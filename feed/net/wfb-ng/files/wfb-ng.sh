#!/bin/sh
# Minimal on-demand wfb-ng launcher for a single-card OpenWrt cluster NODE.
# The node forwards raw 802.11 to the aggregator host (which holds the key and
# decrypts) and injects raw frames the host sends back -- no key on the device.
# Mirrors the multi-stream node profile: video + mavlink + tunnel.
# POSIX sh / busybox ash only (no bash on the device).

WFB_CONF="${WFB_CONF:-/etc/wfb-ng.conf}"
WFB_RUN_DIR="${WFB_RUN_DIR:-/var/run}"

# Defaults (overridable via $WFB_CONF)
PHY="phy0"
MON="mon0"
CHANNEL="132"
BW="HT20"
REG="US"
TXPOWER=""
LINK_ID="7669206"
RCV_BUF="2097152"
HOST_ADDR="192.168.1.10"
# Downlink forwarders -- one "radio_port:host_udp_port" per stream:
#   0=video  16=mavlink  32=tunnel
RX_STREAMS="0:10000 16:10001 32:10002"
RX_EXTRA_ARGS=""
# Uplink injectors -- one local UDP port per stream (host injects raw frames):
#   11001=mavlink  11002=tunnel  (empty disables the uplink)
TX_PORTS="11001 11002"
TX_EXTRA_ARGS=""

[ -f "$WFB_CONF" ] && . "$WFB_CONF"

PID_FILE="$WFB_RUN_DIR/wfb-ng.pids"

setup_mon() {
    iw dev "$MON" del 2>/dev/null
    # 'otherbss' lets monitor mode receive frames not addressed to a local BSS,
    # which wfb-ng's injected traffic is. Fall back if this iw rejects flags-at-add.
    iw phy "$PHY" interface add "$MON" type monitor flags otherbss 2>/dev/null \
        || iw phy "$PHY" interface add "$MON" type monitor || return 1
    ip link set "$MON" up || return 1
    iw reg set "$REG"
    iw dev "$MON" set channel "$CHANNEL" "$BW" || return 1
    [ -n "$TXPOWER" ] && iw dev "$MON" set txpower fixed "$TXPOWER"
    return 0
}

# True if any PID we recorded is still alive.
running() {
    [ -f "$PID_FILE" ] || return 1
    while read -r pid; do
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
    done < "$PID_FILE"
    return 1
}

start() {
    if running; then
        echo "wfb-ng: already running (use restart)" >&2
        exit 1
    fi
    mkdir -p "$WFB_RUN_DIR"
    : > "$PID_FILE"
    setup_mon || { echo "wfb-ng: monitor setup failed" >&2; exit 1; }

    # Forwarders: relay raw 802.11 off the monitor vif to the aggregator host.
    # Each forwarder carries one radio port (wfb-ng filters by link_id+radio_port).
    for s in $RX_STREAMS; do
        rp=${s%%:*}; up=${s#*:}
        wfb_rx -f -c "$HOST_ADDR" -u "$up" -p "$rp" -i "$LINK_ID" -R "$RCV_BUF" $RX_EXTRA_ARGS "$MON" &
        echo $! >> "$PID_FILE"
    done

    # Injectors: inject raw frames the host sends to each local UDP port.
    for p in $TX_PORTS; do
        wfb_tx -I "$p" -R "$RCV_BUF" $TX_EXTRA_ARGS "$MON" &
        echo $! >> "$PID_FILE"
    done

    echo "wfb-ng: started"
}

stop() {
    if [ -f "$PID_FILE" ]; then
        pids=$(cat "$PID_FILE")
        # Signal all, wait briefly for graceful exit, then force-kill stragglers
        # so the monitor vif is released before we tear it down.
        for pid in $pids; do kill "$pid" 2>/dev/null; done
        i=0
        while [ "$i" -lt 3 ]; do
            alive=0
            for pid in $pids; do kill -0 "$pid" 2>/dev/null && alive=1; done
            [ "$alive" -eq 0 ] && break
            i=$((i + 1)); sleep 1
        done
        for pid in $pids; do kill -9 "$pid" 2>/dev/null; done
        rm -f "$PID_FILE"
    fi
    iw dev "$MON" del 2>/dev/null
    echo "wfb-ng: stopped"
}

status() {
    if [ -f "$PID_FILE" ] && running; then
        while read -r pid; do
            [ -n "$pid" ] || continue
            if kill -0 "$pid" 2>/dev/null; then
                echo "pid $pid: running"
            else
                echo "pid $pid: dead"
            fi
        done < "$PID_FILE"
    else
        echo "wfb-ng: stopped"
    fi
    iw dev "$MON" info 2>/dev/null || echo "$MON: absent"
}

case "${1:-}" in
    start) start ;;
    stop) stop ;;
    restart) stop; start ;;
    status) status ;;
    # mon-up/mon-down let the procd init script reuse the monitor-vif setup
    # (channel/reg/txpower) without duplicating it; procd supervises the
    # wfb_rx/wfb_tx instances itself.
    mon-up)
        # Idempotent: if the vif already exists, leave it alone. A redundant
        # init-script `start` would otherwise del+recreate mon0 underneath the
        # running wfb_rx/wfb_tx instances (brief vif churn).
        if iw dev "$MON" info >/dev/null 2>&1; then
            echo "wfb-ng: $MON already up"
        else
            setup_mon || { echo "wfb-ng: monitor setup failed" >&2; exit 1; }
            echo "wfb-ng: $MON up"
        fi
        ;;
    mon-down) iw dev "$MON" del 2>/dev/null; echo "wfb-ng: $MON down" ;;
    *) echo "usage: $0 {start|stop|restart|status|mon-up|mon-down}" >&2; exit 1 ;;
esac
