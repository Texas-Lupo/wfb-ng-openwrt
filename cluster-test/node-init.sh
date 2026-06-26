#!/bin/sh
# wfb-ng cluster NODE init for the CPE510 (busybox ash -- OpenWrt has no bash).
#
# Generated from `wfb-server --profiles gs --gen-init 192.168.1.1` and translated
# bash -> ash:  wait -n -> wait,  jobs -p -> tracked PIDs,  dropped the nmcli block.
# Regenerate/adjust if the cluster config (channel, ports, nodes) changes.
#
# Creates wlan0 in monitor mode and forwards raw 802.11 to the GS host; FEC decode
# and decryption happen on the host (gs.key), so no key is needed here.
export LC_ALL=C

SERVER=192.168.1.10        # GS host (this PC, enp12s0)
LINK_ID=7669206            # hash of link_domain 'default'
CHANNEL="132 HT20"         # 5660 MHz (DFS)

PIDS=""
cleanup() { [ -n "$PIDS" ] && kill $PIDS 2>/dev/null; exit; }
trap cleanup INT TERM EXIT

# Fresh monitor vif (OpenWrt >= 24.10 has no wlan0 until created).
for d in mon0 wlan0; do iw dev "$d" del 2>/dev/null || true; done
iw phy phy0 interface add wlan0 type monitor flags otherbss
iw reg set US
ip link set wlan0 up
iw dev wlan0 set channel $CHANNEL

# Forwarders: raw 802.11 -> $SERVER:1000x ; injection listeners on :1100x
wfb_rx -f -c $SERVER -u 10000 -p 0  -i $LINK_ID -R 2097152 wlan0 & PIDS="$PIDS $!"   # video  (downlink)
wfb_rx -f -c $SERVER -u 10001 -p 16 -i $LINK_ID -R 2097152 wlan0 & PIDS="$PIDS $!"   # mavlink rx
wfb_tx -I 11001 -R 2097152 wlan0 & PIDS="$PIDS $!"                                    # mavlink tx (uplink)
wfb_rx -f -c $SERVER -u 10002 -p 32 -i $LINK_ID -R 2097152 wlan0 & PIDS="$PIDS $!"   # tunnel rx
wfb_tx -I 11002 -R 2097152 wlan0 & PIDS="$PIDS $!"                                    # tunnel tx (uplink)

echo "wfb-ng node up: wlan0 monitor ch132, forwarding to $SERVER"
wait
