# Session Summary — Consolidated pihole-dot-doh Configuration

## What This Is

Production-ready configuration files for pihole-dot-doh, merged from three independent audit sessions plus one earlier debugging session. Ready to replace the current project files.

## Source Sessions

| Session | Focus | Folder |
|---------|-------|--------|
| Session 1 — Dockerfile | tini + entrypoint.sh architecture, selective binary copy, unbound user | `proposed-dockerfile-changes/` |
| Session 2 — General Pihole | Hook-based startup, CI/CD workflow | `proposed-pihole-changes/` |
| Session 3 — Redis & Unbound Performance | LFU eviction, aggressive-nsec, minimal-responses, config cleanup | `proposed-redis-unbound-changes/` |
| Earlier debugging session | Redis save rules, lazy-freeing, graceful shutdown, log-servfail | `~/Downloads/dns-stack-changes.md` |

## Final File List and Sources

```
proposed-final/
├── Dockerfile                              ← Session 1 base + Session 3 healthcheck + fixes
├── entrypoint.sh                           ← Session 1 base + fixes
├── init-config.sh                          ← Session 1 (as-is)
├── .github/workflows/image.yml             ← Session 2 (as-is)
├── config/
│   ├── redis/redis.conf                    ← Session 3 base + daemonize fix
│   └── unbound/
│       ├── unbound.conf                    ← Session 3 (as-is)
│       └── unbound.conf.d/
│           ├── cache.conf                  ← Session 3 (as-is)
│           ├── dnssec.conf                 ← Session 3 (new file)
│           └── forward-queries.conf        ← Session 3 (as-is)
├── CHANGELOG.md                            ← Detailed merge decisions
└── SESSION-SUMMARY.md                      ← This file
```

## Key Architecture Decisions

1. **tini -g as PID 1** — Replaces sed hook injection. tini handles signal forwarding (SIGTERM to entire process group for graceful Redis/Unbound shutdown) and zombie reaping.
2. **entrypoint.sh orchestration** — Starts Redis (background) -> waits for socket -> starts Unbound (background) -> `exec`s Pi-hole's start.sh.
3. **No after-pihole-start.sh** — Eliminated entirely. entrypoint.sh replaces it.
4. **Selective binary copy** — Only 4 Unbound binaries copied from build stage (not the full /tmp/unbound-out tree).
5. **Redis Unix socket only** — `port 0` disables TCP. Healthcheck uses `redis-cli -s /tmp/redis.sock`.

## Fixes Applied Beyond Any Single Session

| Fix | Detail |
|-----|--------|
| `tini -g` | Sends SIGTERM to entire process group on `docker stop`. Redis saves RDB, Unbound exits clean. Replaces signal trap from debugging session (which doesn't work with `exec`). |
| `daemonize no` in redis.conf | Session 3 had `yes` which causes double-fork zombie under tini. Config says `no`, CLI also passes `--daemonize no` as belt-and-suspenders. |
| Socket-poll loop | Replaces `sleep 1` with deterministic poll of `/tmp/redis.sock` every 100ms, max 5s. |
| `set -eu` | Catches undefined variable bugs (Session 2 pattern applied to Session 1 script). |
| Single `sh -c` healthcheck | All three checks in one shell invocation for correct exit code propagation. |

## What Was Intentionally NOT Changed

| Setting | Value | Why |
|---------|-------|-----|
| `cache-min-ttl` | `0` | Debugging session said 300 was "good balance". Session 3 audit argued 0 is correct: serve-expired + prefetch handle latency, 300s delays CDN failover. Session 3's analysis is deeper. |
| `log-servfail` | Commented out | Debugging session recommended enabling for iOS issue. User chose to keep it commented out. Uncomment if debugging SERVFAIL issues. |
| `redis-timeout` | `25` | Appropriate for Unix socket. No session changed this. |
| `redis-expire-records` | `no` | Required for cachedb module per GitHub issue. |
| `num-threads` / slabs | `2` / `2` | Correctly sized for home network. |

## How to Deploy

```bash
# 1. Copy files to pihole-dot-doh repo (replace existing)
cp Dockerfile entrypoint.sh init-config.sh /path/to/pihole-dot-doh/
cp -r config/ /path/to/pihole-dot-doh/config/
cp -r .github/ /path/to/pihole-dot-doh/.github/

# 2. Remove the old hook script (no longer needed)
rm -f /path/to/pihole-dot-doh/after-pihole-start.sh

# 3. Build and test
docker buildx build --platform linux/amd64 -t pihole-dot-doh-test .
docker run -d --name pihole-test -p 53:53/tcp -p 53:53/udp -p 80:80/tcp \
  -e FTLCONF_webserver_api_password='test' pihole-dot-doh-test

# 4. Verify
docker exec pihole-test redis-cli -s /tmp/redis.sock ping              # PONG
docker exec pihole-test dig @127.0.0.1 -p 5335 example.com             # NOERROR
docker exec pihole-test dig @127.0.0.1 -p 5335 example.com +dnssec     # ad flag
docker exec pihole-test redis-cli -s /tmp/redis.sock CONFIG GET maxmemory-policy  # allkeys-lfu
docker inspect --format='{{.State.Health.Status}}' pihole-test          # healthy

# 5. Test graceful shutdown (verify RDB save)
docker stop pihole-test    # tini -g sends SIGTERM to all processes
docker start pihole-test   # Redis loads warm cache from dump.rdb
```

## Host-Level Prerequisites (from debugging session)

Verify sysctl buffer sizes on the Docker host match Unbound's `so-rcvbuf: 8m` / `so-sndbuf: 8m`:
```bash
sysctl net.core.rmem_max   # should be >= 8388608
sysctl net.core.wmem_max   # should be >= 8388608
```

## Resume Context

- All source files are in `proposed-dockerfile-changes/`, `proposed-pihole-changes/`, `proposed-redis-unbound-changes/`
- The debugging session transcript is at `~/Downloads/dns-stack-changes.md`
- `CHANGELOG.md` in this folder has the full per-file merge rationale
- The reference project (adguardhome-unbound-redis) is at `../adguardhome-unbound-redis/`
- Next step: copy these files into the actual pihole-dot-doh repo and build/test
