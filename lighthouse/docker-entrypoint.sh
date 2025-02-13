#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R lhconsensus:lhconsensus /var/lib/lighthouse
  exec gosu lhconsensus docker-entrypoint.sh "$@"
fi


# Because we're oh-so-clever with + substitution and maxpeers, we may have empty args. Remove them
__strip_empty_args() {
  local __arg
  __args=()
  for __arg in "$@"; do
    if [[ -n "$__arg" ]]; then
      __args+=("$__arg")
    fi
  done
}


if [[ -n "${JWT_SECRET}" ]]; then
  echo -n "${JWT_SECRET}" > /var/lib/lighthouse/beacon/ee-secret/jwtsecret
  echo "JWT secret was supplied in .env"
fi

if [[ -O /var/lib/lighthouse/beacon/ee-secret ]]; then
  # In case someone specifies JWT_SECRET but it's not a distributed setup
  chmod 777 /var/lib/lighthouse/beacon/ee-secret
fi
if [[ -O /var/lib/lighthouse/ee-secret/jwtsecret ]]; then
  chmod 666 /var/lib/lighthouse/beacon/ee-secret/jwtsecret
fi

if [[ "${NETWORK}" =~ ^https?:// ]]; then
  echo "Custom testnet at ${NETWORK}"
  repo=$(awk -F'/tree/' '{print $1}' <<< "${NETWORK}")
  branch=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f1)
  config_dir=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f2-)
  echo "This appears to be the ${repo} repo, branch ${branch} and config directory ${config_dir}."
  # For want of something more amazing, let's just fail if git fails to pull this
  set -e
  if [[ ! -d "/var/lib/lighthouse/beacon/testnet/${config_dir}" ]]; then
    mkdir -p /var/lib/lighthouse/beacon/testnet
    cd /var/lib/lighthouse/beacon/testnet
    git init --initial-branch="${branch}"
    git remote add origin "${repo}"
    git config core.sparseCheckout true
    echo "${config_dir}" > .git/info/sparse-checkout
    git pull origin "${branch}"
  fi
  bootnodes="$(awk -F'- ' '!/^#/ && NF>1 {print $2}' "/var/lib/lighthouse/beacon/testnet/${config_dir}/bootstrap_nodes.yaml" | paste -sd ",")"
  set +e
  __network="--testnet-dir=/var/lib/lighthouse/beacon/testnet/${config_dir} --boot-nodes=${bootnodes}"
else
  __network="--network=${NETWORK}"
fi


# Assume we're not zk-enabled
__engine="--execution-endpoint ${EL_NODE} --execution-jwt /var/lib/lighthouse/beacon/ee-secret/jwtsecret"

case "${NODE_TYPE}" in
  archive)
    echo "Lighthouse archive node without pruning"
    __prune="--prune-blobs=false"
    ;;
  full|pruned)
    __prune=""
    ;;
  pruned-with-zkproofs)
    if [[ ! "${NETWORK}" = "mainnet" ]]; then
      echo "Lighthouse with zkProof verification only works on mainnet, as far as Eth Docker is aware."
      echo "Aborting."
      sleep 30
      exit 1
    fi
    echo "Lighthouse node with zkProof verification. HIGHLY experimental."
    echo "Please make sure that you have edited \".env\" and changed:"
    echo "CL_EXTRAS=--boot-nodes enr:-Oy4QJgMz9S1Eb7s13nKIbulKC0nvnt7AEqbmwxnTdwzptxNCGWjc9ipteUaCwqlu2bZDoNz361vGC_IY4fbdkR1K9iCDeuHYXR0bmV0c4gAAAAAAAAABoNjZ2MEhmNsaWVudNGKTGlnaHRob3VzZYU4LjAuMYRldGgykK1TLOsGAAAAAEcGAAAAAACCaWSCdjSCaXCEisV68INuZmSEzCxc24RxdWljgiMpiXNlY3AyNTZrMaEDEIWq41UTcFUgL8LRletpbIwrrpxznIMN_F5jRgatngmIc3luY25ldHMAg3RjcIIjKIR6a3ZtAQ"
    echo "LH_SRC_BUILD_TARGET=ethproofs/zkattester-demo"
    echo "LH_SRC_REPO=https://github.com/ethproofs/lighthouse"
    echo "LH_DOCKERFILE=Dockerfile.source"
    echo "MEV_BOOST=true"
    echo "MEV_BUILD_FACTOR=100"
    echo "And have source-built Lighthouse with \"./ethd update\""
    echo "A PBS sidecar needs to be in COMPOSE_FILE, and MEV relays need to be configured"
    echo "Note the bootnodes ENR may have changed, check on the zkEVM attesting Telegram group!"
    __prune=""
    __engine="--execution-proofs"
    ;;
  *)
    echo "ERROR: The node type ${NODE_TYPE} is not known to Eth Docker's Lighthouse implementation."
    sleep 30
    exit 1
    ;;
esac

# Check whether we should rapid sync
if [[ -n "${CHECKPOINT_SYNC_URL}" ]]; then
  __checkpoint_sync="--checkpoint-sync-url=${CHECKPOINT_SYNC_URL}"
  echo "Checkpoint sync enabled"
  if [[ "${NODE_TYPE}" = "archive" ]]; then
    __prune+=" --reconstruct-historic-states --genesis-backfill --disable-backfill-rate-limiting"
  fi
else
  __checkpoint_sync="--allow-insecure-genesis-sync"
fi

# Check whether we should use MEV Boost
if [[ "${MEV_BOOST}" = "true" ]]; then
  __mev_boost="--builder ${MEV_NODE:-http://mev-boost:18550}"
  echo "MEV Boost enabled"
else
  __mev_boost=""
fi

# Check whether we should send stats to beaconcha.in
if [[ -n "${BEACON_STATS_API}" ]]; then
  __beacon_stats="--monitoring-endpoint https://beaconcha.in/api/v1/client/metrics?apikey=${BEACON_STATS_API}&machine=${BEACON_STATS_MACHINE}"
  echo "Beacon stats API enabled"
else
  __beacon_stats=""
fi

if [[ "${IPV6}" = "true" ]]; then
  echo "Configuring Lighthouse to listen on IPv6 ports"
  echo "IPv6 ENR will be auto-discovered. Please make sure the v6 P2P ports are reachable \"from Internet\""
  __ipv6="--listen-address :: --port6 ${CL_P2P_PORT:-9000} --enr-udp6-port ${CL_P2P_PORT:-9000} --quic-port6 ${CL_QUIC_PORT:-9001}"
else
  __ipv6=""
fi

__strip_empty_args "$@"
set -- "${__args[@]}"

# Traces
if [[ "${COMPOSE_FILE}" =~ (grafana\.yml|grafana-rootless\.yml) ]]; then
  __trace="--telemetry-collector-url http://tempo:4317 --telemetry-service-name lighthouse"
# These may become default in future. Here so Lighthouse doesn't murder itself in the meantime
  export OTEL_TRACES_SAMPLER=parentbased_traceidratio
  export OTEL_TRACES_SAMPLER_ARG=0.01
  export OTEL_EXPORTER_OTLP_INSECURE=true
else
  __trace=""
fi

if [[ -f /var/lib/lighthouse/beacon/prune-marker ]]; then
  rm -f /var/lib/lighthouse/beacon/prune-marker
  if [[ "${NODE_TYPE}" = "archive" ]]; then
    echo "Lighthouse is an archive node. Not attempting to prune state: Aborting."
    exit 1
  fi
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec lighthouse db prune-states ${__network} --datadir /var/lib/lighthouse --confirm
else
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" ${__network} ${__mev_boost} ${__checkpoint_sync} ${__engine} ${__prune} ${__beacon_stats} ${__trace} ${__ipv6} ${CL_EXTRAS}
fi
