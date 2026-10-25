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
  local old new backup mark
  backup=$(ls -1t "$DIR"/backups/homeboard-*.tar.gz | head -1)
  old=$(docker image inspect -f '{{.Id}}' influxdb:2 2>/dev/null)
  if ! compose pull -q >/dev/null 2>&1; then log "update: downloaden lukte niet (geen internet?), volgende week opnieuw"; return 0; fi
  new=$(docker image inspect -f '{{.Id}}' influxdb:2 2>/dev/null)
  if [ "$old" = "$new" ]; then log "update: InfluxDB is al de nieuwste ($(version))"; return 0; fi
  mark=$DIR/.update-start; touch "$mark"
  compose up -d >/dev/null 2>&1
  if wait_healthy 240; then
    log "update: bijgewerkt naar $(version)"
    docker image prune -f >/dev/null 2>&1
  else
    log "update: nieuwe versie start niet goed, terug naar de vorige"
    if rollback "$old" "$mark" "$backup"; then log "update: vorige versie draait weer ($(version))"; ping_hc fail "update teruggedraaid"
    else log "update: ook de vorige versie start niet"; ping_hc fail "database start niet na update"; fi
  fi
  rm -f "$mark"
}

# Back to the previous image and the data as it was before the update. A newer InfluxDB migrates the database on its
# first start, and the older version then refuses it ("unknown migration"), so the image alone is not enough.
# 2.9 and newer keep a copy from before the migration (data/influxd.bolt.pre-v<version>-upgrade.backup): that one goes
# back first. Still down (or no copy): the backup made just before the update, on a fresh start. What the new version
# left behind stays next to it (data.mislukte-update, config.mislukte-update).
rollback() {
  local old=$1 mark=$2 backup=$3 pre
  compose stop >/dev/null 2>&1
  docker tag "$old" influxdb:2 || return 1
  pre=$(find "$DIR/data" -maxdepth 1 -name 'influxd.bolt.pre-v*-upgrade.backup' -newer "$mark" 2>/dev/null | head -1)
  if [ -n "$pre" ]; then
    log "update: database van voor de migratie terugzetten ($(basename "$pre"))"
    cp -p "$DIR/data/influxd.bolt" "$DIR/data/influxd.bolt.mislukte-update" && cp -p "$pre" "$DIR/data/influxd.bolt"
  fi
  compose up -d --force-recreate >/dev/null 2>&1
  wait_healthy 240 && return 0
  [ -f "$backup" ] || return 1
  log "update: backup $(basename "$backup") terugzetten op een lege database"
  compose stop >/dev/null 2>&1
  # config too: the image's first-start setup refuses an existing CLI config, and makes the same one from .env again
  local d
  for d in data config; do
    rm -rf "$DIR/$d.mislukte-update"; mv "$DIR/$d" "$DIR/$d.mislukte-update" && mkdir "$DIR/$d" || return 1
  done
  compose up -d --force-recreate >/dev/null 2>&1
  wait_healthy 240 && restore_full "$backup"
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
  local env
  env=$(tar -xzf "$file" --wildcards --strip-components=1 -O '*/env' 2>/dev/null) || { echo "Kan $file niet uitpakken"; exit 1; }
  if [ -n "$env" ] && [ "$env" != "$(cat "$DIR/.env")" ]; then
    echo "Let op: deze backup hoort bij een andere installatie (andere tokens)."
    echo "Op nieuwe hardware herstel je met: sudo ./install.sh --herstel $file"
    read -r -p "Toch doorgaan? Dan krijgen apparaten mogelijk 'De server weigert het token'. [j/N] " a
    [ "$a" = j ] || exit 1
  fi
  restore_full "$file" && echo "Database draait weer."
}

# a backup of do_backup back into the running database: everything, tokens included (influx restore --full)
restore_full() {
  local file=$1 tmp=$DIR/backups/restore rc=0
  rm -rf "$tmp"; mkdir -p "$tmp"
  tar -xzf "$file" -C "$tmp" --strip-components=1 || { log "restore: kan $file niet uitpakken"; rm -rf "$tmp"; return 1; }
  log "restore: $file terugzetten"
  if docker exec "$CTR" influx restore --full /backups/restore >/dev/null; then log "restore: klaar"
  else log "restore: mislukt"; rc=1; fi
  rm -rf "$tmp"
  docker restart "$CTR" >/dev/null; wait_healthy 120 || rc=1
  return $rc
}

case "${1:-}" in
  check) lock; do_check ;;
  backup) lock; do_backup ;;
  update) lock; do_update; trim_log ;;
  status) do_status ;;
  koppelcode) show_pairing ;;
  restore) lock; do_restore "${2:-}" ;;
  *) echo "Gebruik: $0 check|backup|update|status|koppelcode|restore <bestand>"; exit 1 ;;
esac
