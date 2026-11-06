#!/usr/bin/env bash
# Installs the Home Board server: InfluxDB 2 in Docker, plus everything that keeps it running by itself.
#   sudo ./install.sh                         new installation (safe to run again: it only adds what's missing)
#   sudo ./install.sh --herstel <backup>      new hardware: restore a backup made by onderhoud.sh, tokens included
#   sudo ./install.sh --box                   prepare a Home Board Box: everything but passwords and tokens; prints the
#                                             code for the pairing card (claim.py waits for it on the home network)
#   (install.sh --claimed                     run by claim.py once the family entered that code: the normal installation)
set -euo pipefail
[ "$(id -u)" = 0 ] || exec sudo bash "$(readlink -f "$0")" "$@"
. "$(dirname "$(readlink -f "$0")")/lib.sh"
cd "$DIR"
chmod +x onderhoud.sh install.sh

RESTORE= BOX= CLAIMED=
[ "${1:-}" = --herstel ] && { RESTORE=$(readlink -f "${2:-}"); [ -f "$RESTORE" ] || { echo "Backup niet gevonden: ${2:-}"; exit 1; }; }
[ "${1:-}" = --box ] && BOX=1
[ "${1:-}" = --claimed ] && CLAIMED=1
chmod +x claim.py

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
rnd() { head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
debian() { command -v apt-get >/dev/null && command -v systemctl >/dev/null && [ -d /run/systemd/system ]; }

# InfluxDB 2 is only built for 64-bit systems
case "$(uname -m)" in
  aarch64|arm64|x86_64|amd64) ;;
  *) echo "Dit systeem is $(uname -m). InfluxDB 2 heeft een 64-bit systeem nodig."
     echo "Op een Raspberry Pi: installeer 'Raspberry Pi OS Lite (64-bit)' met Raspberry Pi Imager."; exit 1 ;;
esac

say "Docker"
if ! command -v docker >/dev/null; then
  if debian; then
    curl -fsSL https://get.docker.com | sh
  else
    echo "Docker ontbreekt. Op een NAS: installeer Container Manager (Synology) of Container Station (QNAP) en start dit script opnieuw."
    exit 1
  fi
fi
debian && systemctl enable --now docker >/dev/null 2>&1 || true
docker version --format 'Docker {{.Server.Version}}'

if [ -n "$BOX" ]; then
  debian || { echo "Een Box klaarmaken kan alleen op Debian (met systemd)."; exit 1; }
  [ -f .env ] && { echo "Deze server is al ingericht ($DIR/.env). Een Box maak je van een schone installatie."; exit 1; }
  say "Database klaarzetten (zonder wachtwoorden)"
  compose pull -q
  say "Pakketten"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 qrencode unattended-upgrades avahi-daemon >/dev/null
  say "Wachten op de koppelcode"
  cat >/etc/systemd/system/homeboard-claim.service <<UNIT
[Unit]
Description=Home Board: wacht op de koppelcode van de kaart
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/bin/python3 $DIR/claim.py 8086
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT
  echo "Let op: SSH, het root-wachtwoord en de wachtwoorden van gebruikers gaan op slot zodra de koper de code invult."
  code=$(python3 claim.py new)
  write_avahi
  dev=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  if [ -n "$dev" ] && [ -f /etc/avahi/avahi-daemon.conf ]; then
    sed -i '/^#\?allow-interfaces=/d' /etc/avahi/avahi-daemon.conf
    sed -i "/^\[server\]/a allow-interfaces=$dev" /etc/avahi/avahi-daemon.conf
  fi
  systemctl daemon-reload
  systemctl enable avahi-daemon homeboard-claim >/dev/null 2>&1
  systemctl restart avahi-daemon homeboard-claim
  card="{\"kb\":1,\"claim\":\"${code//-/}\"}"
  qrencode -t SVG -m 2 -o "$DIR/claim/koppelkaart-qr.svg" "$card"
  say "Klaar voor verzending"
  echo "Koppelcode voor de kaart:  $code"
  qrencode -t ansiutf8 -m 2 "$card"
  echo "QR-code als bestand: $DIR/claim/koppelkaart-qr.svg (print hem op de kaart en verwijder het bestand daarna)"
  echo "De code staat verder nergens leesbaar op deze server, alleen als hash. Kwijt? Maak een nieuwe: sudo $DIR/install.sh --box"
  exit 0
fi

if [ -n "$CLAIMED" ]; then
  say "Toegang van het klaarmaken afsluiten"
  # whoever prepared the box (RXTCOM) keeps no way in: no SSH, no password for root or the users made then, no keys
  systemctl disable --now ssh ssh.socket sshd >/dev/null 2>&1 || true
  passwd -l root >/dev/null 2>&1 || true
  awk -F: '$3>=1000 && $3<65534 {print $1}' /etc/passwd | while read -r u; do usermod -L -e 1 "$u" >/dev/null 2>&1 || true; done
  rm -f /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys
  echo "SSH uit, wachtwoorden van het klaarmaken op slot."
fi

say "Instellingen"
if [ -n "$RESTORE" ]; then
  # the old .env brings back the same admin and app tokens, so paired devices and encrypted photos keep working
  [ -d data ] && [ -n "$(ls -A data 2>/dev/null)" ] && { echo "Er staat al data in $DIR/data. Herstel alleen op een lege installatie."; exit 1; }
  tar -xzf "$RESTORE" --wildcards --strip-components=1 -O '*/env' >.env || { echo "Geen instellingen (env) in deze backup."; exit 1; }
  echo "Instellingen uit de backup gebruikt."
elif [ ! -f .env ]; then
  cat >.env <<EOF
# Home Board server settings. Keep this file safe: it holds the passwords and tokens (also inside every backup).
INFLUX_ORG=thuis
INFLUX_BUCKET=homeboard
INFLUX_USER=admin
INFLUX_PASSWORD=$(rnd 24)
INFLUX_ADMIN_TOKEN=$(rnd 64)
PORT=8086
# address the app uses; empty = this device's address on the home network
SERVER_URL=
# number of nightly backups to keep, and an optional second place to copy them (USB disk, NAS share)
BACKUP_KEEP=14
BACKUP_COPY_TO=
# optional: a healthchecks.io ping URL; you get an e-mail when the server stops reporting
HEALTHCHECK_URL=
EOF
  echo "Nieuwe wachtwoorden en tokens gemaakt in $DIR/.env"
else
  echo "Bestaande instellingen in $DIR/.env gebruikt."
fi
server_id >/dev/null
chmod 600 .env
mkdir -p data config backups && chmod 700 backups

say "Database starten"
compose pull -q || echo "Downloaden lukte niet; de versie die er al is wordt gebruikt."
# a Box being claimed: the database only reachable on this device for now; claim.py still answers on the home network
# and hands the port over when the app has its code (onderhoud.sh claim-done)
[ -n "$CLAIMED" ] && export PORT=127.0.0.1:18086
compose up -d
if ! wait_healthy 240; then echo "De database start niet. Kijk met: docker logs $CTR"; exit 1; fi
echo "InfluxDB $(docker exec "$CTR" influxd version | awk '{print $2}') draait."

if [ -n "$RESTORE" ]; then
  say "Backup terugzetten"
  rm -rf backups/restore && mkdir -p backups/restore
  tar -xzf "$RESTORE" -C backups/restore --strip-components=1
  docker exec "$CTR" influx restore --full /backups/restore >/dev/null
  rm -rf backups/restore
  docker restart "$CTR" >/dev/null; wait_healthy 120
  log "install: backup $(basename "$RESTORE") teruggezet"
  echo "Teruggezet."
fi

say "Token voor de app"
if [ -z "$(envget APP_TOKEN)" ]; then
  # the app only gets read and write rights on its own bucket, not the admin token
  bid=$(docker exec "$CTR" influx bucket list --name "$(envget INFLUX_BUCKET)" --hide-headers | awk '{print $1}')
  tok=$(docker exec "$CTR" influx auth create --org "$(envget INFLUX_ORG)" --read-bucket "$bid" --write-bucket "$bid" \
        --description "Home Board app" --json | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p')
  [ -n "$tok" ] || { echo "Token maken lukte niet."; exit 1; }
  printf '# token for the app (read/write on the bucket only). Never replace it by hand.\nAPP_TOKEN=%s\n' "$tok" >>.env
  echo "Gemaakt."
else
  echo "Bestaat al."
fi

say "Beheertoken voor de app"
if [ -z "$(envget BEHEER_TOKEN)" ]; then
  # for parents in the app (Ouders → Apparaten): a token per device, and unlinking a lost one. It can only hand out
  # rights it has itself (this bucket), so it can't make a stronger token; it travels only to the board and parents' phones
  bid=$(docker exec "$CTR" influx bucket list --name "$(envget INFLUX_BUCKET)" --hide-headers | awk '{print $1}')
  tok=$(docker exec "$CTR" influx auth create --org "$(envget INFLUX_ORG)" --read-bucket "$bid" --write-bucket "$bid" \
        --read-authorizations --write-authorizations --read-users --write-users \
        --description "Home Board beheer" --json | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p')
  [ -n "$tok" ] || { echo "Beheertoken maken lukte niet."; exit 1; }
  printf '# token with which parents link and unlink devices in the app\nBEHEER_TOKEN=%s\n' "$tok" >>.env
  echo "Gemaakt."
else
  echo "Bestaat al."
fi

if debian; then
  say "Automatisch onderhoud"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qrencode unattended-upgrades avahi-daemon >/dev/null
  unit() { # name, description, command, schedule, random delay
    cat >/etc/systemd/system/homeboard-$1.service <<EOF
[Unit]
Description=Home Board: $2
After=docker.service
Requires=docker.service
[Service]
Type=oneshot
ExecStart=$DIR/onderhoud.sh $3
EOF
    cat >/etc/systemd/system/homeboard-$1.timer <<EOF
[Unit]
Description=Home Board: $2
[Timer]
$4
Persistent=true
RandomizedDelaySec=$5
[Install]
WantedBy=timers.target
EOF
  }
  unit check "database bewaken" check "OnBootSec=5min
OnUnitActiveSec=10min" 30
  unit backup "nachtelijke backup" backup "OnCalendar=*-*-* 03:15" 15min
  unit update "wekelijkse update" update "OnCalendar=Sun 04:30" 30min
  systemctl daemon-reload
  # a Box being claimed: the timers start with onderhoud.sh claim-done, once the database has port 8086 (claim.py holds it now)
  [ -n "$CLAIMED" ] || systemctl enable --now homeboard-check.timer homeboard-backup.timer homeboard-update.timer >/dev/null 2>&1
  echo "Elke 10 min controle, elke nacht een backup, elke zondag een update van InfluxDB 2."

  # announce the server on the home network (mDNS), so the app finds it with "Zoek op het netwerk"
  write_avahi
  # only on the home network card, not on Docker's internal networks (their addresses can't be reached from a tablet)
  dev=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  if [ -n "$dev" ] && [ -f /etc/avahi/avahi-daemon.conf ]; then
    sed -i '/^#\?allow-interfaces=/d' /etc/avahi/avahi-daemon.conf
    sed -i "/^\[server\]/a allow-interfaces=$dev" /etc/avahi/avahi-daemon.conf
  fi
  systemctl enable avahi-daemon >/dev/null 2>&1; systemctl restart avahi-daemon 2>/dev/null || true
  echo "De app vindt deze server via 'Zoek op het netwerk'."

  # security and Docker updates for the system itself, with a reboot at night when one needs it
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  cat >/etc/apt/apt.conf.d/52homeboard <<'EOF'
Unattended-Upgrade::Origins-Pattern {
  "origin=Debian,codename=${distro_codename},label=Debian";
  "origin=Debian,codename=${distro_codename}-updates";
  "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
  "origin=Raspbian,codename=${distro_codename},label=Raspbian";
  "origin=Raspberry Pi Foundation,codename=${distro_codename}";
  "origin=Docker";
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
EOF
  # the system log stays small (spares the SD card)
  mkdir -p /etc/systemd/journald.conf.d
  printf '[Journal]\nSystemMaxUse=100M\n' >/etc/systemd/journald.conf.d/homeboard.conf
  systemctl restart systemd-journald
  echo "Systeemupdates gaan automatisch; als een update dat vraagt, herstart het systeem om 04:00."
else
  say "Automatisch onderhoud (zelf inplannen)"
  echo "Dit is geen Debian/Raspberry Pi OS. Plan in de taakplanner van je NAS, als root:"
  echo "  elke 10 minuten : $DIR/onderhoud.sh check"
  echo "  elke nacht      : $DIR/onderhoud.sh backup"
  echo "  elke week       : $DIR/onderhoud.sh update"
fi

[ -n "$CLAIMED" ] && { log "install: Box ingericht met de koppelcode"; exit 0; }

say "Klaar"
echo "Serveradres : $(server_url)"
echo "Organisatie : $(envget INFLUX_ORG)"
echo "Bucket      : $(envget INFLUX_BUCKET)"
echo "Token       : $(envget APP_TOKEN)"
show_pairing
echo "Later nog eens nodig?  sudo $DIR/onderhoud.sh koppelcode"
echo "Hoe staat het ervoor?  sudo $DIR/onderhoud.sh status"
