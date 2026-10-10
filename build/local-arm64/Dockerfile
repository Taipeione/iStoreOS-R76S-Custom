FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential clang flex bison gawk gettext \
    git libelf-dev libncurses-dev libssl-dev \
    python3 python3-dev python3-pyelftools \
    python3-setuptools rsync swig time unzip \
    squashfs-tools util-linux zlib1g-dev \
    file wget curl xsltproc zstd pigz \
    ca-certificates ccache \
    patch pkg-config xz-utils bzip2 \
    openssl fdisk jq \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash builder

USER builder
WORKDIR /home/builder
