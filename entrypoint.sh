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
ROOT_KEY_FILE="/etc/unbound/var/root.key"
if [ ! -f "$ROOT_KEY_FILE" ]; then
    echo "[ENTRYPOINT] Initializing DNSSEC root trust anchor at $ROOT_KEY_FILE..."

    # Temporary resolv.conf for bootstrap DNS lookups
    TEMP_RESOLV="/tmp/temp_resolv.conf"
    echo "nameserver 1.1.1.1" > "$TEMP_RESOLV"
    echo "nameserver 1.0.0.1" >> "$TEMP_RESOLV"

    MAX_RETRIES=5
    RETRY_COUNT=0
    until unbound-anchor -a "$ROOT_KEY_FILE" -f "$TEMP_RESOLV" || [ $RETRY_COUNT -eq $MAX_RETRIES ]; do
        RETRY_COUNT=$((RETRY_COUNT + 1))
        echo "[ENTRYPOINT] unbound-anchor failed (network not ready?), retrying ($RETRY_COUNT/$MAX_RETRIES) in 2s..."
        sleep 2
    done

    rm -f "$TEMP_RESOLV"

    if [ ! -f "$ROOT_KEY_FILE" ]; then
        echo "[ENTRYPOINT] FATAL: Could not initialize DNSSEC root anchor after $MAX_RETRIES retries. Exiting."
        exit 1
    fi

    echo "[ENTRYPOINT] DNSSEC root trust anchor initialized."
else
    echo "[ENTRYPOINT] DNSSEC root trust anchor already exists."
fi

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

# --- 5. Start Pi-hole (exec replaces shell — Pi-hole becomes main process under tini) ---
PIHOLE_START="$(cat /etc/pihole-start-path)"
echo "[ENTRYPOINT] Starting Pi-hole via $PIHOLE_START..."
exec "$PIHOLE_START"
