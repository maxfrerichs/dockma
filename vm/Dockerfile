# syntax=docker/dockerfile:1
# Builds the dockma guest: an uncompressed arm64 kernel Image and an lz4
# initramfs. Build with `make guest`; outputs land in vm/out/.

ARG ALPINE=alpine:3.24
ARG GOLANG=golang:1.27-alpine

# --- Kernel ----------------------------------------------------------------
FROM ${ALPINE} AS kernel-src
ARG KERNEL_VERSION=6.18.57
ARG KERNEL_SHA256=5bd9acdc82ec5efc3790ae840e5aaa40dfde7efff261cf6dde902dc570acf98c
ARG MOBY_VERSION=29.9.1
# contrib/check-config.sh at the docker-v${MOBY_VERSION} tag; it runs in this
# stage before the kernel is built, so it is pinned like the sources.
ARG CHECK_CONFIG_SHA256=fda4343e9b50c47896653ca774ccbe9614bfcdb60f080d2b6277baf27efc0a71
RUN apk add --no-cache build-base linux-headers bison flex bc perl openssl-dev elfutils-dev xz bash zstd
WORKDIR /build
RUN wget -q https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz \
 && echo "${KERNEL_SHA256}  linux-${KERNEL_VERSION}.tar.xz" | sha256sum -c - \
 && tar xf linux-${KERNEL_VERSION}.tar.xz && rm linux-${KERNEL_VERSION}.tar.xz \
 && mv linux-${KERNEL_VERSION} linux \
 && wget -q -O /build/check-config.sh https://raw.githubusercontent.com/moby/moby/docker-v${MOBY_VERSION}/contrib/check-config.sh \
 && echo "${CHECK_CONFIG_SHA256}  /build/check-config.sh" | sha256sum -c -

# The kernel's own cpio generator creates device nodes without mknod, which
# BuildKit does not permit.
FROM kernel-src AS cpiotool
RUN gcc -O2 -o /usr/local/bin/gen_init_cpio /build/linux/usr/gen_init_cpio.c

FROM kernel-src AS kernel
WORKDIR /build/linux
COPY kernel/dockma.config /build/dockma.config
RUN make ARCH=arm64 tinyconfig \
 && scripts/kconfig/merge_config.sh -m .config /build/dockma.config \
 && make ARCH=arm64 olddefconfig
# Every fragment option must survive olddefconfig; a dropped one means an
# unmet dependency that would otherwise fail silently at runtime. Every
# disabled one must stay disabled; another option's select can re-enable it.
RUN missing=0; \
    while IFS= read -r line; do \
      case "$line" in \
      CONFIG_*=*) grep -qx "$line" .config || { echo "fragment option not applied: $line"; missing=1; } ;; \
      "# CONFIG_"*" is not set") opt=${line#"# "}; opt=${opt%% *}; \
        if grep -q "^$opt=" .config; then echo "fragment option not disabled: $opt"; missing=1; fi ;; \
      esac; \
    done < /build/dockma.config; \
    exit $missing
COPY kernel/check-docker-config.sh /build/
RUN sh /build/check-docker-config.sh /build/check-config.sh .config
RUN make ARCH=arm64 -j"$(nproc)" Image \
 && mkdir -p /out && cp arch/arm64/boot/Image /out/Image && cp .config /out/kernel.config

# --- Guest agent -----------------------------------------------------------
FROM ${GOLANG} AS agent
WORKDIR /src
COPY agent/go.mod agent/go.sum ./
RUN go mod download
COPY agent/ ./
RUN go vet ./... && go test ./... \
 && CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /out/dockma-agent .

# --- Docker static bundle --------------------------------------------------
FROM ${ALPINE} AS docker
ARG DOCKER_VERSION=29.9.1
ARG DOCKER_SHA256=3e93cc6d1a686456a3b18eefdde26467a837a7a2b257af22e27cba1dbc1b2018
WORKDIR /build
RUN wget -q https://download.docker.com/linux/static/stable/aarch64/docker-${DOCKER_VERSION}.tgz \
 && echo "${DOCKER_SHA256}  docker-${DOCKER_VERSION}.tgz" | sha256sum -c - \
 && tar xzf docker-${DOCKER_VERSION}.tgz \
 && mkdir -p /out \
 && cd docker && cp dockerd containerd containerd-shim-runc-v2 runc docker-proxy docker-init /out/

# --- Root filesystem and initramfs -----------------------------------------
FROM ${ALPINE} AS rootfs
RUN apk add --no-cache busybox-static nftables e2fsprogs e2fsprogs-extra ca-certificates-bundle cpio lz4
WORKDIR /rootfs
# copy_bin copies a dynamically linked musl binary plus the libraries ldd lists.
RUN mkdir -p bin sbin usr/bin usr/sbin lib usr/lib etc/ssl/certs proc sys dev run tmp root var/lib/docker mnt \
 && cp /bin/busybox.static bin/busybox && cp /bin/busybox.static busybox \
 && for applet in $(bin/busybox --list-full); do [ "$applet" = bin/busybox ] || ln -sf /bin/busybox "$applet"; done \
 && copy_bin() { rm -f "./$2"; cp "$1" "./$2"; ldd "$1" | awk '/=>/ {print $3; next} /ld-musl/ {print $1}' | sort -u \
      | while read -r lib; do mkdir -p ".$(dirname "$lib")"; cp -L "$lib" ".$lib"; done; } \
 && copy_bin /usr/sbin/nft usr/sbin/nft \
 && copy_bin /sbin/mke2fs sbin/mke2fs \
 && copy_bin /usr/sbin/resize2fs usr/sbin/resize2fs \
 && copy_bin /sbin/e2fsck sbin/e2fsck \
 && cp /etc/ssl/certs/ca-certificates.crt etc/ssl/certs/
COPY --from=cpiotool /usr/local/bin/gen_init_cpio /usr/local/bin/
COPY --from=docker /out/ usr/bin/
COPY --from=agent /out/dockma-agent usr/bin/dockma-agent
COPY rootfs/ ./
COPY tests/ /tests/
RUN chmod 0755 init etc/init.d/* usr/libexec/dockma-disk usr/libexec/dockma-motd usr/share/udhcpc/default.script \
 && usr/sbin/nft --version && sbin/mke2fs -V && sbin/e2fsck -V \
 && sh /tests/dockma-disk-test.sh /rootfs/usr/libexec/dockma-disk /rootfs/bin/busybox \
 && sh /tests/dockma-motd-test.sh /rootfs/usr/libexec/dockma-motd /rootfs/bin/busybox \
 && mkdir -p /out \
 && printf 'dir /dev 0755 0 0\nnod /dev/console 0600 0 0 c 5 1\nnod /dev/null 0666 0 0 c 1 3\n' > /tmp/devices \
 && { gen_init_cpio /tmp/devices; find . -mindepth 1 | sort | cpio -o -H newc --quiet; } \
    | lz4 -l -9 -q -c >/out/initramfs.cpio.lz4 \
 && du -sh /rootfs /out/initramfs.cpio.lz4

FROM scratch
COPY --from=kernel /out/ /
COPY --from=rootfs /out/ /
# The host refuses a guest whose protocol number differs from its own.
COPY agent/protocol /guest-protocol
