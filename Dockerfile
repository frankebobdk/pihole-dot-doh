# =========================
# Stage 1: build Unbound
# =========================
FROM alpine:3.22 AS unbound-build

ARG UNBOUND_VERSION=1.24.1

RUN apk update && apk upgrade && \
    apk add --no-cache \
        build-base \
        openssl-dev \
        expat-dev \
        libcap-dev \
        libevent-dev \
        hiredis-dev \
        perl \
        linux-headers \
        curl \
        ca-certificates

RUN curl -L "https://nlnetlabs.nl/downloads/unbound/unbound-${UNBOUND_VERSION}.tar.gz" -o /tmp/unbound.tar.gz && \
    tar -xzf /tmp/unbound.tar.gz -C /tmp && \
    cd /tmp/unbound-${UNBOUND_VERSION} && \
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
    make -j"$(nproc)" && make install DESTDIR=/tmp/unbound-out

# =========================
# Stage 2: final (Pi-hole)
# =========================
FROM pihole/pihole:latest

# Pi-hole image er Alpine + s6-overlay
# Installer runtime afhængigheder og Redis
RUN apk update && apk upgrade && \
    apk add --no-cache \
        hiredis \
        redis \
        libevent \
        libcap \
        libexpat \
        openssl \
        curl \
        nano

# Kopiér Unbound fra build-stage
COPY --from=unbound-build /tmp/unbound-out/ /

# Opret dirs til logs/konfig
RUN mkdir -p /config /config_default /var/log/unbound /var/log/pihole && \
    chmod 755 /config_default /var/log/unbound /var/log/pihole

# --- Konfigurationsseeding (dine filer) ---
COPY config/ /config_default/
RUN chmod -R 755 /config_default && \
    find /config_default -type d -exec chmod 755 {} \;

# --- s6 services for Redis og Unbound ---
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

# (valgfrit) simple finish-scripts så s6 restarter ved exit
COPY --chown=root:root <<'EOF' /etc/services.d/unbound/finish
#!/bin/sh
exit 0
EOF
RUN chmod +x /etc/services.d/unbound/finish

COPY --chown=root:root <<'EOF' /etc/services.d/redis/finish
#!/bin/sh
exit 0
EOF
RUN chmod +x /etc/services.d/redis/finish

# Dit init-script kan stadig bruges til at kopiere defaults første gang
COPY init-config.sh /usr/local/bin/init-config.sh
RUN chmod +x /usr/local/bin/init-config.sh

# Kør init-config.sh ved container start via s6 'cont-init.d'
RUN mkdir -p /etc/cont-init.d
COPY --chown=root:root <<'EOF' /etc/cont-init.d/10-init-config
#!/usr/bin/execlineb -P
with-contenv
/usr/local/bin/init-config.sh
EOF
RUN chmod +x /etc/cont-init.d/10-init-config

# Eksponer relevante porte
EXPOSE 53/tcp 53/udp 67/udp 68/udp 80/tcp 443/tcp

# Pi-hole v6 styres via FTLCONF_* (upstream = lokal Unbound; DNSSEC off i FTL)
ENV TZ="Europe/Copenhagen" \
    FTLCONF_dns_upstreams="127.0.0.1#5335" \
    FTLCONF_dns_listeningMode="all" \
    FTLCONF_dns_dnssec="false" \
    FTLCONF_webserver_port="80" \
    FTLCONF_webserver_tls="true" \
    # Sæt et stærkt pwd i runtime (compose secrets/vars)
    FTLCONF_webserver_api_password="CHANGE_ME" \
    # Lad Unbound/Redis håndtere caching (valgfrit at nulstille FTL-cache)
    FTLCONF_dns_cache_size="0"

# HEALTHCHECK – mod HTTP UI (tilpas til https hvis du håndhæver TLS)
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
  CMD curl -fsS http://localhost:80/admin/ > /dev/null || exit 1

# VIGTIGT: behold Pi-hole's ENTRYPOINT/CMD (s6 init). Ingen CMD override her.
