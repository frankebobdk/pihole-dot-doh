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

max_retries=3
retry=0
while [ $retry -lt $max_retries ]; do
    rc=0; unbound-anchor -a "$ROOT_KEY_FILE" || rc=$?
    if [ $rc -eq 0 ] || [ $rc -eq 1 ]; then
        break
    fi
    retry=$((retry + 1))
    echo "[ENTRYPOINT] DNSSEC anchor init attempt $retry/$max_retries failed (exit $rc), retrying..."
    sleep 2
done

if [ $retry -eq $max_retries ]; then
    if [ -f "$ROOT_KEY_FILE" ]; then
        echo "[ENTRYPOINT] WARNING: DNSSEC anchor refresh failed after $max_retries attempts (exit $rc), using existing root.key"
    else
        echo "[ENTRYPOINT] FATAL: DNSSEC root anchor initialization failed after $max_retries attempts"
        exit 1
    fi
fi
chown unbound:unbound "$ROOT_KEY_FILE"
echo "[ENTRYPOINT] DNSSEC root trust anchor ready."

# --- 3. Start Redis (--daemonize no overrides config, fixes double-fork zombie) ---
echo "[ENTRYPOINT] Starting Redis..."
redis-server /config/redis/redis.conf --daemonize no &
REDIS_PID=$!

# Wait for Redis socket to be ready (max 5s)
WAIT=0
while [ ! -S /tmp/redis.sock ] && [ $WAIT -lt 50 ]; do
    sleep 0.1
    WAIT=$((WAIT + 1))
done
if [ -S /tmp/redis.sock ]; then
    if ! kill -0 "$REDIS_PID" 2>/dev/null; then
        echo "[ENTRYPOINT] ERROR: Redis process died during startup"
        exit 1
    fi
    echo "[ENTRYPOINT] Redis socket ready."
else
    echo "[ENTRYPOINT] ERROR: Redis socket not detected after 5s"
    exit 1
fi

# --- 4. Start Unbound ---
echo "[ENTRYPOINT] Starting Unbound..."
unbound -d -c /config/unbound/unbound.conf &
UNBOUND_PID=$!

# Wait for Unbound to accept connections (max 10s)
WAIT=0
while ! dig @127.0.0.1 -p 5335 +time=1 +tries=1 ch version.bind txt >/dev/null 2>&1 && [ $WAIT -lt 100 ]; do
    sleep 0.1
    WAIT=$((WAIT + 1))
done
if [ $WAIT -lt 100 ]; then
    if ! kill -0 "$UNBOUND_PID" 2>/dev/null; then
        echo "[ENTRYPOINT] ERROR: Unbound process died during startup"
        exit 1
    fi
    echo "[ENTRYPOINT] Unbound is ready."
else
    echo "[ENTRYPOINT] ERROR: Unbound not responding after 10s"
    exit 1
fi

# --- 5. Start Pi-hole (exec replaces shell — Pi-hole becomes main process under tini) ---
PIHOLE_START="$(cat /etc/pihole-start-path)"
echo "[ENTRYPOINT] Starting Pi-hole via $PIHOLE_START..."
exec "$PIHOLE_START"
