ARG FRM='pihole/pihole'
ARG TAG='latest'

FROM debian:bullseye as unbound

ARG UNBOUND_VERSION=1.19.3
ARG UNBOUND_SHA256=3ae322be7dc2f831603e4b0391435533ad5861c2322e34a76006a9fb65eb56b9
ARG UNBOUND_DOWNLOAD_URL=https://nlnetlabs.nl/downloads/unbound/unbound-1.19.3.tar.gz

WORKDIR /tmp/src

RUN build_deps="curl gcc libc-dev libevent-dev libexpat1-dev libnghttp2-dev make libssl-dev" && \
    set -x && \
    apt-get update && apt-get install -y --no-install-recommends \
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

FROM debian:bullseye as stubby_builder

RUN apt-get update && apt-get install -y \
    libyaml-dev \
    libuv1-dev \
    check \
    git \
    cmake \
    libidn2-dev \
    libsystemd-dev \
    libev-dev \
    libssl-dev \
    libunbound-dev \
    libuv1-dev:amd64 \
    wget \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -M stubby && usermod -L stubby && usermod -a -G stubby stubby

# Install CMake 3.20
WORKDIR /tmp
RUN wget https://github.com/Kitware/CMake/releases/download/v3.20.0/cmake-3.20.0.tar.gz && \
    tar -zxvf cmake-3.20.0.tar.gz && \
    cd cmake-3.20.0 && \
    export CXX=g++ && \
    export CXXFLAGS=-std=c++11 && \
    ./bootstrap -- -DCMAKE_CXX_FLAGS=-std=c++11 && \
    make -j$(nproc) && \
    make install && \
    rm -rf /tmp/cmake-3.20.0.tar.gz /tmp/cmake-3.20.0

RUN git clone https://github.com/getdnsapi/getdns.git /tmp/getdns
WORKDIR /tmp/getdns
RUN git checkout master && git submodule update --init && \
    mkdir build && \
    cd build && \
    cmake -DBUILD_STUBBY=ON .. && \
    make && \
    make install

FROM ${FRM}:${TAG}
ARG FRM
ARG TAG
ARG TARGETPLATFORM

RUN mkdir -p /usr/local/etc/unbound

COPY --from=unbound /usr/local/sbin/unbound* /usr/local/sbin/
COPY --from=unbound /usr/local/lib/libunbound* /usr/local/lib/
COPY --from=unbound /usr/local/etc/unbound/* /usr/local/etc/unbound/

COPY --from=stubby_builder /usr/local/bin/stubby* /usr/local/bin/

RUN apt-get update && \
    apt-get install -y bash nano curl wget libssl-dev && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

ADD scripts /temp

RUN groupadd unbound \
    && useradd -g unbound unbound \
    && /bin/bash /temp/install.sh \
    && rm -rf /temp/install.sh 

VOLUME ["/config"]

RUN echo "$(date "+%d.%m.%Y %T") Built from ${FRM} with tag ${TAG}" >> /build_date.info
