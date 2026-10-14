#!/usr/bin/env bash
# Home Board server maintenance. Runs by itself from timers (or the NAS task scheduler):
#   check   every 10 minutes: start the database if it's down, restart it if it hangs
#   backup  every night: full backup, keeps the newest BACKUP_KEEP
#   update  every week: backup, pull the newest InfluxDB 2.x, roll back if it doesn't come up healthy
# By hand:
#   status | koppelcode | restore <backup.tar.gz>
set -uo pipefail
. "$(dirname "$(readlink -f "$0")")/lib.sh"
cd "$DIR" || exit 1

# one task at a time (mkdir is atomic, also on NAS systems without flock)
LOCK=$DIR/.lock
lock() {
  if ! mkdir "$LOCK" 2>/dev/null; then
    # a lock older than 2 hours is left over from a crash or power cut
    if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +120 2>/dev/null)" ]; then rmdir "$LOCK"; mkdir "$LOCK" || exit 0
    else exit 0; fi
  fi
  trap 'rmdir "$LOCK" 2>/dev/null' EXIT
}

# keep the log short
trim_log() { [ -f "$LOG" ] && tail -n 1000 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"; }

do_check() {
  local h; h=$(health)
  case "$h" in
    healthy|starting) ;;
    missing|exited|created|dead) log "check: database draait niet ($h), start hem"; compose up -d ;;
    unhealthy) log "check: database reageert niet, herstart"; docker restart "$CTR" >/dev/null ;;
    *) log "check: status $h" ;;
  esac
  local used; used=$(df -P "$DIR" | awk 'NR==2{gsub("%","",$5); print $5}')
  if [ "${used:-0}" -ge 90 ]; then
    log "check: schijf is voor ${used}% vol"; ping_hc fail "schijf ${used}% vol"; return
  fi
  if [ "$(health)" = healthy ] || wait_healthy 120; then ping_hc; else ping_hc fail "database niet gezond: $(health)"; fi
}

do_backup() {
  local keep name tmp out copy
  keep=$(envget BACKUP_KEEP); keep=${keep:-14}
  name=homeboard-$(date +%F-%H%M%S); tmp=$DIR/backups/$name
  mkdir -p "$DIR/backups"; chmod 700 "$DIR/backups"
  rm -rf "$tmp"
  if ! docker exec "$CTR" influx backup "/backups/$name" >/dev/null 2>"$DIR/backups/.err"; then
    log "backup: mislukt: $(tail -n 3 "$DIR/backups/.err" | tr '\n' ' ')"; rm -rf "$tmp"; ping_hc fail "backup mislukt"; return 1
  fi
  # .env holds the tokens; with it a restore on new hardware keeps every device paired and every photo readable
  cp "$DIR/.env" "$tmp/env"
  out=$DIR/backups/$name.tar.gz
  tar -czf "$out" -C "$DIR/backups" "$name" && rm -rf "$tmp" "$DIR/backups/.err"
  chmod 600 "$out"
  log "backup: $(basename "$out") ($(du -h "$out" | cut -f1))"
  # newest first; remove everything after the first $keep
  ls -1t "$DIR"/backups/homeboard-*.tar.gz 2>/dev/null | tail -n +$((keep + 1)) | xargs -r rm -f
  copy=$(envget BACKUP_COPY_TO)
  if [ -n "$copy" ]; then
    if mkdir -p "$copy" 2>/dev/null && cp "$out" "$copy/"; then
      ls -1t "$copy"/homeboard-*.tar.gz 2>/dev/null | tail -n +$((keep + 1)) | xargs -r rm -f
    else log "backup: kopiëren naar $copy lukte niet"; ping_hc fail "backup niet gekopieerd naar $copy"; fi
  fi
}

do_update() {
  do_backup || { log "update: overgeslagen, want de backup lukte niet"; return 1; }
  local old new
  old=$(docker image inspect -f '{{.Id}}' influxdb:2 2>/dev/null)
  if ! compose pull -q >/dev/null 2>&1; then log "update: downloaden lukte niet (geen internet?), volgende week opnieuw"; return 0; fi
  new=$(docker image inspect -f '{{.Id}}' influxdb:2 2>/dev/null)
  if [ "$old" = "$new" ]; then log "update: InfluxDB is al de nieuwste ($(version))"; return 0; fi
  compose up -d >/dev/null 2>&1
  if wait_healthy 240; then
    log "update: bijgewerkt naar $(version)"
    docker image prune -f >/dev/null 2>&1
  else
    log "update: nieuwe versie start niet goed, terug naar de vorige"
    docker tag "$old" influxdb:2 && compose up -d --force-recreate >/dev/null 2>&1
    if wait_healthy 240; then log "update: vorige versie draait weer ($(version))"; ping_hc fail "update teruggedraaid"
    else log "update: ook de vorige versie start niet"; ping_hc fail "database start niet na update"; fi
  fi
}

version() { docker exec "$CTR" influxd version 2>/dev/null | awk '{print $2}'; }

do_status() {
  echo "Database:       $(health), InfluxDB $(version)"
  echo "Adres:          $(server_url)"
  echo "Laatste backup: $(ls -1t "$DIR"/backups/homeboard-*.tar.gz 2>/dev/null | head -1 | xargs -r basename)"
  echo "Backups:        $(ls -1 "$DIR"/backups/homeboard-*.tar.gz 2>/dev/null | wc -l) stuks, $(du -sh "$DIR/backups" 2>/dev/null | cut -f1)"
  echo "Schijf:         $(df -hP "$DIR" | awk 'NR==2{print $5" vol, "$4" vrij"}')"
  echo "Data:           $(du -sh "$DIR/data" 2>/dev/null | cut -f1)"
  echo; echo "Laatste meldingen:"; tail -n 8 "$LOG" 2>/dev/null
}

do_restore() {
  local file=${1:-}
  [ -f "$file" ] || { echo "Gebruik: $0 restore backups/homeboard-JJJJ-MM-DD-UUMMSS.tar.gz"; exit 1; }
  local tmp=$DIR/backups/restore
  rm -rf "$tmp"; mkdir -p "$tmp"
  tar -xzf "$file" -C "$tmp" --strip-components=1 || { echo "Kan $file niet uitpakken"; exit 1; }
  if [ -f "$tmp/env" ] && ! cmp -s "$tmp/env" "$DIR/.env"; then
    echo "Let op: deze backup hoort bij een andere installatie (andere tokens)."
    echo "Op nieuwe hardware herstel je met: sudo ./install.sh --herstel $file"
    read -r -p "Toch doorgaan? Dan krijgen apparaten mogelijk 'De server weigert het token'. [j/N] " a
    [ "$a" = j ] || exit 1
  fi
  log "restore: $file terugzetten"
  if docker exec "$CTR" influx restore --full /backups/restore >/dev/null; then log "restore: klaar"
  else log "restore: mislukt"; fi
  rm -rf "$tmp"
  docker restart "$CTR" >/dev/null; wait_healthy 120 && echo "Database draait weer."
}

# a lost or stolen tablet or phone: a new app token, and the old one stops working at once. The devices you keep get the
# new one by scanning the QR code shown at the end; they keep their family key, so photos and settings stay readable.
# Every device you keep needs app 1.43 or newer (older versions derive their key from the token).
do_newtoken() {
  local old bid out tok newid oldids oldid
  old=$(envget APP_TOKEN)
  [ -n "$old" ] || { echo "Geen APP_TOKEN in .env: draai eerst sudo ./install.sh"; exit 1; }
  echo "Hiermee werkt het huidige token niet meer. Alle apparaten die je houdt, koppel je daarna opnieuw met de QR-code"
  echo "(in de app: Ouders → Server → Serververbinding wijzigen → QR-code scannen). Ze hebben app 1.43 of nieuwer nodig."
  read -r -p "Doorgaan? [j/N] " a
  [ "$a" = j ] || exit 1
  bid=$(docker exec "$CTR" influx bucket list --name "$(envget INFLUX_BUCKET)" --hide-headers | awk '{print $1}')
  out=$(docker exec "$CTR" influx auth create --org "$(envget INFLUX_ORG)" --read-bucket "$bid" --write-bucket "$bid" \
        --description "Home Board app $(date +%F)" --json)
  tok=$(echo "$out" | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p'); newid=$(echo "$out" | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' | head -1)
  [ -n "$tok" ] && [ -n "$newid" ] || { echo "Een nieuw token maken lukte niet; er is niets veranderd."; exit 1; }
  cp "$DIR/.env" "$DIR/.env.voor-nieuw-token"
  sed -i "s|^APP_TOKEN=.*|APP_TOKEN=$tok|" "$DIR/.env"
  # InfluxDB no longer shows tokens, so the old one is found by its description: every earlier "Home Board app" token goes
  oldids=$(docker exec "$CTR" influx auth list --hide-headers | awk -F'\t' -v n="$newid" '$2 ~ /^Home Board app/ && $1 != n {print $1}')
  for oldid in $oldids; do
    if docker exec "$CTR" influx auth delete --id "$oldid" >/dev/null; then log "nieuw-token: oud token $oldid ingetrokken"
    else log "nieuw-token: token $oldid niet ingetrokken; doe dat zelf via de InfluxDB-website (Load Data → API Tokens)"; fi
  done
  [ -n "$oldids" ] || log "nieuw-token: geen oud token gevonden; kijk zelf via de InfluxDB-website (Load Data → API Tokens)"
  rm -f "$DIR/.env.voor-nieuw-token"
  show_pairing
}

case "${1:-}" in
  check) lock; do_check ;;
  backup) lock; do_backup ;;
  update) lock; do_update; trim_log ;;
  status) do_status ;;
  koppelcode) show_pairing ;;
  nieuw-token) lock; do_newtoken ;;
  restore) lock; do_restore "${2:-}" ;;
  *) echo "Gebruik: $0 check|backup|update|status|koppelcode|nieuw-token|restore <bestand>"; exit 1 ;;
esac
