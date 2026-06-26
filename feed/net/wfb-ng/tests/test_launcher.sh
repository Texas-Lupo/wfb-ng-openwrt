#!/bin/sh
# Stub-based tests for wfb-ng.sh. Stubs log "<name> <args>" so we can assert
# the launcher builds the right command lines. POSIX sh only.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
LAUNCHER="$HERE/../files/wfb-ng.sh"
fail=0

setup() {
  TMP=$(mktemp -d)
  BIN="$TMP/bin"; mkdir -p "$BIN"
  LOG="$TMP/log"; : > "$LOG"
  for c in iw ip wfb_rx wfb_tx; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 0\n' "$c" "$LOG" > "$BIN/$c"
    chmod +x "$BIN/$c"
  done
  export PATH="$BIN:$PATH"
  export WFB_CONF="$TMP/wfb-ng.conf"
  export WFB_RUN_DIR="$TMP/run"; mkdir -p "$WFB_RUN_DIR"
  PID_FILE="$WFB_RUN_DIR/wfb-ng.pids"
}
teardown() { rm -rf "$TMP"; }
assert_log() { if grep -q -- "$1" "$LOG"; then echo "ok - $2"; else echo "NOT ok - $2 (missing: $1)"; fail=1; fi; }
refute_log() { if grep -q -- "$1" "$LOG"; then echo "NOT ok - $2 (present: $1)"; fail=1; else echo "ok - $2"; fi; }
# wfb_rx/wfb_tx are launched in the background by the launcher, so their stub
# log lines may land after `start` returns. Poll (up to ~3s) instead of racing.
wait_log() {
  i=0
  while [ "$i" -lt 30 ]; do
    if grep -q -- "$1" "$LOG"; then echo "ok - $2"; return; fi
    i=$((i + 1)); sleep 0.1
  done
  echo "NOT ok - $2 (missing after wait: $1)"; fail=1
}

# Test 1: forwarders -- one wfb_rx -f per stream, no key on a node
setup
cat > "$WFB_CONF" <<'EOF'
CHANNEL=132
BW=HT20
REG=US
LINK_ID=7669206
HOST_ADDR=192.168.1.10
RX_STREAMS="0:10000 16:10001 32:10002"
TX_PORTS=""
EOF
sh "$LAUNCHER" start
assert_log "iw reg set US" "reg domain set"
assert_log "iw phy phy0 interface add mon0 type monitor" "monitor vif created"
assert_log "set channel 132 HT20" "channel/bandwidth set (split)"
wait_log "wfb_rx .*-f .*-c 192.168.1.10 .*-u 10000 .*-p 0 .*-i 7669206 .*mon0" "video forwarder (port 0)"
wait_log "wfb_rx .*-f .*-u 10001 .*-p 16 .*mon0" "mavlink forwarder (port 16)"
wait_log "wfb_rx .*-f .*-u 10002 .*-p 32 .*mon0" "tunnel forwarder (port 32)"
refute_log "wfb_rx .*-K" "no key passed to the node"
refute_log "^wfb_tx " "no injector when TX_PORTS empty"
teardown

# Test 2: injectors -- one wfb_tx -I per uplink port
setup
cat > "$WFB_CONF" <<'EOF'
LINK_ID=7669206
RX_STREAMS="0:10000"
TX_PORTS="11001 11002"
EOF
sh "$LAUNCHER" start
wait_log "wfb_tx .*-I 11001 .*mon0" "mavlink injector (port 11001)"
wait_log "wfb_tx .*-I 11002 .*mon0" "tunnel injector (port 11002)"
refute_log "wfb_tx .*-K" "no key passed to the injector"
teardown

# Test 3: stop kills every tracked process and tears down the monitor vif
setup
: > "$WFB_CONF"
sleep 30 & A=$!; sleep 30 & B=$!
printf '%s\n%s\n' "$A" "$B" > "$PID_FILE"
sh "$LAUNCHER" stop
if kill -0 "$A" 2>/dev/null || kill -0 "$B" 2>/dev/null; then
  echo "NOT ok - stop did not kill all processes"; fail=1; kill "$A" "$B" 2>/dev/null
else
  echo "ok - stop killed all tracked processes"
fi
assert_log "iw dev mon0 del" "monitor vif removed on stop"
teardown

# Test 4: start refuses when already running (re-entrancy guard)
setup
: > "$WFB_CONF"
sleep 30 & FAKE=$!; echo "$FAKE" > "$PID_FILE"
out=$(sh "$LAUNCHER" start 2>&1) || true
if printf '%s' "$out" | grep -q "already running"; then echo "ok - start refused while running"; else echo "NOT ok - start not refused (got: $out)"; fail=1; fi
kill "$FAKE" 2>/dev/null
teardown

# Test 5: mon-up creates the vif when mon0 is absent
setup
: > "$WFB_CONF"
# iw stub: `dev mon0 info` fails (vif absent), everything else succeeds.
printf '#!/bin/sh\necho "iw $*" >> "%s"\ncase "$*" in "dev mon0 info") exit 1;; esac\nexit 0\n' "$LOG" > "$BIN/iw"
out=$(sh "$LAUNCHER" mon-up)
assert_log "iw phy phy0 interface add mon0 type monitor" "mon-up creates vif when absent"
printf '%s' "$out" | grep -q "mon0 up" && echo "ok - reports 'mon0 up'" || { echo "NOT ok - missing 'mon0 up' (got: $out)"; fail=1; }
teardown

# Test 6: mon-up is idempotent -- skips setup when mon0 already exists
setup
: > "$WFB_CONF"
# iw stub: `dev mon0 info` succeeds (vif present).
printf '#!/bin/sh\necho "iw $*" >> "%s"\nexit 0\n' "$LOG" > "$BIN/iw"
out=$(sh "$LAUNCHER" mon-up)
refute_log "interface add mon0" "mon-up does NOT recreate an existing vif"
refute_log "iw dev mon0 del" "mon-up does NOT delete an existing vif"
printf '%s' "$out" | grep -q "already up" && echo "ok - reports 'already up'" || { echo "NOT ok - missing 'already up' (got: $out)"; fail=1; }
teardown

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo "FAILURES"; exit 1; }
