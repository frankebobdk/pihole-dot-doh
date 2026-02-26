# =========================
# Stage 1: Builder
# =========================
ARG ALPINE_VERSION=3.23
FROM alpine:${ALPINE_VERSION} AS builder

ARG UNBOUND_VERSION=1.24.2
ARG REDIS_VERSION=8.6.1

# Build deps — all from stable repos, zero edge dependencies
RUN apk update && apk upgrade && \
    apk add --no-cache \
        build-base openssl-dev expat-dev libcap-dev libevent-dev \
        perl linux-headers curl ca-certificates

# Download sources
RUN curl -L "https://github.com/redis/redis/archive/refs/tags/${REDIS_VERSION}.tar.gz" -o redis.tar.gz && \
    tar -xzf redis.tar.gz && rm redis.tar.gz && \
    curl -L "https://nlnetlabs.nl/downloads/unbound/unbound-${UNBOUND_VERSION}.tar.gz" -o unbound.tar.gz && \
    tar -xzf unbound.tar.gz && rm unbound.tar.gz

# Build hiredis static from Redis deps/
RUN cd redis-${REDIS_VERSION}/deps/hiredis && \
    make && \
    make PREFIX=/tmp/hiredis-out install && \
    rm -f /tmp/hiredis-out/lib/libhiredis.so*

# Build Unbound (statically linked against hiredis)
RUN cd unbound-${UNBOUND_VERSION} && \
    ./configure \
        --with-libhiredis=/tmp/hiredis-out \
        --with-libexpat=/usr \
        --with-libevent \
        --enable-cachedb \
        --disable-flto \
        --disable-shared \
        --disable-rpath \
        --with-pthreads \
        --prefix=/usr \
        --sysconfdir=/etc \
        --mandir=/usr/share/man \
        --localstatedir=/var && \
    make -j"$(nproc)" && \
    make install DESTDIR=/tmp/unbound-out

# Build Redis
RUN cd redis-${REDIS_VERSION} && \
    make -j"$(nproc)" USE_SYSTEMD=no BUILD_TLS=no && \
    make install PREFIX=/tmp/redis-out/usr

# =========================
# Stage 2: Pi-hole with Redis and Unbound
# =========================
# TODO: Pin to a specific Pi-hole version tag for reproducible builds
FROM pihole/pihole:latest
LABEL org.opencontainers.image.source="https://github.com/frankebobdk/pihole-dot-doh"
LABEL org.opencontainers.image.description="Pi-hole + Redis + Unbound DNS"

# Install runtime deps (Alpine-based Pi-hole image)
# Audit note: nano kept intentionally for in-container config editing. Do not remove in future audits.
# Redis and hiredis built from source (single tarball strategy).
# hiredis is statically linked into Unbound — no runtime .so dependency.
# ARG REDIS_VERSION controls both Redis binaries and hiredis version.
RUN apk update && apk upgrade && \
    apk add --no-cache \
        tini \
        nano \
        curl \
        openssl \
        libexpat \
        libcap \
        libevent \
        ca-certificates \
        procps \
        bash && \
    # Create dedicated unbound user
    addgroup -S unbound && adduser -S -H -G unbound -s /sbin/nologin unbound && \
    # Create DNSSEC root key directory owned by unbound
    mkdir -p /etc/unbound/var && \
    chown -R unbound:unbound /etc/unbound && \
    # Folders
    mkdir -p /config /config_default /var/log/unbound /var/log/pihole /var/lib/redis && \
    chown -R unbound:unbound /var/log/unbound && \
    chmod 755 /config_default /var/log/unbound /var/log/pihole && \
    rm -rf /var/cache/apk/* /tmp/* /var/tmp/*

# Copy only the binaries we need from the build stage (no man pages, headers, docs)
COPY --from=builder /tmp/unbound-out/usr/sbin/unbound /usr/sbin/unbound
COPY --from=builder /tmp/unbound-out/usr/sbin/unbound-anchor /usr/sbin/unbound-anchor
COPY --from=builder /tmp/unbound-out/usr/sbin/unbound-checkconf /usr/sbin/unbound-checkconf
COPY --from=builder /tmp/unbound-out/usr/sbin/unbound-control /usr/sbin/unbound-control

# Copy Redis binaries from builder
COPY --from=builder /tmp/redis-out/usr/bin/redis-server /usr/bin/redis-server
COPY --from=builder /tmp/redis-out/usr/bin/redis-cli /usr/bin/redis-cli

# Copy default config payload
COPY config/ /config_default/
RUN find /config_default -type d -exec chmod 755 {} \; && \
    find /config_default -type f -exec chmod 644 {} \;

# Init script (idempotent copy of defaults on first run)
COPY init-config.sh /usr/local/bin/init-config.sh
RUN chmod +x /usr/local/bin/init-config.sh && sed -i 's/\r$//' /usr/local/bin/init-config.sh

# Entrypoint script (replaces sed hook injection)
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh && sed -i 's/\r$//' /usr/local/bin/entrypoint.sh

# Save Pi-hole start.sh path for entrypoint to exec later
RUN set -eux; \
    START_SH="$(command -v start.sh || true)"; \
    if [ -z "$START_SH" ]; then \
      for cand in /usr/bin/start.sh /start.sh /usr/local/bin/start.sh; do \
        [ -f "$cand" ] && START_SH="$cand" && break; \
      done; \
    fi; \
    echo "Using start script: ${START_SH}"; \
    [ -n "$START_SH" ] || (echo "start.sh not found in image" >&2; exit 1); \
    echo "$START_SH" > /etc/pihole-start-path

# Networking — only ports the container actually serves
# 53  = DNS (TCP + UDP)
# 80  = Pi-hole web admin (HTTP)
# 443 = Pi-hole web admin (HTTPS)
EXPOSE 53/tcp 53/udp 80/tcp 443/tcp

# Runtime env
ENV XDG_CONFIG_HOME=/config \
    PATH="/usr/local/bin:${PATH}"

# Healthcheck — all checks in single sh -c for correct exit code propagation
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=5 CMD \
  sh -c 'curl -fsS http://127.0.0.1/admin/ >/dev/null 2>&1 && redis-cli -s /tmp/redis.sock ping | grep -q PONG && pgrep -x unbound >/dev/null'

# tini as PID 1 for proper signal handling and zombie reaping
ENTRYPOINT ["/sbin/tini", "-g", "--"]
CMD ["/usr/local/bin/entrypoint.sh"]
