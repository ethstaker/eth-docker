#!/usr/bin/env bash

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R lsconsensus:lsconsensus /var/lib/lodestar
  exec gosu lsconsensus docker-entrypoint.sh "$@"
fi


# Because we're oh-so-clever with + substitution and maxpeers, we may have empty args. Remove them
__strip_empty_args() {
  local arg
  __args=()
  for arg in "$@"; do
    if [[ -n "${arg}" ]]; then
      __args+=("${arg}")
    fi
  done
}


if [[ ! -f /var/lib/lodestar/consensus/api-token.txt ]]; then
  token=api-token-0x$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)
  echo "$token" > /var/lib/lodestar/consensus/api-token.txt
fi

if [[ -n "${JWT_SECRET}" ]]; then
  echo -n "${JWT_SECRET}" > /var/lib/lodestar/consensus/ee-secret/jwtsecret
  echo "JWT secret was supplied in .env"
fi

if [[ -O /var/lib/lodestar/consensus/ee-secret ]]; then
  # In case someone specifies JWT_SECRET but it's not a distributed setup
  chmod 777 /var/lib/lodestar/consensus/ee-secret
fi
if [[ -O /var/lib/lodestar/consensus/ee-secret/jwtsecret ]]; then
  chmod 666 /var/lib/lodestar/consensus/ee-secret/jwtsecret
fi

if [[ "${NETWORK}" =~ ^https?:// ]]; then
  echo "Custom testnet at ${NETWORK}"
  repo=$(awk -F'/tree/' '{print $1}' <<< "${NETWORK}")
  branch=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f1)
  config_dir=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f2-)
  echo "This appears to be the ${repo} repo, branch ${branch} and config directory ${config_dir}."
  # For lack of something more sophisticated, let's just fail if git fails to pull this
  set -e
  if [[ ! -d "/var/lib/lodestar/consensus/testnet/${config_dir}" ]]; then
    mkdir -p /var/lib/lodestar/consensus/testnet
    cd /var/lib/lodestar/consensus/testnet
    git init --initial-branch="${branch}"
    git remote add origin "${repo}"
    git config core.sparseCheckout true
    echo "${config_dir}" > .git/info/sparse-checkout
    git pull origin "${branch}"
  fi
  bootnodes="$(awk -F'- ' '!/^#/ && NF>1 {print $2}' "/var/lib/lodestar/consensus/testnet/${config_dir}/bootstrap_nodes.yaml" | paste -sd ",")"
  set +e
  __network="--paramsFile=/var/lib/lodestar/consensus/testnet/${config_dir}/config.yaml --genesisStateFile=/var/lib/lodestar/consensus/testnet/${config_dir}/genesis.ssz \
--bootnodes=${bootnodes} --network.connectToDiscv5Bootnodes --rest.namespace=*"
else
  __network="--network ${NETWORK}"
fi

# Check whether we should use MEV Boost
if [[ "${MEV_BOOST}" = "true" ]]; then
  __mev_boost="--builder --builder.url=${MEV_NODE:-http://mev-boost:18550}"
  echo "MEV Boost enabled"
else
  __mev_boost=""
fi

# Check whether we should send stats to beaconcha.in
if [[ -n "${BEACON_STATS_API}" ]]; then
  __beacon_stats="--monitoring.endpoint https://beaconcha.in/api/v1/client/metrics?apikey=${BEACON_STATS_API}&machine=${BEACON_STATS_MACHINE}"
  echo "Beacon stats API enabled"
else
  __beacon_stats=""
fi

case "${NODE_TYPE}" in
  archive)
    echo "Lodestar archive node without pruning"
    __prune="--chain.archiveBlobEpochs Infinity --serveHistoricalState"
    ;;
  full)
    __prune=""
    ;;
  pruned)
    echo "Lodestar pruned node"
    __prune="--chain.pruneHistory"
    ;;
  *)
    echo "ERROR: The node type ${NODE_TYPE} is not known to Eth Docker's Lodestar implementation."
    sleep 30
    exit 1
    ;;
esac

# Check whether we should rapid sync
if [[ -n "${CHECKPOINT_SYNC_URL}" ]]; then
  if [[ ! "${NODE_TYPE}" = "archive" ]]; then
    __checkpoint_sync="--checkpointSyncUrl=${CHECKPOINT_SYNC_URL}"
    echo "Checkpoint sync enabled"
  else
    echo "Lodestar does not support checkpoint sync for an archive node. Syncing from genesis."
    __checkpoint_sync=""
  fi
else
  __checkpoint_sync=""
fi

if [[ "${IPV6}" = "true" ]]; then
  echo "Configuring Lodestar to listen on IPv6 ports"
  __ipv6="--listenAddress 0.0.0.0 --listenAddress6 :: --port6 ${CL_P2P_PORT:-9000}"
# ENR discovery on v6 is not yet working, likely too few peers. Manual for now
  ipv6_pattern="^[0-9A-Fa-f]{1,4}:" # Sufficient to check the start
  set +e
  public_v6=$(curl -s -6 https://ifconfig.me)
  set -e
  if [[ "${public_v6}" =~ ${ipv6_pattern} ]]; then
    __ipv6+=" --enr.ip6 ${public_v6}"
  fi
else
  __ipv6="--listenAddress 0.0.0.0"
fi

__strip_empty_args "$@"
set -- "${__args[@]}"

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${__ipv6} ${__network} ${__mev_boost} ${__beacon_stats} ${__checkpoint_sync} ${__prune} ${CL_EXTRAS}
