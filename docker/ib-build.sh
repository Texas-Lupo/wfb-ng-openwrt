#!/bin/sh
# Runs inside the ImageBuilder container. Adds our locally-built apk to the
# ImageBuilder's local package repo, builds one image per CPE510 profile,
# copies results to /work/output, and asserts the size budget.
#
# OpenWrt 25.12 uses apk: dropping wfb-ng-*.apk into packages/ makes the IB
# regenerate packages.adb (apk mkndx) automatically; ADD_LOCAL_KEY=1 installs
# the local signing pubkey into the image so the local package is trusted.
set -eu
cd /opt/ib

mkdir -p packages
cp /work/build/packages/wfb-ng-*.apk packages/
# Our patched mac80211/ath9k kmods (PKG_RELEASE=4) override the stock -r1 ones.
cp /work/build/packages/kmod-*.apk packages/

for p in $PROFILES; do
  echo "=== building image for $p ==="
  make image PROFILE="$p" PACKAGES="$PACKAGES" FILES=/work/build/overlay ADD_LOCAL_KEY=1
  # Assert the image installed OUR patched kmod-mac80211 (-r4), not the stock -r1.
  man=$(find bin -name "*${p}*.manifest" | head -n1)
  [ -n "$man" ] || { echo "ERROR: no manifest for $p - cannot verify kmod override"; exit 1; }
  echo "--- $p wireless kmods ---"; grep -E '^kmod-(mac80211|ath9k|ath|cfg80211)' "$man" || true
  # The antnoise struct-ABI change spans mac80211 + ath9k, so assert BOTH (plus ath9k-common)
  # are our -r4 and no stock -r1 slipped in (a mixed install would shift the noise offset).
  for k in kmod-mac80211 kmod-ath9k kmod-ath9k-common; do
    awk -v k="$k" '$1==k{if ($0 ~ /-r4$/) ok=1; else bad=1} END{exit !(ok && !bad)}' "$man" \
      || { echo "ERROR: $p: $k is not our -r4 build"; exit 1; }
  done
done

mkdir -p /work/output
find bin -type f \( -name '*cpe510*sysupgrade.bin' -o -name '*cpe510*factory.bin' -o -name '*rocket*sysupgrade.bin' -o -name '*rocket*factory.bin' \) -exec cp -v {} /work/output/ \;

# Image budget: every sysupgrade image must fit the 7680k partition.
max=$((7680 * 1024))
for f in /work/output/*sysupgrade.bin; do
  sz=$(wc -c < "$f")
  echo "$f: $sz bytes (max $max)"
  [ "$sz" -le "$max" ] || { echo "ERROR: $f exceeds $max bytes"; exit 1; }
done
echo "OK: all images within size budget"
