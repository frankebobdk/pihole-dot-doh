#!/bin/sh
set -eu
exec >>/var/log/after-hook.log 2>&1
echo "[HOOK] $(date) starting"
sleep 2

# Initialisering
/usr/local/bin/init-config.sh

# Verificer at config eksisterer
if [ ! -f /config/unbound/unbound.conf ]; then
    echo "[HOOK] ERROR: /config/unbound/unbound.conf not found!"
    exit 1
fi

# Start redis
redis-server /config/redis/redis.conf &
echo "[HOOK] redis started (pid $!)"

# Start unbound
exec unbound -d -c /config/unbound/unbound.conf
