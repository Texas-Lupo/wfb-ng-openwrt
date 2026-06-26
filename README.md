# wfb-ng firmware for TP-Link CPE510

[![build](https://github.com/gilankpam/wfb-ng-openwrt/actions/workflows/build.yml/badge.svg)](https://github.com/gilankpam/wfb-ng-openwrt/actions/workflows/build.yml)

**[⬇ Download the latest firmware](https://github.com/gilankpam/wfb-ng-openwrt/releases/latest)** — built by CI from every push to `master` (rolling `latest` prerelease).

Minimal OpenWrt firmware that turns a TP-Link CPE510 into a single-card
wfb-ng **cluster node** (with an optional uplink). The node forwards raw 802.11
to an aggregator host that holds the key and decrypts — **no key lives on the
device**. It runs nothing at boot; you SSH in, configure, and start it on demand.

- OpenWrt **25.12** (`ath79/generic`), CPE510 **v1/v2/v3**.
- Ships `wfb_rx` + `wfb_tx` built from `gilankpam/wfb-ng@swfec`, an on-demand
  launcher (per-stream forwarders + injectors: video / mavlink / tunnel), and
  SSH for config. No key is baked into the image.
- Design + plan: `docs/superpowers/specs/` and `docs/superpowers/plans/`.

## Build

Requires Docker. All inputs are pinned in `versions.env`.

```sh
./build.sh all       # package (+ qemu FEC self-test) then images
# or individually:
./build.sh package   # compile the wfb-ng .apk + qemu FEC self-test
./build.sh image     # assemble the CPE510 images
```

The first run builds two Docker images (OpenWrt SDK ~3.5 GB, ImageBuilder
~1.7 GB) — it downloads the pinned SDK/ImageBuilder and clones the `base` +
`packages` feeds, then caches all of it. Subsequent builds reuse the images.

Outputs land in `output/`:
- `*tplink_cpe510-v{1,2,3}-squashfs-sysupgrade.bin` — flash from OpenWrt.
- `*tplink_cpe510-v{1,2,3}-squashfs-factory.bin` — flash from TP-Link firmware / TFTP.

To build newer wfb-ng work: push to the fork, set `WFB_COMMIT` in `versions.env`, rerun.

### Notes on OpenWrt 25.12 (apk)

25.12 uses the `apk` package manager. The package is built as
`wfb-ng-<version>-r<rel>.apk`; the ImageBuilder picks it up from its local
`packages/` dir and `ADD_LOCAL_KEY=1` makes the image trust it. `wfb-ng` also
exists in the official `packages` feed (the full upstream build); the SDK uses
`feeds install -p wfbng` so this fork wins, and `libpcap` comes from the `base`
feed. The firewall stack (`firewall4` + `nftables` + `kmod-nft-*`) is removed —
this is a one-port appliance, so it adds no value and frees ~1.6 MiB of rootfs
(installed footprint ~9.6 MiB / 87 packages). The CPE510 sysupgrade image is a
**fixed-layout** ~7.8 MB (tplink-safeloader), so removing packages frees
read-only rootfs/overlay space rather than shrinking the `.bin`; if you add
packages and the rootfs overflows the partition, trimming further defaults is
the lever.

## Flash

Pick the file matching your hardware revision. From stock TP-Link: use the
`-factory.bin` (Pharos web UI or TFTP recovery). From an existing OpenWrt:
`sysupgrade -n <...-sysupgrade.bin>` (use `-n`, do not keep settings).

## Configure & run

1. Set your computer's NIC to a static **192.168.1.10/24** and connect it to the
   CPE510 (PoE LAN port). The device is **192.168.1.1**, no DHCP.
2. On that host, run the wfb-ng **aggregator** — it holds the key and does the
   FEC-decode + decryption. See `cluster-test/` for a ready-made Docker host that
   binds `192.168.1.10` and serves `wfb-cli` stats.
3. `ssh root@192.168.1.1`
4. Edit `/etc/wfb-ng.conf` to match your air unit / aggregator. `CHANNEL` and
   `BW` are separate keys (`132` + `HT20`); set `LINK_ID` to match the link.
   `HOST_ADDR` is the aggregator host (default `192.168.1.10`). The node mirrors
   the standard multi-stream profile — `RX_STREAMS` forwards video/mavlink/tunnel
   (radio ports `0`/`16`/`32` → host UDP `10000`/`10001`/`10002`) and `TX_PORTS`
   are the uplink injector ports (`11001`/`11002`; clear it to disable the uplink).
5. Start it. Two ways:
   - **Supervised (recommended):** `/etc/init.d/wfb-ng start` runs each forwarder
     and injector as a procd instance that auto-respawns on crash. Add
     `/etc/init.d/wfb-ng enable` to also start on boot.
   - **One-shot:** `/usr/sbin/wfb-ng.sh start` (also `stop`, `restart`, `status`)
     for a quick, unsupervised run — don't use both at once.

   The node forwards raw 802.11 to the aggregator on **192.168.1.10:10000-10002**;
   the aggregator decodes and serves the decrypted streams. For the uplink, the
   host injects raw frames to **192.168.1.1:11001-11002**.

Autostart is **off** until you `/etc/init.d/wfb-ng enable` — by design it stays
off otherwise.

## On-device smoke test

```sh
ssh root@192.168.1.1
iw dev                      # radio present (phy0)
/usr/sbin/wfb-ng.sh start
/usr/sbin/wfb-ng.sh status  # forwarders/injectors running; mon0 present on the channel
```
With the air unit transmitting (matching `LINK_ID` / radio port / channel), the
node forwards raw frames to the aggregator host: `tcpdump -ni <nic> udp port 10000`
shows the forwarded video stream, and the aggregator there decrypts it.
