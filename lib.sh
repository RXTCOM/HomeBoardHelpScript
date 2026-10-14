# shellcheck shell=bash
# Shared helpers for install.sh and onderhoud.sh (sourced, not run).
DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
CTR=homeboard-influxdb
LOG=$DIR/onderhoud.log

log() { echo "$(date '+%F %T') $*" | tee -a "$LOG"; }

# docker compose v2 plugin, or the older docker-compose binary some NAS systems ship
compose() {
  if docker compose version >/dev/null 2>&1; then docker compose --project-directory "$DIR" -f "$DIR/docker-compose.yml" "$@"
  else docker-compose --project-directory "$DIR" -f "$DIR/docker-compose.yml" "$@"; fi
}

envget() { sed -n "s/^$1=//p" "$DIR/.env" 2>/dev/null | tail -1; }

health() { docker inspect -f '{{if ne .State.Status "running"}}{{.State.Status}}{{else if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' "$CTR" 2>/dev/null || echo missing; }

# wait until the container reports healthy; returns 1 after $1 seconds
wait_healthy() {
  local t=${1:-180}
  while [ "$t" -gt 0 ]; do
    [ "$(health)" = healthy ] && return 0
    sleep 5; t=$((t - 5))
  done
  return 1
}

# optional outside watchdog (e.g. healthchecks.io): it mails you when the pings stop
ping_hc() {
  local url; url=$(envget HEALTHCHECK_URL)
  [ -n "$url" ] && curl -fsS -m 10 --retry 3 "$url${1:+/$1}" ${2:+--data-raw "$2"} >/dev/null 2>&1
  return 0
}

lan_ip() {
  local ip
  ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  [ -n "$ip" ] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo "$ip"
}

# the address devices use; SERVER_URL in .env overrides it (for example a Tailscale name)
server_url() {
  local u; u=$(envget SERVER_URL); [ -n "$u" ] || u="http://$(lan_ip):$(envget PORT)"
  echo "$u"
}

# for the family board; with the beheertoken ("m") a parent can add and unlink devices from the app
pairing_code() {
  local m; m=$(envget BEHEER_TOKEN)
  printf '{"kb":1,"u":"%s","o":"%s","b":"%s","t":"%s","r":"board"%s}' \
    "$(server_url)" "$(envget INFLUX_ORG)" "$(envget INFLUX_BUCKET)" "$(envget APP_TOKEN)" "${m:+,\"m\":\"$m\"}"
}

show_pairing() {
  local code; code=$(pairing_code)
  echo
  echo "Koppelcode voor de app (op de tablet aan de muur: '📷 QR-code scannen'):"
  if command -v qrencode >/dev/null; then qrencode -t ansiutf8 -m 2 "$code"
  else echo "(installeer 'qrencode' voor een QR-code in beeld; plakken in het veld Serveradres werkt ook)"; fi
  echo "$code"
  echo
}
