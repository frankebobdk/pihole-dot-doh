# =========================
# Stage 1: Build Unbound
# =========================
FROM alpine:3.22 AS unbound-build

ARG UNBOUND_VERSION=1.24.1

# Build Unbound in single optimized layer
RUN apk update && apk upgrade && \
    # Install build dependencies
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
    # Install hiredis-dev from edge/main for cachedb support
    apk add --no-cache --repository https://dl-cdn.alpinelinux.org/alpine/edge/main \
        hiredis-dev && \
    # Download and build Unbound
    curl -L "https://nlnetlabs.nl/downloads/unbound/unbound-${UNBOUND_VERSION}.tar.gz" -o unbound.tar.gz && \
    tar -xzf unbound.tar.gz && \
    cd unbound-${UNBOUND_VERSION} && \
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
    make -j$(nproc) && \
    make install DESTDIR=/tmp/unbound-out && \
    # Cleanup
    cd .. && \
    rm -rf unbound-${UNBOUND_VERSION} unbound.tar.gz

# =========================
# Stage 2: Pi-hole with Redis and Unbound
# =========================
FROM pihole/pihole:latest

ARG UNBOUND_VERSION=1.24.1

# Install all dependencies in single optimized layer
RUN apk update && apk upgrade && \
    # Install runtime dependencies
    apk --no-cache add \
        nano \
        curl \
        openssl \
        libexpat \
        libcap \
        libevent \
        ca-certificates && \
    # Install hiredis from edge/main
    apk --no-cache --repository https://dl-cdn.alpinelinux.org/alpine/edge/main add \
        hiredis && \
    # Install redis from edge/community
    apk --no-cache --repository https://dl-cdn.alpinelinux.org/alpine/edge/community add \
        redis && \
    # Create necessary directories with proper permissions
    mkdir -p /config /config_default /var/log/unbound /var/log/pihole && \
    chmod 755 /config_default /var/log/unbound /var/log/pihole && \
    # Cleanup
    rm -rf /var/cache/apk/* /tmp/* /var/tmp/*

# Copy Unbound binaries from build stage
COPY --from=unbound-build /tmp/unbound-out/ /

# Copy configuration files (done separately for better layer caching)
COPY config/ /config_default/
RUN chmod -R 755 /config_default && \
    find /config_default -type d -exec chmod 755 {} \;

# Copy and setup initialization script
COPY init-config.sh /usr/local/bin/init-config.sh
RUN chmod +x /usr/local/bin/init-config.sh

# --- s6 services for Redis and Unbound ---
# Redis service
RUN mkdir -p /etc/services.d/redis
COPY --chown=root:root <<'EOF' /etc/services.d/redis/run
#!/usr/bin/execlineb -P
with-contenv
s6-setuidgid root
redis-server /config/redis/redis.conf
EOF
RUN chmod +x /etc/services.d/redis/run

# Unbound service
RUN mkdir -p /etc/services.d/unbound
COPY --chown=root:root <<'EOF' /etc/services.d/unbound/run
#!/usr/bin/execlineb -P
with-contenv
s6-setuidgid root
unbound -d -c /config/unbound/unbound.conf
EOF
RUN chmod +x /etc/services.d/unbound/run

# Simple finish scripts for service restart
COPY --chown=root:root <<'EOF' /etc/services.d/redis/finish
#!/bin/sh
exit 0
EOF
RUN chmod +x /etc/services.d/redis/finish

COPY --chown=root:root <<'EOF' /etc/services.d/unbound/finish
#!/bin/sh
exit 0
EOF
RUN chmod +x /etc/services.d/unbound/finish

# Init script via s6 cont-init.d
RUN mkdir -p /etc/cont-init.d
COPY --chown=root:root <<'EOF' /etc/cont-init.d/10-init-config
#!/usr/bin/execlineb -P
with-contenv
/usr/local/bin/init-config.sh
EOF
RUN chmod +x /etc/cont-init.d/10-init-config

# Expose ports efficiently (grouped by function)
EXPOSE \
    # DNS services
    53/tcp 53/udp \
    # DHCP services
    67/udp 68/udp \
    # HTTP/HTTPS services
    80/tcp 443/tcp

# Set environment variables for Pi-hole v6
ENV TZ="Europe/Copenhagen" \
    FTLCONF_dns_upstreams="127.0.0.1#53" \
    FTLCONF_dns_listeningMode="all" \
    FTLCONF_dns_dnssec="false" \
    FTLCONF_webserver_port="80" \
    FTLCONF_webserver_tls="true" \
    FTLCONF_webserver_api_password="CHANGE_ME" \
    FTLCONF_dns_cache_size="0" \
    PATH="/usr/local/bin:$PATH"

# Healthcheck against Pi-hole web UI and services
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:80/admin/ && \
        redis-cli ping && \
        unbound-control status || exit 1

# IMPORTANT: Keep Pi-hole's s6-overlay entrypoint intact
# No CMD override needed - Pi-hole handles init
