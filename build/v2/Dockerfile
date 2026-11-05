FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential clang flex bison gawk gettext git libelf-dev \
    libncurses-dev libssl-dev python3 python3-dev python3-pyelftools \
    python3-setuptools rsync swig time unzip squashfs-tools util-linux zlib1g-dev \
    file wget curl xsltproc zstd pigz ca-certificates ccache patch pkg-config \
    xz-utils bzip2 openssl fdisk jq libfdt-dev device-tree-compiler \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /work
RUN useradd --create-home --uid 1000 builder && mkdir -p /work/r76s-build /artifacts && \
    chown -R builder:builder /work /artifacts
COPY entrypoint.sh /usr/local/bin/r76s-v2-entrypoint
RUN chmod 0755 /usr/local/bin/r76s-v2-entrypoint
ENTRYPOINT ["/usr/local/bin/r76s-v2-entrypoint"]
