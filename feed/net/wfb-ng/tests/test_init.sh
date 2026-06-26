#!/bin/sh
# Stub-based tests for the procd init script (wfb-ng.init). We stub the procd
# helpers and the launcher, source the script's functions (the rc.common shebang
# is a no-op when sourced), and assert the supervised instances it registers.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
INIT="$HERE/../files/wfb-ng.init"
fail=0
TMP=$(mktemp -d)
LOG="$TMP/log"; : > "$LOG"

# Stub procd helpers -> log every call.
procd_open_instance() { echo "open_instance $*" >> "$LOG"; }
procd_set_param() { echo "set_param $*" >> "$LOG"; }
procd_close_instance() { echo "close_instance" >> "$LOG"; }
procd_add_reload_trigger() { :; }

# Stub launcher -> log mon-up/mon-down instead of touching the radio.
LAUNCH="$TMP/wfb-ng.sh"
printf '#!/bin/sh\necho "launcher $*" >> "%s"\nexit 0\n' "$LOG" > "$LAUNCH"
chmod +x "$LAUNCH"
export WFB_LAUNCHER="$LAUNCH"

CONF="$TMP/wfb-ng.conf"
cat > "$CONF" <<'EOF'
LINK_ID=7669206
HOST_ADDR=192.168.1.10
RX_STREAMS="0:10000 16:10001 32:10002"
TX_PORTS="11001 11002"
EOF
export WFB_CONF="$CONF"

assert() { if grep -q -- "$1" "$LOG"; then echo "ok - $2"; else echo "NOT ok - $2 (missing: $1)"; fail=1; fi; }
refute() { if grep -q -- "$1" "$LOG"; then echo "NOT ok - $2 (present: $1)"; fail=1; else echo "ok - $2"; fi; }

# Load the init script's functions and register the instances.
. "$INIT"
start_service

assert "launcher mon-up" "monitor vif brought up first"
assert "open_instance rx-0" "video forwarder instance"
assert "set_param command wfb_rx -f -c 192.168.1.10 -u 10000 -p 0 -i 7669206 -R 2097152 mon0" "video forwarder command"
assert "open_instance rx-16" "mavlink forwarder instance"
assert "open_instance rx-32" "tunnel forwarder instance"
assert "open_instance tx-11001" "mavlink injector instance"
assert "set_param command wfb_tx -I 11001 -R 2097152 mon0" "mavlink injector command"
assert "open_instance tx-11002" "tunnel injector instance"
assert "set_param respawn" "respawn enabled"
refute "set_param command wfb_rx.*-K" "no key in forwarder command"
refute "set_param command wfb_tx.*-K" "no key in injector command"

# stop_service tears the monitor vif back down.
: > "$LOG"
stop_service
assert "launcher mon-down" "monitor vif torn down on stop"

rm -rf "$TMP"
[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
