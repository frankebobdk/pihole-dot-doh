#!/bin/sh
set -e
/usr/local/bin/init-config.sh
# Start Redis i baggrunden
redis-server /config/redis/redis.conf &
# Unbound i forgrund (beholder processen i live)
exec unbound -d -c /config/unbound/unbound.conf
