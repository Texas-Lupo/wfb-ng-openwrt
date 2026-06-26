# wfb-ng GS cluster host (manager/aggregator + wfb-cli).
# Build context is the sibling wfb-ng checkout (pinned at commit e8033cf, the same
# source the CPE510 firmware was built from, so node/host protocols match):
#   docker build -t wfb-cluster-test -f cluster-test/Dockerfile ../wfb-ng
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential libpcap-dev libsodium-dev libevent-dev \
      python3 python3-pip python3-setuptools \
      python3-twisted python3-pyroute2 python3-serial python3-msgpack \
      python3-jinja2 python3-yaml \
      iw socat iproute2 openssh-client procps iputils-ping ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Match the CPE510 firmware build (versions.env) so wfb version strings line up.
ARG WFB_VERSION=2025.06.25
ARG WFB_COMMIT=e8033cf

COPY Makefile setup.py version.py README.md /src/wfb-ng/
COPY src     /src/wfb-ng/src
COPY wfb_ng  /src/wfb-ng/wfb_ng
COPY scripts /src/wfb-ng/scripts
WORKDIR /src/wfb-ng

RUN make all_bin VERSION="$WFB_VERSION" COMMIT="$WFB_COMMIT" \
    && install -m755 wfb_rx wfb_tx wfb_tx_cmd wfb_tun wfb_keygen /usr/bin/ \
    && VERSION="$WFB_VERSION" COMMIT="$WFB_COMMIT" OMIT_DATA_FILES=1 \
       pip install --break-system-packages --no-deps .

WORKDIR /etc
ENTRYPOINT ["wfb-server"]
