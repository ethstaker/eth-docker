#!/usr/bin/env bash
# A fake "docker" for the macOS CI jobs. Hosted macOS runners have no nested virtualization, so no
# container runtime can start there. This answers the calls that ethd's update, space, config and
# port-check make, so that their shell logic still runs on macOS userland. Anything it does not know
# fails loudly, so that a new Docker call on those paths shows up in CI rather than being faked.

echo "$*" >> "${DOCKER_STUB_LOG:-/dev/null}"

# "compose up" creates DOCKER_STUB_STATE, and the Beacon API only answers after that. Unset, the
# node is down.
node_up() {
  [[ -n "${DOCKER_STUB_STATE:-}" && -e "${DOCKER_STUB_STATE}" ]]
}

# The ENR is fixture_enr from test-port-check.sh: a properly signed record with a private key of 1,
# 203.0.113.42 and 2001:db8::1, UDP 9000 as CL_P2P_PORT. Compact, the way ethd's sed wants it.
identity='{"data":{"peer_id":"16Uiu2HAmStubNode","enr":"enr:-Lm4QH2z7bOXo6bYgd6JCZjFF2DzrbFb_OXwGR7Cqse_ytCaSxpqtJ9IO4mO8GB7ryM6T_dptihwtUqUkbJZdqokVwQHgmlkgnY0gmlwhMsAcSqDaXA2kCABDbgAAAAAAAAAAAAAAAGEcXVpY4IjKYVxdWljNoIjjYlzZWNwMjU2azGhAnm-Zn753LusVaBilc6HCwcCm_zbLc4o2VnygVsW-BeYg3RjcIIjKIN1ZHCCIyiEdWRwNoIjjA","p2p_addresses":["/ip4/203.0.113.42/tcp/9000","/ip4/203.0.113.42/udp/9001/quic-v1"],"discovery_addresses":["/ip4/203.0.113.42/udp/9000"],"metadata":{"seq_number":"1","attnets":"0x00","syncnets":"0x00"}}}'
# No connected inbound peers, as on a CI runner, so the plain output points at --troubleshoot.
# The disconnected inbound peer is one ethd must not count.
peers='{"data":[{"peer_id":"16Uiu2HAmOutboundTcp","enr":null,"last_seen_p2p_address":"/ip4/198.51.100.3/tcp/9000","state":"connected","direction":"outbound"},{"peer_id":"16Uiu2HAmOutboundQuic","enr":null,"last_seen_p2p_address":"/ip4/198.51.100.4/udp/9001/quic-v1","state":"connected","direction":"outbound"},{"peer_id":"16Uiu2HAmGoneAway","enr":null,"last_seen_p2p_address":"/ip4/203.0.113.9/tcp/9000","state":"disconnected","direction":"inbound"}],"meta":{"count":3}}'

case "$*" in
  --version)
    echo "Docker version 29.0.0, build stub"
    ;;
  "compose version")
    echo "Docker Compose version v2.40.0"
    ;;
  "compose --help")
    echo "Usage:  docker compose [OPTIONS] COMMAND"
    ;;
  "compose config")  # ethd falls back to the directory name for the project
    exit 1
    ;;
  "compose --profile tools pull"|"compose --profile tools build --pull")
    ;;
  "buildx version")
    echo "github.com/docker/buildx v0.29.0 stub"
    ;;
  images)
    ;;
  "run "*" df -P /dummy")  # 100 GiB available
    echo "Filesystem           1024-blocks      Used Available Capacity Mounted on"
    echo "/dev/vda1              209715200 104857600 104857600  50% /dummy"
    ;;
  "run "*" df -h /dummy")
    echo "Filesystem                Size      Used Available Use% Mounted on"
    echo "/dev/vda1               200.0G    100.0G    100.0G  50% /dummy"
    ;;
  "volume inspect "*)  # No volumes, so ethd skips the migrations that need one
    exit 1
    ;;
  "volume ls "*)
    ;;
  "system df --format "*)
    echo "0B"
    ;;
  "compose up -d --remove-orphans")
    if [[ -n "${DOCKER_STUB_STATE:-}" ]]; then
      touch "${DOCKER_STUB_STATE}"
    fi
    ;;
  "compose exec -T consensus sh -c "*"/eth/v1/node/identity'"*)
    node_up || exit 1
    echo "${identity}"
    ;;
  "compose exec -T consensus sh -c "*"/eth/v1/node/peers'"*)
    node_up || exit 1
    echo "${peers}"
    ;;
  "image ls --format {{.Repository}}:{{.Tag}}")  # So that port-check does not build vc-utils
    echo "vc-utils:local"
    ;;
  "run --rm --network "*" vc-utils:local curl "*)  # The throwaway container finds no client either
    exit 7
    ;;
  *)
    echo "docker-stub: unhandled: $*" >&2
    exit 1
    ;;
esac
