#!/bin/sh
set -eu
# log alt til egen fil (nem fejlsøgning)
exec >>/var/log/after-hook.log 2>&1
echo "[HOOK] $(date) starting"
# giv Pi-hole et par sekunder til at komme i gang
sleep 2
# initialisering (idempotent)
 /usr/local/bin/init-config.sh
# start redis i baggrunden
redis-server /config/redis/redis.conf &
echo "[HOOK] redis started (pid $!)"
# start unbound i forgrunden i denne baggrunds-job
exec unbound -d -c /config/unbound/unbound.conf
