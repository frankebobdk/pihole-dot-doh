# =========================
# Stage 1: Build Unbound
# =========================
FROM alpine:3.22 AS unbound-build

ARG UNBOUND_VERSION=1.24.1

# Build Unbound in single optimized layer
RUN apk update && apk upgrade && \
    apk add --no-cache --virtual .build-deps \
        build-base \
        openssl-dev \
        expat-dev \
        libcap-dev \
        libevent-dev \
        perl \
        linux-headers \
        curl \
        ca-certificates && \
    # hiredis headers for cachedb (edge/main)
    apk add --no-cache --repository https://dl-cdn.alpinelinux.org/alpine/edge/main \
        hiredis-dev && \
    # Download and build Unbound
    curl -L "https://nlnetlabs.nl/downloads/unbound/unbound-${UNBOUND_VERSION}.tar.gz" -o unbound.tar.gz && \
    tar -xzf unbound.tar.gz && \
    cd "unbound-${UNBOUND_VERSION}" && \
    ./configure \
        --with-libhiredis \
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
    make install DESTDIR=/tmp/unbound-out && \
    cd .. && rm -rf "unbound-${UNBOUND_VERSION}" unbound.tar.gz

# =========================
# Stage 2: Pi-hole with Redis and Unbound
# =========================
FROM pihole/pihole:latest

ARG UNBOUND_VERSION=1.24.1

# Install runtime deps (Alpine-based Pi-hole image)
RUN apk update && apk upgrade && \
    apk add --no-cache \
        nano \
        curl \
        openssl \
        libexpat \
        libcap \
        libevent \
        ca-certificates \
        procps \
        bash && \
    # hiredis (edge/main) + redis (edge/community)
    apk add --no-cache --repository https://dl-cdn.alpinelinux.org/alpine/edge/main hiredis && \
    apk add --no-cache --repository https://dl-cdn.alpinelinux.org/alpine/edge/community redis && \
    # Folders
    mkdir -p /config /config_default /var/log/unbound /var/log/pihole && \
    chmod 755 /config_default /var/log/unbound /var/log/pihole && \
    rm -rf /var/cache/apk/* /tmp/* /var/tmp/*

# Copy Unbound from build stage
COPY --from=unbound-build /tmp/unbound-out/ /

# Copy default config payload (your repo should contain /config_default/{unbound,redis,...})
COPY config/ /config_default/
RUN chmod -R 755 /config_default && find /config_default -type d -exec chmod 755 {} \;

# Init script (idempotent copy of defaults on first run)
COPY init-config.sh /usr/local/bin/init-config.sh
RUN chmod +x /usr/local/bin/init-config.sh && sed -i 's/\r$//' /usr/local/bin/init-config.sh || true

# Hook that starts init + redis + unbound in parallel with Pi-hole
# (Make sure this file exists next to the Dockerfile)
COPY after-pihole-start.sh /usr/local/bin/after-pihole-start.sh
RUN set -eux; \
    chmod +x /usr/local/bin/after-pihole-start.sh; \
    sed -i 's/\r$//' /usr/local/bin/after-pihole-start.sh || true; \
    # Locate Pi-hole start script robustly
    START_SH="$(command -v start.sh || true)"; \
    if [ -z "$START_SH" ]; then \
      for cand in /usr/bin/start.sh /start.sh /usr/local/bin/start.sh; do \
        [ -f "$cand" ] && START_SH="$cand" && break; \
      done; \
    fi; \
    echo "Using start script: ${START_SH}"; \
    [ -n "$START_SH" ] || (echo "start.sh not found in image" >&2; exit 1); \
    # Insert our hook right after the shebang so it always runs, in background
    # NOTE: keep the ampersand escaped so sed doesn't treat it specially
    sed -i '1a /usr/local/bin/after-pihole-start.sh \&' "$START_SH"; \
    # Verify insertion
    grep -n 'after-pihole-start.sh' "$START_SH"

# Networking
EXPOSE \
    53/tcp 53/udp \
    67/udp 68/udp \
    80/tcp 443/tcp 443/udp \
    853/tcp 853/udp 5443/tcp 5443/udp \
    6379/tcp 5053/tcp

# Runtime env
ENV XDG_CONFIG_HOME=/config \
    PATH="/usr/local/bin:${PATH}"

# Simple healthcheck that doesn't require unbound-control remote-control
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=5 CMD \
  sh -c 'curl -fsS http://127.0.0.1/admin/ >/dev/null 2>&1' && \
  sh -c 'redis-cli -h 127.0.0.1 ping | grep -q PONG' && \
  sh -c 'pgrep -x unbound >/dev/null' || exit 1

# IMPORTANT:
# - We DO NOT override ENTRYPOINT. Pi-hole's /usr/bin/start.sh remains PID 1.
# - Our hook runs in background and starts init-config + redis + unbound.
