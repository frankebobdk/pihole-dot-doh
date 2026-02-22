# Pi-hole + Redis + Unbound

High-performance DNS setup with Pi-hole, Redis caching, and Unbound recursive resolver.

## Features

- 🛡️ **Pi-hole** - Network-wide ad blocking
- ⚡ **Redis** - Ultra-fast DNS cache via Unbound
- 🔒 **Unbound** - DNSSEC-validating recursive resolver
- 🐳 **Multi-arch** - Supports amd64, arm64

## Quick Start
```bash
docker run -d \
  --name pihole \
  -p 53:53/tcp -p 53:53/udp \
  -p 80:80/tcp \
  -e FTLCONF_webserver_api_password='yourpassword' \
  -v ./config:/config \
  frankebob/pihole-dot-doh:latest
```

## Docker Compose

See [docker-compose.yml](docker-compose.yml) for full example.

## Configuration

Mount `/config` volume with:
- `/config/redis/redis.conf` - Redis configuration
- `/config/unbound/unbound.conf` - Unbound configuration

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TZ` | `Europe/Copenhagen` | Timezone |
| `FTLCONF_webserver_api_password` | `CHANGE_ME` | Admin password |
| `FTLCONF_dns_upstreams` | `127.0.0.1#5335` | Upstream DNS (Unbound) |

## Architecture
```
Client → Pi-hole (:53) → Unbound (:5335, DNSSEC) → Redis Cache → Upstream DoT (Cloudflare)
```
## License

MIT
