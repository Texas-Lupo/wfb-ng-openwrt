#!/bin/sh
# Runs inside the SDK container (as the host uid). Compiles the wfb-ng package
# and copies the built package to /work/build/packages, then checks the binary
# arch. OpenWrt 25.12 builds the apk format (.apk), not legacy .ipk.
set -eu
cd /opt/sdk

grep -q '^src-link wfbng ' feeds.conf 2>/dev/null || echo 'src-link wfbng /work/feed' >> feeds.conf
./scripts/feeds update wfbng
# wfb-ng also exists in the official 'packages' feed (the full upstream version);
# -p wfbng forces OUR fork's package to win the name collision.
./scripts/feeds install -p wfbng -f wfb-ng
./scripts/feeds install libpcap libsodium

grep -q '^CONFIG_PACKAGE_wfb-ng=y' .config 2>/dev/null || echo 'CONFIG_PACKAGE_wfb-ng=y' >> .config
make defconfig
make package/wfb-ng/compile -j"$(nproc)" \
  WFB_REPO="${WFB_REPO}" WFB_COMMIT="${WFB_COMMIT}" WFB_VERSION="${WFB_VERSION}"

mkdir -p /work/build/packages
PKG=$(find bin/packages -name 'wfb-ng-*.apk' | head -n1)
[ -n "$PKG" ] || { echo "ERROR: no wfb-ng .apk produced"; find bin/packages -name 'wfb-ng*' -o -name '*.apk' | head; exit 1; }
cp -v "$PKG" /work/build/packages/

# --- Patched mac80211/ath9k bundle: radiotap DBM_ANTNOISE so wfb-ng reports SNR. ---
# Source comes from the SDK's own base feed (exact 25.12.4 rev), copied into the package
# tree so we can apply our patch and bump PKG_RELEASE. PATCH is applied only if present
# (Task 1 builds stock; Task 2 adds the patch + the release bump).
MAC_SRC=feeds/base/kernel/mac80211
MAC_PKG=package/kernel/mac80211
if [ ! -d "$MAC_PKG" ]; then cp -a "$MAC_SRC" "$MAC_PKG"; fi
if [ -f /work/patches/mac80211/999-ath9k-radiotap-antnoise.patch ]; then
  cp /work/patches/mac80211/999-ath9k-radiotap-antnoise.patch "$MAC_PKG/patches/subsys/"
  sed -i 's/^PKG_RELEASE:=.*/PKG_RELEASE:=3/' "$MAC_PKG/Makefile"
fi
grep -q '^CONFIG_PACKAGE_kmod-ath9k=y' .config 2>/dev/null || echo 'CONFIG_PACKAGE_kmod-ath9k=y' >> .config
make defconfig
make package/kernel/mac80211/compile -j"$(nproc)"
# apk filenames use dashes; the version begins with the kernel version digit, so
# "${k}-[0-9]*" matches kmod-ath9k but NOT kmod-ath9k-common / kmod-ath9k-htc.
for k in kmod-cfg80211 kmod-mac80211 kmod-ath kmod-ath9k kmod-ath9k-common; do
  f=$(find bin -name "${k}-[0-9]*.apk" | head -n1)
  [ -n "$f" ] || { echo "ERROR: $k apk not produced"; exit 1; }
  cp -v "$f" /work/build/packages/
done

# Architecture sanity: the binaries must be big-endian (MSB) MIPS.
BIN=$(find build_dir -type f -name wfb_rx | head -n1)
echo "Checking arch of $BIN"
file "$BIN" | grep -q 'ELF 32-bit MSB.*MIPS' || { echo "ERROR: wfb_rx not big-endian MIPS"; file "$BIN"; exit 1; }
echo "OK: wfb_rx is big-endian MIPS"
