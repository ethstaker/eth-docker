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

# Check whether we should rapid sync
if [[ -n "${CHECKPOINT_SYNC_URL}" ]]; then
  __checkpoint_sync="--checkpoint-sync-url=${CHECKPOINT_SYNC_URL}"
  echo "Checkpoint sync enabled"
  if [[ "${ARCHIVE_NODE}" = "true" ]]; then
    echo "Lighthouse archive node without pruning"
    __prune="--reconstruct-historic-states --genesis-backfill --disable-backfill-rate-limiting --prune-blobs=false"
  else
    __prune=""
  fi
else
  __checkpoint_sync="--allow-insecure-genesis-sync"
  __prune=""
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
  __ipv6="--listen-address :: --port6 ${CL_P2P_PORT:-9000} --enr-udp6-port ${CL_P2P_PORT:-9000} --quic-port6 ${CL_QUIC_PORT:-9001}"
# ENR discovery on v6 is not yet working, likely too few peers. Manual for now
  __ipv6_pattern="^[0-9A-Fa-f]{1,4}:" # Sufficient to check the start
  set +e
  __public_v6=$(curl -6 -s ifconfig.me)
  set -e
  if [[ "$__public_v6" =~ $__ipv6_pattern ]]; then
    __ipv6+=" --enr-address ${__public_v6}"
  fi
else
  __ipv6=""
fi

__strip_empty_args "$@"
set -- "${__args[@]}"

if [[ -f /var/lib/lighthouse/beacon/prune-marker ]]; then
  rm -f /var/lib/lighthouse/beacon/prune-marker
  if [[ "${ARCHIVE_NODE}" = "true" ]]; then
    echo "Lighthouse is an archive node. Not attempting to prune state: Aborting."
    exit 1
  fi
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec lighthouse db prune-states ${__network} --datadir /var/lib/lighthouse --confirm
else
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" ${__network} ${__mev_boost} ${__checkpoint_sync} ${__prune} ${__beacon_stats} ${__ipv6} ${CL_EXTRAS}
fi
