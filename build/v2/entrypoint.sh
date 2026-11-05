#!/bin/sh
set -eu
chown -R builder:builder /work/r76s-build
su -s /bin/sh -c 'git config --global --add safe.directory /openwrt-source && git config --global --add safe.directory /openwrt-source/.git' builder
exec runuser -u builder -- "$@"
