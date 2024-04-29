ARG FRM='pihole/pihole'
ARG TAG='latest'

FROM debian:bullseye as unbound

ARG UNBOUND_VERSION=1.19.3
ARG UNBOUND_SHA256=3ae322be7dc2f831603e4b0391435533ad5861c2322e34a76006a9fb65eb56b9
ARG UNBOUND_DOWNLOAD_URL=https://nlnetlabs.nl/downloads/unbound/unbound-1.19.3.tar.gz

WORKDIR /tmp/src

RUN build_deps="curl gcc libc-dev libevent-dev libexpat1-dev libnghttp2-dev make libssl-dev" && \
    set -x && \
    DEBIAN_FRONTEND=noninteractive apt-get update && apt-get install -y --no-install-recommends \
      $build_deps \
      bsdmainutils \
      ca-certificates \
      ldnsutils \
      libevent-2.1-7 \
      libexpat1 \
      libprotobuf-c-dev \
      protobuf-c-compiler && \
    curl -sSL $UNBOUND_DOWNLOAD_URL -o unbound.tar.gz && \
    echo "${UNBOUND_SHA256} *unbound.tar.gz" | sha256sum -c - && \
    tar xzf unbound.tar.gz && \
    rm -f unbound.tar.gz && \
    cd unbound-${UNBOUND_VERSION} && \
    groupadd unbound && \
    useradd -g unbound -s /dev/null -d /etc unbound && \
    ./configure \
        --disable-dependency-tracking \
        --with-pthreads \
        --with-username=unbound \
        --with-libevent \
        --with-libnghttp2 \
        --enable-dnstap \
        --enable-tfo-server \
        --enable-tfo-client \
        --enable-event-api \
        --enable-subnet && \
    make -j$(nproc) install && \
    apt-get purge -y --auto-remove \
      $build_deps && \
    rm -rf \
        /tmp/* \
        /var/tmp/* \
        /var/lib/apt/lists/*

FROM debian:buster as stubby_builder

RUN apt-get update && apt-get install -y libyaml-dev libssl-dev libtool-bin autoconf git make && \
        apt-get clean && \
        rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/getdnsapi/getdns.git

WORKDIR getdns

# Check out a specific tag or commit
RUN git checkout v1.7.2

RUN git submodule update --init && libtoolize -ci && autoreconf -fi && mkdir build
WORKDIR build
RUN ../configure --without-libidn --without-libidn2 --enable-stub-only --with-stubby && make && make install && ldconfig

FROM ${FRM}:${TAG}
ARG FRM
ARG TAG
ARG TARGETPLATFORM

RUN mkdir -p /usr/local/etc/unbound

COPY --from=unbound /usr/local/sbin/unbound* /usr/local/sbin/
COPY --from=unbound /usr/local/lib/libunbound* /usr/local/lib/
COPY --from=unbound /usr/local/etc/unbound/* /usr/local/etc/unbound/

COPY --from=stubby_builder /usr/local/etc/stubby/stubby.yml /usr/local/etc/stubby/stubby.yml

RUN apt update && \
    apt install -y bash nano curl wget libssl-dev

ADD scripts /temp

RUN groupadd unbound \
    && useradd -g unbound unbound \
    && /bin/bash /temp/install.sh \
    && rm -rf /temp/install.sh 

VOLUME ["/config"]

RUN echo "$(date "+%d.%m.%Y %T") Built from ${FRM} with tag ${TAG}" >> /build_date.info
