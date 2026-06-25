# wfb-ng firmware for TP-Link CPE510

Minimal OpenWrt firmware that turns a TP-Link CPE510 into a single-card
wfb-ng **ground-station receiver** (with an optional uplink). It runs nothing
at boot; you SSH in, configure, and start it on demand.

- OpenWrt **25.12** (`ath79/generic`), CPE510 **v1/v2/v3**.
- Ships `wfb_rx` + `wfb_tx` built from `gilankpam/wfb-ng@swfec`, an on-demand
  launcher, a baked **test key** (insecure — see *Keys*), and SSH for config.
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
- `drone.key` — copy this to your **air unit** (it pairs with the baked `gs.key`).

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
2. `ssh root@192.168.1.1`
3. Edit `/etc/wfb-ng.conf` to match your air unit (`CHANNEL`, `LINK_ID`, and, if
   you want the uplink, `TX_ENABLED=1`). `HOST_ADDR` defaults to `192.168.1.10`.
4. Start it: `/usr/sbin/wfb-ng.sh start`  (also `stop`, `restart`, `status`).
5. On your computer: decoded downlink arrives as UDP on **192.168.1.10:5600**
   (point your video player / GCS there). For the uplink, send UDP to
   **192.168.1.1:5601**.

There is no autostart. To make it persist across reboots you must add your own
init hook — by design it stays off until you start it.

## Keys (important)

The image bakes a **fixed, shared, non-unique test key** (`keys/gs.key`) — fine
for bench/PoC, **not secure**. For a real link, regenerate a unique pair and
rebuild:

```sh
cd keys && rm -f gs.key drone.key && ../../wfb-ng/wfb_keygen && cd ..
./build.sh image
```

Install the new `output/drone.key` on the air unit.

## On-device smoke test

```sh
ssh root@192.168.1.1
iw dev                      # radio present (phy0)
/usr/sbin/wfb-ng.sh start
/usr/sbin/wfb-ng.sh status  # wfb_rx running; mon0 present on the channel
```
With the air unit transmitting (matching key / `LINK_ID` / radio port / channel),
on the host: `tcpdump -ni <nic> udp port 5600` should show decoded packets.
