#!/usr/bin/env bash
# Run the wfb-ng cluster host in Docker. --network host so the node (192.168.1.1)
# can reach server_address (192.168.1.10) and the aggregator binds the host's IP.
#
#   cluster-test/wfb.sh --profiles gs --gen-init 192.168.1.1   # print node init script
#   cluster-test/wfb.sh --profiles gs --cluster manual         # run the aggregator
#   cluster-test/wfb.sh --profiles gs --cluster manual &       # ... in background
#
# wfb-cli (stats UI) is in the same image:
#   docker run --rm -it --network host -v "$PWD/cluster-test/wifibroadcast.cfg:/etc/wifibroadcast.cfg:ro" \
#       --entrypoint wfb-cli wfb-cluster-test gs
set -euo pipefail
cd "$(dirname "$0")/.."

# The aggregator host needs a key to decrypt; none is committed to the repo.
# Generate a local (gitignored) keypair on first run -- pair drone.key with the
# air unit. Regenerate by deleting keys/ and rerunning.
if [ ! -f keys/gs.key ]; then
  echo "cluster-test: generating keys/gs.key (+ drone.key) ..." >&2
  mkdir -p keys
  docker run --rm -v "$PWD/keys:/keys" -w /keys --entrypoint wfb_keygen wfb-cluster-test
fi

exec docker run --rm -i --network host \
  --cap-add NET_ADMIN --device /dev/net/tun \
  -v "$PWD/cluster-test/wifibroadcast.cfg:/etc/wifibroadcast.cfg:ro" \
  -v "$PWD/keys/gs.key:/etc/gs.key:ro" \
  wfb-cluster-test "$@"
