#!/bin/sh
set -eu

echo "[ENTRYPOINT] Starting initialization..."

# --- 1. Initialize configuration ---
/usr/local/bin/init-config.sh

# Verify config exists
if [ ! -f /config/unbound/unbound.conf ]; then
    echo "[ENTRYPOINT] ERROR: /config/unbound/unbound.conf not found!"
    exit 1
fi

# --- 2. DNSSEC root anchor initialization ---
# unbound-anchor exit codes: 0 = updated, 1 = already current (both OK), >1 = failure
ROOT_KEY_FILE="/etc/unbound/var/root.key"
echo "[ENTRYPOINT] Initializing DNSSEC root trust anchor at $ROOT_KEY_FILE..."
unbound-anchor -a "$ROOT_KEY_FILE" || ANCHOR_EXIT=$?
ANCHOR_EXIT="${ANCHOR_EXIT:-0}"
if [ "$ANCHOR_EXIT" -gt 1 ]; then
    echo "[ENTRYPOINT] FATAL: unbound-anchor failed (exit $ANCHOR_EXIT). Exiting."
    exit 1
fi
echo "[ENTRYPOINT] DNSSEC root trust anchor ready (exit $ANCHOR_EXIT)."

# --- 3. Start Redis (--daemonize no overrides config, fixes double-fork zombie) ---
echo "[ENTRYPOINT] Starting Redis..."
redis-server /config/redis/redis.conf --daemonize no &

# Wait for Redis socket to be ready (max 5s)
WAIT=0
while [ ! -S /tmp/redis.sock ] && [ $WAIT -lt 50 ]; do
    sleep 0.1
    WAIT=$((WAIT + 1))
done
if [ -S /tmp/redis.sock ]; then
    echo "[ENTRYPOINT] Redis socket ready."
else
    echo "[ENTRYPOINT] WARNING: Redis socket not detected after 5s, continuing anyway..."
fi

# --- 4. Start Unbound ---
echo "[ENTRYPOINT] Starting Unbound..."
unbound -d -c /config/unbound/unbound.conf &

# Wait for Unbound to accept connections (max 10s)
WAIT=0
while ! dig @127.0.0.1 -p 5335 +time=1 +tries=1 ch version.bind txt >/dev/null 2>&1 && [ $WAIT -lt 100 ]; do
    sleep 0.1
    WAIT=$((WAIT + 1))
done
if [ $WAIT -lt 100 ]; then
    echo "[ENTRYPOINT] Unbound is ready."
else
    echo "[ENTRYPOINT] WARNING: Unbound not responding after 10s, continuing anyway..."
fi

# --- 5. Start Pi-hole (exec replaces shell — Pi-hole becomes main process under tini) ---
PIHOLE_START="$(cat /etc/pihole-start-path)"
echo "[ENTRYPOINT] Starting Pi-hole via $PIHOLE_START..."
exec "$PIHOLE_START"
