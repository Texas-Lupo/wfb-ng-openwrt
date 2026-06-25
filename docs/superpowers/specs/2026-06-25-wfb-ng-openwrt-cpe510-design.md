# wfb-ng on OpenWrt for TP-Link CPE510 — Design Spec

**Date:** 2026-06-25
**Status:** Approved (pending spec review)
**Topic:** Build a minimal wfb-ng ground-station receiver firmware image for the TP-Link CPE510.

---

## 1. Goal & scope

Produce a **flashable OpenWrt firmware image** for the TP-Link CPE510 that boots as a
**minimal wfb-ng ground-station node**. The node:

- puts its ath9k radio into monitor mode,
- runs `wfb_rx` to decode a wifibroadcast downlink (including the `swfec` software-FEC work
  on the target fork) and forwards the decoded UDP stream to the operator host over the wired LAN,
- optionally runs `wfb_tx` for an uplink, for bidirectional communication, and
- is configured and started **on demand** by the operator host over SSH — there is no boot
  autostart and no service supervisor.

Nothing else ships on the device. The build is reproducible and runs in Docker.

**Explicit non-goals:** no Python/Twisted stack, no multi-card diversity aggregator, no
`wfb-cli` stats UI, no `wfb_tun` IP tunnel, no DHCP/DNS server, no boot-time service, no
per-device unique keys.

---

## 2. Target hardware & platform constraints

| Property | Value |
|---|---|
| Device | TP-Link CPE510 (revisions v1, v2, v3) |
| SoC | Atheros AR9344, MIPS 74Kc, **big-endian**, `mips_24kc` @ 560 MHz |
| RAM | 64 MB |
| Flash | 8 MB SPI-NOR |
| WiFi | AR9344 integrated 802.11n 5 GHz, **ath9k** driver (good monitor-mode + injection support) |
| OpenWrt | **25.12.x** (latest stable; 25.12.4 as of 2026-05), target `ath79/generic` |
| Image profiles | `tplink_cpe510-v1`, `tplink_cpe510-v2`, `tplink_cpe510-v3` (build all three) |
| **Image budget** | **`IMAGE_SIZE = 7680k` (~7.5 MB)** — kernel + rootfs must fit; build fails if exceeded |

The 7.5 MB budget is the central constraint and the reason for a binaries-only design: the
wfb-ng C binaries plus `libsodium`/`libpcap`/`libstdcpp` fit with room to spare, whereas the
Python/Twisted stack would not.

---

## 3. Source of truth

- **Repository:** `https://github.com/gilankpam/wfb-ng` (the user's fork).
- **Branch:** `swfec` (software-FEC `zfex` work not present upstream).
- **Pinned commit:** `e8033cf9cf5a2081447ae45bf441bc68c28a26da` (current `swfec` HEAD).
- The commit is pinned in `versions.env`; the user pushes to the fork before building, and
  bumps the pin to build newer work.
- The OpenWrt package source is fetched via git from this fork/commit — **not** from the
  upstream `svpcom/wfb-ng` feed (which lacks `swfec`) and **not** from the local working tree.

### Cross-compilation note (big-endian MIPS, no SIMD)

The `zfex`/`fec_swfec` software FEC contains SSSE3 (x86) and NEON (ARM) SIMD paths, but
`src/zfex_macros.h` gates them behind architecture detection (`__x86_64__`/`__i386__` and
`__arm__`/`__aarch64__` respectively). On `mips_24kc` both compile out to the scalar path, so
the `-DZFEX_USE_INTEL_SSSE3 -DZFEX_USE_ARM_NEON` flags in the upstream Makefile are inert and
harmless on this target. The scalar path must produce byte-identical FEC results on big-endian
MIPS — verified by the qemu-user check in §9.

---

## 4. On-device components

Kept (installed by the build):

- **`wfb_rx`** and **`wfb_tx`** — built from the fork. `wfb_rx` links `libpcap` (captures from
  the monitor interface); `wfb_tx` injects via a raw `PF_PACKET` socket (no pcap). Both link
  `libsodium` and `libstdcpp`.
- **`iw`** — creates/configures the monitor interface.
- **`kmod-ath9k`** + **`mac80211`** — already in the CPE510 default profile.
- **`dropbear`** (SSH) — kept from defaults; the operator host's configuration channel.
- **`/usr/sbin/wfb-ng.sh`** — launcher (`start`/`stop`/`status`).
- **`/etc/wfb-ng.conf`** — plain shell config (conffile, preserved across sysupgrade).
- **`/etc/gs.key`** — the baked test key.

Removed / excluded:

- `wfb_tun`, `wfb_keygen` (build-time only), all Python/Twisted, `kmod-tun`.
- `wpad` (wifi-auth daemon) — removed so it cannot claim `phy0`; the radio is driven manually
  with `iw`.
- `dnsmasq`, `odhcpd` — no DHCP/DNS.
- `ppp`, `ppp-mod-pppoe` — unused on this node.
- **No `/etc/init.d/wfb-ng`** — no procd integration, no boot autostart.

(Exact default package names to remove — e.g. `wpad-basic-mbedtls`, the `odhcpd` variant — are
confirmed against `make info` on the first ImageBuilder run; see §7.)

---

## 5. Networking

- **LAN (`br-lan`)**: static **`192.168.1.1/24`**, no DHCP server.
- **Operator host**: configured with a static IP on the subnet (convention **`192.168.1.10`**),
  which is also the default `HOST_ADDR` that `wfb_rx` forwards decoded UDP to.
- **SSH**: `dropbear` listens on the LAN; the operator runs `ssh root@192.168.1.1` to configure
  and start the node.
- **Firewall**: **removed** (`firewall4` + `nftables` + the `kmod-nft-*` modules). This is a
  single-purpose appliance with one LAN port (SSH in, UDP forwarded to the directly-connected
  host); the firewall adds no value and reclaims flash. Without it, the LAN is open on that port
  — acceptable for this point-to-point use; re-add `firewall4` if you expose the device further.
- **Wireless**: a shipped `/etc/config/wireless` disables the default radio so `netifd` does not
  create a managed `wlan0` on `phy0`; the launcher then creates a monitor vif directly. (The
  `phy0` device still exists for `iw` because `kmod-ath9k` is loaded.)

---

## 6. Keys

- A **single fixed test keypair** is generated once with `wfb_keygen` and committed to this repo
  under `keys/` (`gs.key` + `drone.key`). This is a shared, non-unique key — trivial pairing for
  a PoC/bench link, **not secure** (the accepted trade-off).
- `keys/gs.key` is baked into the image at **`/etc/gs.key`** (via the ImageBuilder files overlay).
- `keys/drone.key` is the matching artifact for the **air unit**; the build copies it into
  `output/` alongside the images.
- `gs.key` covers **both directions** on the ground side: `crypto_box` uses *(own secret, peer
  public)* for both decrypting the downlink and encrypting the uplink, so the optional `wfb_tx`
  path needs no additional key.
- The README documents regenerating the pair with `wfb_keygen` for a real (secure) link.

---

## 7. Build system (this repo) — Docker, SDK + ImageBuilder

Two-stage, both stages pinned and containerized. Both `docker run` builds use
`--network host` (OpenWrt fetches sources at build time; the host resolver is the reliable one).

1. **SDK stage** — compiles the wfb-ng package (`.apk`) for `ath79/generic` (`mips_24kc`) from
   the fork. A Debian-based Dockerfile downloads the **pinned OpenWrt 25.12.x SDK** tarball for
   `ath79/generic` from `downloads.openwrt.org`, bakes in the `base` + `packages` feeds, then at
   run time installs the custom feed and runs `make package/wfb-ng/compile`.
2. **ImageBuilder stage** — assembles the CPE510 image(s). A Dockerfile downloads the **pinned
   ImageBuilder** for the same version/target; the build drops the stage-1 `.apk` into the
   ImageBuilder's `packages/` dir (auto-indexed via `apk mkndx`) and runs
   `make image PROFILE=<v> PACKAGES=... FILES=... ADD_LOCAL_KEY=1` once per profile.

### OpenWrt 25.12 / apk notes (settled during implementation)

- **25.12 uses the `apk` package format**, not legacy opkg/`.ipk`. The package builds as
  `wfb-ng-<version>-r<rel>.apk`; `ADD_LOCAL_KEY=1` makes the image trust the locally-signed package.
- **`libpcap` lives in the `base` feed** (`src-git --root=package base … openwrt.git`), not the
  `packages` feed; both feeds are baked into the SDK image (as separate layers).
- **`wfb-ng` also exists in the official `packages` feed** (the full upstream version, `25.01`).
  The SDK uses `feeds install -p wfbng` so our fork wins; our version `2025.06.25` also outranks
  `25.01` by apk version order, so the ImageBuilder selects our local package too.

### Repository layout

```
wfb-ng-openwrt/
├── README.md                       # usage, flashing, on-device smoke test, key regen
├── versions.env                    # OPENWRT_VERSION, OPENWRT_TARGET=ath79/generic,
│                                   #   WFB_REPO, WFB_COMMIT, profiles list
├── build.sh                        # orchestrates: SDK build -> ImageBuilder -> output/
├── docker/
│   ├── Dockerfile.sdk
│   └── Dockerfile.imagebuilder
├── feed/
│   └── net/wfb-ng/
│       ├── Makefile                # PKG_SOURCE git=fork@WFB_COMMIT; builds wfb_rx + wfb_tx;
│       │                           #   installs binaries + launcher + conf
│       └── files/
│           ├── wfb-ng.sh           # launcher (start/stop/status)
│           └── wfb-ng.conf         # default config (conffile)
├── files/                          # static rootfs overlay parts (currently empty;
│                                   #   gs.key is staged in at build time)
├── keys/
│   ├── gs.key
│   └── drone.key
└── output/                         # built images (per variant) + drone.key
```

At build time `build.sh` assembles `build/overlay/` (the committed `files/` plus
`keys/gs.key` → `etc/gs.key`) and passes it as `FILES=` to the ImageBuilder. Keeping `phy0`
free for monitor mode relies on OpenWrt's default-disabled wifi + `wpad` removal + the
launcher's own vif teardown (no static `/etc/config/wireless` is shipped — see the plan).

### Package list passed to ImageBuilder

```
PACKAGES="wfb-ng iw -wpad-basic-mbedtls -dnsmasq -odhcpd -ppp -ppp-mod-pppoe \
          -firewall4 -nftables -kmod-nft-core -kmod-nft-nat -kmod-nft-offload"
FILES="build/overlay/"   # staged: committed files/ + keys/gs.key -> etc/gs.key
```

`wfb-ng` pulls `libpcap`, `libsodium`, `libstdcpp` as dependencies; `kmod-ath9k`, `mac80211`,
and `dropbear` come from the profile defaults. The exact removal names are validated on first
build and corrected in `versions.env`/`build.sh` if a default differs.

### Iteration

Change `swfec` (push to fork, bump `WFB_COMMIT`) → re-run `build.sh`. Only the package
recompiles in the SDK stage; the image re-assembles in seconds in the ImageBuilder stage.

---

## 8. Runtime behaviour

### `/etc/wfb-ng.conf` (sourced by the launcher)

| Key | Purpose | Default |
|---|---|---|
| `CHANNEL` | 5 GHz channel number | `149` |
| `BW` | bandwidth: `HT20` / `HT40+` / `HT40-` | `HT20` |
| `REG` | regulatory domain for `iw reg set` | `US` |
| `TXPOWER` | fixed TX power (mBm), empty = driver default | (unset) |
| `LINK_ID` | 24-bit wifibroadcast link id (must match air unit) | `0` |
| `RX_RADIO_PORT` | radio port for the downlink stream | `0` |
| `HOST_ADDR` | operator host IP to forward decoded UDP to | `192.168.1.10` |
| `RX_UDP_PORT` | UDP port on the host for decoded downlink | `5600` |
| `TX_ENABLED` | `1` to also start the uplink | `0` |
| `TX_RADIO_PORT` | radio port for the uplink stream | `1` |
| `TX_UDP_PORT` | local UDP port the host sends uplink data to | `5601` |
| `KEY` | key file path | `/etc/gs.key` |

### `wfb-ng.sh start`

1. Create the monitor interface: `iw phy phy0 interface add mon0 type monitor` (with
   `otherbss`), `ip link set mon0 up`.
2. Apply radio params: `iw reg set $REG`; `iw dev mon0 set channel $CHANNEL $BW`; if `TXPOWER`
   set, `iw dev mon0 set txpower fixed $TXPOWER`.
3. Start downlink (always):
   `wfb_rx -p $RX_RADIO_PORT -i $LINK_ID -c $HOST_ADDR -u $RX_UDP_PORT -K $KEY mon0`
   (backgrounded, pidfile written).
4. If `TX_ENABLED=1`, start uplink:
   `wfb_tx -p $TX_RADIO_PORT -i $LINK_ID -u $TX_UDP_PORT -K $KEY [radio/FEC params] mon0`
   (backgrounded, pidfile written). Radio/FEC tuning flags (`-M` MCS, `-B` bandwidth, `-S/-L`
   STBC/LDPC, `-G` guard interval, `-k/-n` FEC) are exposed as optional conf keys; the exact set
   wired in is finalized during implementation against `wfb_tx`'s options.

`wfb_rx`/`wfb_tx` share `mon0` (one radio, one channel) but use **different radio ports**.

### `wfb-ng.sh stop`

Kill the `wfb_rx`/`wfb_tx` processes via pidfiles and remove `mon0`.

### `wfb-ng.sh status`

Report whether each process is running and show the monitor interface state.

### Operator workflow

1. Set host NIC to `192.168.1.10/24`, plug into the CPE510 LAN/PoE port.
2. `ssh root@192.168.1.1`, edit `/etc/wfb-ng.conf` to match the air unit (`CHANNEL`, `LINK_ID`,
   `HOST_ADDR`, optionally `TX_ENABLED`).
3. `wfb-ng.sh start`.
4. On the host, consume decoded video on `192.168.1.10:5600` (player/GCS); for uplink, send to
   `192.168.1.1:5601`.

The pairing tuple `LINK_ID` + radio ports + key must match the air unit.

---

## 9. Verification

- **Image size**: ImageBuilder fails the build if the rootfs exceeds 7680k; `build.sh`
  additionally asserts each output `.bin` is within budget and reports sizes.
- **Cross-arch FEC sanity (qemu-user)**: cross-compile `fec_swfec_test` (and/or `fec_test`) with
  the SDK toolchain for `mips_24kc` and run it under `qemu-mips` (big-endian) inside the build
  container. This catches endianness or no-SIMD regressions in `zfex`/`fec_swfec` before
  flashing. Build fails if the FEC tests fail.
- **On-device smoke test (documented, manual)** after flashing one unit:
  1. `ssh root@192.168.1.1`; confirm `iw dev` shows the radio and `wfb-ng.sh start` brings up
     `mon0` on the configured channel.
  2. Confirm `wfb_rx`/`wfb_tx` processes are running (`wfb-ng.sh status`).
  3. With the air unit transmitting (matching key/link_id/port/channel), confirm decoded UDP
     arrives at the host (`tcpdump -i <nic> udp port 5600` on `192.168.1.10`).

---

## 10. Risks & things to watch

- **ath9k monitor + injection on AR9344 under OpenWrt mac80211**: well-trodden for wfb-ng, but
  verify `wpad` is genuinely gone / not holding `phy0`, and that the chosen `REG` domain unlocks
  channel 149 and the desired TX power. (Regulatory compliance is the operator's responsibility;
  `REG` defaults to `US` and is configurable.)
- **`swfec`/`zfex` on big-endian MIPS scalar path**: should compile and compute correctly; the
  qemu-user FEC test (§9) de-risks this and must pass.
- **Image budget**: confirmed — the CPE510 sysupgrade is a fixed-layout ~7.8 MB image that fits
  the 7680k partition; the firewall stack is removed (rootfs ~9.6 MiB / 87 packages). Removing
  packages frees rootfs/overlay space, not `.bin` size; trim further defaults if the rootfs ever
  overflows the partition at build time.
- **Default-key security**: the baked test key is shared and non-unique — acceptable for a PoC,
  documented as such, with regeneration instructions for a real link.
- **OpenWrt SDK/ImageBuilder tarball URLs / package default names** for 25.12.x `ath79/generic`:
  pinned and verified on first build; corrected in `versions.env`/`build.sh` if a name differs.

---

## 11. Deliverables

- Reproducible Docker build (`build.sh` + `docker/` + `feed/` + `files/` + `versions.env`).
- Per-variant images in `output/`:
  `openwrt-25.12.x-ath79-generic-tplink_cpe510-v{1,2,3}-squashfs-{sysupgrade,factory}.bin`.
- `output/drone.key` for the air unit.
- `README.md`: build, flash, configure-and-start workflow, on-device smoke test, key regeneration.
