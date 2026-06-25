#!/usr/bin/env bash
# Build the minimal wfb-ng CPE510 firmware in two Docker stages:
#   package  -> OpenWrt SDK compiles the wfb-ng .apk (+ qemu FEC self-test)
#   image    -> OpenWrt ImageBuilder assembles the per-variant CPE510 images
# All inputs are pinned in versions.env.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck disable=SC1091
. ./versions.env

SDK_IMAGE="wfbng-sdk:${OPENWRT_VERSION}"
IB_IMAGE="wfbng-ib:${OPENWRT_VERSION}"
IMG_PACKAGES="wfb-ng iw -wpad-basic-mbedtls -dnsmasq -odhcpd -ppp -ppp-mod-pppoe -firewall4 -nftables -kmod-nft-core -kmod-nft-nat -kmod-nft-offload"
# --network host: the OpenWrt builds fetch sources; use the host's resolver/network.
DOCKER_RUN=(docker run --rm --network host -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD:/work")

build_sdk_image() {
  docker build -t "$SDK_IMAGE" \
    --build-arg OPENWRT_VERSION="$OPENWRT_VERSION" \
    --build-arg OPENWRT_TARGET="$OPENWRT_TARGET" \
    --build-arg OPENWRT_SUBTARGET="$OPENWRT_SUBTARGET" \
    -f docker/Dockerfile.sdk docker
}

build_ib_image() {
  docker build -t "$IB_IMAGE" \
    --build-arg OPENWRT_VERSION="$OPENWRT_VERSION" \
    --build-arg OPENWRT_TARGET="$OPENWRT_TARGET" \
    --build-arg OPENWRT_SUBTARGET="$OPENWRT_SUBTARGET" \
    -f docker/Dockerfile.imagebuilder docker
}

cmd_test() {
  echo "=== launcher tests ==="
  sh feed/net/wfb-ng/tests/test_launcher.sh
}

cmd_package() {
  build_sdk_image
  mkdir -p build/packages
  "${DOCKER_RUN[@]}" \
    -e WFB_REPO="$WFB_REPO" -e WFB_COMMIT="$WFB_COMMIT" -e WFB_VERSION="$WFB_VERSION" \
    "$SDK_IMAGE" sh -ec '/work/docker/sdk-build.sh && /work/docker/sdk-fectest.sh'
}

cmd_image() {
  build_ib_image
  ls build/packages/wfb-ng-*.apk >/dev/null 2>&1 || { echo "Run './build.sh package' first."; exit 1; }
  rm -rf build/overlay && mkdir -p build/overlay/etc
  if [ -d files ]; then cp -a files/. build/overlay/; fi
  rm -f build/overlay/.gitkeep
  cp keys/gs.key build/overlay/etc/gs.key
  mkdir -p output
  "${DOCKER_RUN[@]}" \
    -e PROFILES="$CPE510_PROFILES" -e PACKAGES="$IMG_PACKAGES" \
    "$IB_IMAGE" sh -ec '/work/docker/ib-build.sh'
  echo "Images in ./output:"; ls -lh output/
}

case "${1:-all}" in
  test)    cmd_test ;;
  package) cmd_package ;;
  image)   cmd_image ;;
  all)     cmd_test; cmd_package; cmd_image ;;
  *) echo "usage: $0 {test|package|image|all}" >&2; exit 1 ;;
esac
