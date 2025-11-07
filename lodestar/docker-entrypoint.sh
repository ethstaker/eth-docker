#!/usr/bin/env bash

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R lsconsensus:lsconsensus /var/lib/lodestar
  exec gosu lsconsensus docker-entrypoint.sh "$@"
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


# Remove old low-entropy token, related to Sigma Prime security audit
# This detection isn't perfect - a user could recreate the token without ./ethd update
if [[ -f /var/lib/lodestar/consensus/api-token.txt  && "$(date +%s -r /var/lib/lodestar/consensus/api-token.txt)" -lt "$(date +%s --date="2023-05-02 09:00:00")" ]]; then
    rm /var/lib/lodestar/consensus/api-token.txt
fi

if [ ! -f /var/lib/lodestar/consensus/api-token.txt ]; then
    __token=api-token-0x$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)
    echo "$__token" > /var/lib/lodestar/consensus/api-token.txt
fi

if [ -n "${JWT_SECRET}" ]; then
  echo -n "${JWT_SECRET}" > /var/lib/lodestar/consensus/ee-secret/jwtsecret
  echo "JWT secret was supplied in .env"
fi

if [[ -O "/var/lib/lodestar/consensus/ee-secret" ]]; then
  # In case someone specifies JWT_SECRET but it's not a distributed setup
  chmod 777 /var/lib/lodestar/consensus/ee-secret
fi
if [[ -O "/var/lib/lodestar/consensus/ee-secret/jwtsecret" ]]; then
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
  if [ ! -d "/var/lib/lodestar/consensus/testnet/${config_dir}" ]; then
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
if [ "${MEV_BOOST}" = "true" ]; then
  __mev_boost="--builder --builder.url=${MEV_NODE:-http://mev-boost:18550}"
  echo "MEV Boost enabled"
else
  __mev_boost=""
fi

# Check whether we should send stats to beaconcha.in
if [ -n "${BEACON_STATS_API}" ]; then
  __beacon_stats="--monitoring.endpoint https://beaconcha.in/api/v1/client/metrics?apikey=${BEACON_STATS_API}&machine=${BEACON_STATS_MACHINE}"
  echo "Beacon stats API enabled"
else
  __beacon_stats=""
fi

# Check whether we should rapid sync
if [ -n "${CHECKPOINT_SYNC_URL}" ]; then
  if [ "${ARCHIVE_NODE}" = "true" ]; then
    echo "Lodestar archive node cannot use checkpoint sync: Syncing from genesis."
    __checkpoint_sync="--chain.archiveBlobEpochs Infinity --serveHistoricalState"
  else
    __checkpoint_sync="--checkpointSyncUrl=${CHECKPOINT_SYNC_URL}"
    echo "Checkpoint sync enabled"
  fi
else
  __checkpoint_sync=""
fi
if [ "${MINIMAL_NODE}" = "true" ]; then
  if [ ! -d /var/lib/lodestar/consensus/chain-db ]; then  # It's a fresh sync - pruneHistory is too intense to run on an existing DB
    touch /var/lib/lodestar/consensus/prune-marker
  fi
fi

if [ -f /var/lib/lodestar/consensus/prune-marker ]; then  # This gets set above
  __checkpoint_sync+=" --chain.pruneHistory"
fi

if [ "${IPV6}" = "true" ]; then
  echo "Configuring Lodestar to listen on IPv6 ports"
  __ipv6="--listenAddress 0.0.0.0 --listenAddress6 :: --port6 ${CL_P2P_PORT:-9000}"
# ENR discovery on v6 is not yet working, likely too few peers. Manual for now
  __ipv6_pattern="^[0-9A-Fa-f]{1,4}:" # Sufficient to check the start
  set +e
  __public_v6=$(wget -6 -q -O- ifconfig.me)
  set -e
  if [[ "$__public_v6" =~ $__ipv6_pattern ]]; then
    __ipv6+=" --enr.ip6 ${__public_v6}"
  fi
else
  __ipv6="--listenAddress 0.0.0.0"
fi

__strip_empty_args "$@"
set -- "${__args[@]}"

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${__ipv6} ${__network} ${__mev_boost} ${__beacon_stats} ${__checkpoint_sync} ${CL_EXTRAS}
