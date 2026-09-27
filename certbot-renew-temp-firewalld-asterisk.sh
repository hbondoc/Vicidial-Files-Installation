#!/usr/bin/env bash
set -euo pipefail

ZONE="public"
LOG="/var/log/certbot-renew-temp-firewalld-asterisk.log"
LOCK="/var/lock/certbot-renew-temp-firewalld.lock"

# Commands (adjust if your paths differ)
FIREWALL_CMD="/usr/bin/firewall-cmd"
CERTBOT="/usr/bin/certbot"
ASTERISK="/usr/sbin/asterisk"

# Ensure log dir exists
mkdir -p "$(dirname "$LOG")"

exec >>"$LOG" 2>&1
echo "[$(date '+%F %T')] === START ==="

# Prevent overlapping runs
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "[$(date '+%F %T')] Another run is active. Exiting."
  exit 0
fi

cleanup() {
  # Always close HTTP again (ignore errors)
  echo "[$(date '+%F %T')] Closing HTTP in firewalld..."
  $FIREWALL_CMD --zone="$ZONE" --remove-service=http >/dev/null 2>&1 || true

  rmdir "$LOCK" >/dev/null 2>&1 || true
  echo "[$(date '+%F %T')] === END ==="
}
trap cleanup EXIT

# Track current cert mtime snapshots (so we reload only if changed)
# Looks at all live certs; if you want only specific domain, tell me.
PRE_HASH="$(find /etc/letsencrypt/live -maxdepth 2 -type f -name 'fullchain.pem' -o -name 'privkey.pem' 2>/dev/null | sort | xargs -r sha256sum | sha256sum | awk '{print $1}')"

echo "[$(date '+%F %T')] Temporarily opening HTTP in firewalld..."
$FIREWALL_CMD --zone="$ZONE" --add-service=http >/dev/null 2>&1

echo "[$(date '+%F %T')] Running certbot renew..."
# No --standalone (uses your existing webserver plugin/config or http-01 if configured)
$CERTBOT renew --quiet

POST_HASH="$(find /etc/letsencrypt/live -maxdepth 2 -type f -name 'fullchain.pem' -o -name 'privkey.pem' 2>/dev/null | sort | xargs -r sha256sum | sha256sum | awk '{print $1}')"

if [[ "$PRE_HASH" != "$POST_HASH" ]]; then
  echo "[$(date '+%F %T')] Certificate change detected. Reloading Asterisk HTTP..."
  $ASTERISK -rx "http reload" >/dev/null 2>&1 || $ASTERISK -rx "core reload" >/dev/null 2>&1 || true
else
  echo "[$(date '+%F %T')] No cert changes detected. Skipping Asterisk reload."
fi
