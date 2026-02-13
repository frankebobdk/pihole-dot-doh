# Redis & Unbound Performance Audit — Session Summary

**Date:** 2026-02-13
**Status:** Proposed changes written, awaiting review before applying
**Proposed files:** `../proposed-redis-unbound-changes/`

---

## What Was Done

Full performance audit of Redis and Unbound configurations. All proposed changes were written to `../proposed-redis-unbound-changes/` — nothing in the actual project was modified.

### Files Created

```
../proposed-redis-unbound-changes/
├── redis/redis.conf                      # Optimized Redis config
├── unbound/unbound.conf                  # Optimized main Unbound config
├── unbound/unbound.conf.d/cache.conf     # Unchanged (copied for completeness)
├── unbound/unbound.conf.d/dnssec.conf    # NEW — DNSSEC hardening
├── unbound/unbound.conf.d/forward-queries.conf  # IPv6 addrs commented out
├── after-pihole-start.sh                 # Added DNSSEC anchor init
├── init-config.sh                        # Added upgrade merge for dnssec.conf
├── Dockerfile.healthcheck-patch          # Healthcheck + EXPOSE changes
└── CHANGES.md                            # Full rationale for every change
```

---

## Changes by Priority

### Critical Fix
- **DNSSEC was broken.** `module-config: "validator cachedb iterator"` loads the validator, but no `auto-trust-anchor-file` existed — making validation a no-op. Fixed with new `dnssec.conf`, `unbound-anchor` init in startup script, and upgrade merge logic in `init-config.sh`.

### High Impact
| Change | File | Detail |
|--------|------|--------|
| `allkeys-lru` → `allkeys-lfu` | redis.conf | DNS power-law distribution — LFU keeps popular domains cached through unique-query bursts |
| `aggressive-nsec: yes` | unbound.conf | Synthesizes NXDOMAIN from NSEC records without upstream query |
| IPv6 forward-addrs commented out | forward-queries.conf | `do-ip6: no` caused these to timeout on every cache miss, adding latency |

### Medium Impact
| Change | File | Detail |
|--------|------|--------|
| `verbosity 2` → `1` | unbound.conf | Stops synchronous per-query I/O to stderr |
| `minimal-responses: yes` | unbound.conf | Strips unnecessary authority/additional sections |
| `cache-min-ttl 300` → `0` | unbound.conf | serve-expired + prefetch handle latency; 0 fixes CDN failover |
| `hz 10` → `100` | redis.conf | Faster background eviction/cleanup |
| `port 6379` → `port 0` | redis.conf | TCP disabled — Unix socket only |

### Low Impact
| Change | File | Detail |
|--------|------|--------|
| `rrset-roundrobin: yes` | unbound.conf | Rotates RRsets for load distribution |
| `use-caps-for-id: yes` | unbound.conf | 0x20 anti-poisoning defense |
| `qname-minimisation: yes` | dnssec.conf | Privacy, defense-in-depth |
| `maxmemory-samples 10` → `5` | redis.conf | Sufficient for LFU, less CPU |
| `slowlog-log-slower-than 10000` → `1000` | redis.conf | Catch ops >1ms |

### Cleanup
- Redis: ~70 lines of dead config removed (replica, AOF, pub/sub, TCP-only, data structure thresholds)
- Unbound: removed commented-out thread/slab experiments, standardized comments to English

### Dockerfile
- Healthcheck: `redis-cli -h 127.0.0.1` → `redis-cli -s /tmp/redis.sock`
- EXPOSE: removed `6379/tcp`

---

## How to Apply

### Step 1: Copy proposed files into the project
```bash
cd ~/Documents/GitHub

# Redis
cp proposed-redis-unbound-changes/redis/redis.conf pihole-dot-doh/config/redis/redis.conf

# Unbound
cp proposed-redis-unbound-changes/unbound/unbound.conf pihole-dot-doh/config/unbound/unbound.conf
cp proposed-redis-unbound-changes/unbound/unbound.conf.d/cache.conf pihole-dot-doh/config/unbound/unbound.conf.d/cache.conf
cp proposed-redis-unbound-changes/unbound/unbound.conf.d/dnssec.conf pihole-dot-doh/config/unbound/unbound.conf.d/dnssec.conf
cp proposed-redis-unbound-changes/unbound/unbound.conf.d/forward-queries.conf pihole-dot-doh/config/unbound/unbound.conf.d/forward-queries.conf

# Scripts
cp proposed-redis-unbound-changes/after-pihole-start.sh pihole-dot-doh/after-pihole-start.sh
cp proposed-redis-unbound-changes/init-config.sh pihole-dot-doh/init-config.sh
```

### Step 2: Apply Dockerfile changes manually
See `proposed-redis-unbound-changes/Dockerfile.healthcheck-patch` — two changes:
1. Healthcheck: `redis-cli -h 127.0.0.1` → `redis-cli -s /tmp/redis.sock`
2. EXPOSE: remove `6379/tcp`

### Step 3: Build and verify
```bash
cd ~/Documents/GitHub/pihole-dot-doh

# Build
docker buildx build --platform linux/amd64 -t pihole-dot-doh .

# Run
docker run -d --name pihole-test -p 53:53/tcp -p 53:53/udp -p 80:80/tcp \
  -e FTLCONF_webserver_api_password='test' pihole-dot-doh

# Verify Redis
docker exec pihole-test redis-cli -s /tmp/redis.sock ping
# → PONG

# Verify Unbound
docker exec pihole-test dig @127.0.0.1 -p 5335 example.com
# → NOERROR with A record

# Verify LFU active
docker exec pihole-test redis-cli -s /tmp/redis.sock INFO server | grep maxmemory_policy
# → allkeys-lfu

# Verify DNSSEC
docker exec pihole-test dig @127.0.0.1 -p 5335 example.com +dnssec
# → ad flag in response

# Check logs for errors
docker logs pihole-test 2>&1 | tail -50
```

### Step 4: Cleanup after applying
```bash
rm -rf ~/Documents/GitHub/proposed-redis-unbound-changes
rm ~/Documents/GitHub/pihole-dot-doh/SESSION-redis-unbound-performance-audit.md
```

---

## What Was NOT Changed

| File | Reason |
|------|--------|
| `cache.conf` (functional) | `redis-timeout: 25`, `redis-expire-records: no`, `cachedb-check-when-serve-expired: yes` are all correct |
| Thread count (2) | Appropriate for the workload — no evidence more threads help |
| Memory sizes (256m rrset, 128m msg, 128mb Redis) | Already well-sized |
| Persistence (`save 3600 1`) | Negligible cost on NVMe/ZFS, provides warm cache on restart |

---

## Reference

- Full change rationale: `../proposed-redis-unbound-changes/CHANGES.md`
- Reference project pattern: `../adguardhome-unbound-redis/entrypoint.sh` (DNSSEC anchor init)
