# Consolidated Changelog

Merged from three independent audit sessions into a single production-ready configuration.

**Priority order:** DNS resolution speed > security > maintainability > image size

---

## Architecture: tini + entrypoint.sh (from Session 1)

Replaces the sed hook injection approach with explicit service orchestration:

- **tini** as PID 1 for proper signal handling and zombie reaping
- **entrypoint.sh** starts Redis, Unbound, then `exec`s Pi-hole's `start.sh`
- Eliminates fragile `sed` injection into Pi-hole's start script
- Eliminates `after-pihole-start.sh` hook and its `sleep 2` delay

---

## Dockerfile

| Decision | Source | Rationale |
|----------|--------|-----------|
| tini + entrypoint.sh architecture | Session 1 | Explicit orchestration, no sed injection |
| Selective binary copy (4 binaries) | Session 1 | Smaller image, no man pages/headers/docs |
| Dedicated unbound user | Session 1 | Security: least-privilege |
| Alpine 3.23 build ARG | Session 1 | Parameterized, easy to update |
| CRLF-to-LF conversion on scripts | Session 1 | Windows compatibility |
| Healthcheck: `redis-cli -s /tmp/redis.sock` | Session 3 | TCP port disabled, must use Unix socket |
| Removed `6379/tcp` from EXPOSE | Session 3 | Port no longer listening |
| Single `sh -c` healthcheck | New fix | Correct exit code propagation for all checks |

**Discarded:**
- Session 2's sed hook injection and `COPY --from=unbound-build /tmp/unbound-out/ /` (copies everything)
- Session 2's hardcoded `alpine:3.22`

---

## entrypoint.sh

| Decision | Source | Rationale |
|----------|--------|-----------|
| Base script structure | Session 1 | Only source for entrypoint approach |
| `set -eu` (was `set -e`) | Session 2 pattern | Catches undefined variable bugs |
| Socket-poll loop (was `sleep 1`) | New fix | Deterministic wait — polls `/tmp/redis.sock` every 100ms, max 5s |
| `--daemonize no` flag on redis-server | Session 1 | Overrides config file, prevents double-fork under tini |

---

## init-config.sh

| Decision | Source | Rationale |
|----------|--------|-----------|
| Full script | Session 1 | Most robust: stderr redirect on `ls`, `chown -R root:root /config`, proper upgrade logic with manifest |

Session 1 is a superset of Sessions 2 and 3. No changes needed.

---

## redis.conf

| Decision | Source | Rationale |
|----------|--------|-----------|
| `allkeys-lfu` eviction | Session 3 | DNS follows power-law distribution; LFU keeps popular domains cached |
| `hz 100` | Session 3 | Faster background task processing, negligible CPU cost |
| `port 0` (TCP disabled) | Session 3 | Unbound uses Unix socket only; removes attack surface |
| `maxmemory-samples 5` | Session 3 | Sufficient for LFU, less CPU per eviction |
| `slowlog-log-slower-than 1000` | Session 3 | Catches >1ms operations (was 10ms) |
| `daemonize no` | New fix | **Critical:** Session 3 had `daemonize yes` which causes double-fork zombie under tini |
| Removed ~70 lines dead config | Session 3 | Replica, AOF, data-structure encoding — none used |
| Lazy-free operations enabled | Sessions 1+3 | Non-blocking memory reclamation |

**Discarded from Session 1:**
- `allkeys-lru` (LFU is better for DNS workloads)
- `hz 10` (slower background processing)
- `port 6379` (unnecessary TCP attack surface)
- `maxmemory-samples 10` (overkill for LFU)
- Replica, AOF, and data-structure encoding settings

---

## unbound.conf

| Decision | Source | Rationale |
|----------|--------|-----------|
| `verbosity: 1` | Session 3 | Level 2 logs every query synchronously — measurable I/O latency |
| `cache-min-ttl: 0` | Session 3 | `serve-expired` + `prefetch` handle latency; 0 ensures correct CDN failover |
| `aggressive-nsec: yes` | Session 3 | Synthesize NXDOMAIN from NSEC records — free speed for DNSSEC-signed domains |
| `minimal-responses: yes` | Session 3 | Strip unnecessary sections, smaller UDP packets |
| `rrset-roundrobin: yes` | Session 3 | Rotate RRsets for load distribution, zero cost |
| `use-caps-for-id: yes` | Session 3 | 0x20 encoding defense against cache poisoning |
| English-only comments | Session 3 | Consistency |

**Discarded from Session 1:**
- `verbosity: 2` (I/O bottleneck)
- `cache-min-ttl: 300` (delays CDN failover)
- Commented-out thread/slab experiments (`TEST FORKED`, `DEFAULT` blocks)
- Danish comments

---

## cache.conf

| Decision | Source | Rationale |
|----------|--------|-----------|
| Clean version | Session 3 | Same functional values, no debate comments or old/new markers |

**Discarded from Session 1:** Danish comments, `#OLD`/`#NEW` markers, ChatGPT/Claude debate comments.

---

## dnssec.conf (new file)

| Decision | Source | Rationale |
|----------|--------|-----------|
| All three sessions identical | Sessions 1/2/3 | Using Session 3's version (period after "root trust anchor." in comment) |

This file is new to pihole-dot-doh. Previously, the validator module was loaded but had no trust anchor — making DNSSEC validation a no-op. `init-config.sh` auto-deploys this to existing users on upgrade.

---

## forward-queries.conf

| Decision | Source | Rationale |
|----------|--------|-----------|
| IPv6 Cloudflare addresses commented out | Session 3 | `do-ip6: no` means IPv6 forwarders timeout on every cache miss |

**Discarded from Session 1:** IPv6 addresses uncommented (causes latency from timeouts).

---

## .github/workflows/image.yml

| Decision | Source | Rationale |
|----------|--------|-----------|
| Full workflow | Session 2 | Only source for CI/CD; multi-arch, dual registry |

---

## Cross-Session Conflicts Resolved

| Conflict | Resolution |
|----------|------------|
| Session 1 `daemonize no` in redis.conf vs Session 3 `daemonize yes` | `daemonize no` — tini manages the process; double-fork creates zombies |
| Session 1 `sleep 1` Redis wait vs robustness | Socket-poll loop — deterministic, max 5s |
| Session 1 `set -e` vs Session 2 `set -eu` | `set -eu` — catches undefined variable bugs |
| Session 1 `allkeys-lru` vs Session 3 `allkeys-lfu` | `allkeys-lfu` — DNS workloads follow power-law distribution |
| Session 1 `cache-min-ttl: 300` vs Session 3 `cache-min-ttl: 0` | `0` — `serve-expired` + `prefetch` already handle latency |
| Session 1 `verbosity: 2` vs Session 3 `verbosity: 1` | `1` — per-query logging causes measurable I/O latency |
| Session 1 IPv6 active vs Session 3 IPv6 commented | Commented — `do-ip6: no` causes IPv6 forwarder timeouts |
| Session 1+2 healthcheck `redis-cli -h 127.0.0.1` vs Session 3 Unix socket | Unix socket — TCP port is disabled |
