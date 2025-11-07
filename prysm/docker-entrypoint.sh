#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R prysmconsensus:prysmconsensus /var/lib/prysm
  exec gosu prysmconsensus docker-entrypoint.sh "$@"
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


if [ -n "${JWT_SECRET}" ]; then
  echo -n "${JWT_SECRET}" > /var/lib/prysm/ee-secret/jwtsecret
  echo "JWT secret was supplied in .env"
fi

if [[ -O "/var/lib/prysm/ee-secret" ]]; then
  # In case someone specifies JWT_SECRET but it's not a distributed setup
  chmod 777 /var/lib/prysm/ee-secret
fi
if [[ -O "/var/lib/prysm/ee-secret/jwtsecret" ]]; then
  chmod 666 /var/lib/prysm/ee-secret/jwtsecret
fi

if [[ "${NETWORK}" =~ ^https?:// ]]; then
  echo "Custom testnet at ${NETWORK}"
  repo=$(awk -F'/tree/' '{print $1}' <<< "${NETWORK}")
  branch=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f1)
  config_dir=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f2-)
  echo "This appears to be the ${repo} repo, branch ${branch} and config directory ${config_dir}."
  # For want of something more amazing, let's just fail if git fails to pull this
  set -e
  if [ ! -d "/var/lib/prysm/testnet/${config_dir}" ]; then
    mkdir -p /var/lib/prysm/testnet
    cd /var/lib/prysm/testnet
    git init --initial-branch="${branch}"
    git remote add origin "${repo}"
    git config core.sparseCheckout true
    echo "${config_dir}" > .git/info/sparse-checkout
    git pull origin "${branch}"
  fi
  bootnodes="$(awk -F'- ' '!/^#/ && NF>1 {print $2}' "/var/lib/prysm/testnet/${config_dir}/bootstrap_nodes.yaml" | paste -sd ",")"
  deploy_block=$(cat "/var/lib/prysm/testnet/${config_dir}/deposit_contract_block.txt")
  set +e
  __network="--chain-config-file=/var/lib/prysm/testnet/${config_dir}/config.yaml --genesis-state=/var/lib/prysm/testnet/${config_dir}/genesis.ssz \
--enable-debug-rpc-endpoints --bootstrap-node=${bootnodes} --contract-deployment-block=${deploy_block}"
else
  __network="--${NETWORK}"
fi

# Check whether we should rapid sync
if [ -n "${CHECKPOINT_SYNC_URL:+x}" ]; then
  __checkpoint_sync="--checkpoint-sync-url=${CHECKPOINT_SYNC_URL}"
  echo "Checkpoint sync enabled"
else
  __checkpoint_sync=""
fi

# Check whether we should use MEV Boost
if [ "${MEV_BOOST}" = "true" ]; then
  __mev_boost="--http-mev-relay=${MEV_NODE:-http://mev-boost:18550}"
  echo "MEV Boost enabled"
  echo "No MEV Build Factor configured: Prysm doesn't support it, or Eth Docker doesn't know how."
else
  __mev_boost=""
fi

if [ "${ARCHIVE_NODE}" = "true" ]; then
  echo "Prysm archive node without pruning"
  __prune="--slots-per-archive-point=32 --blob-retention-epochs=4294967295"
elif [ "${MINIMAL_NODE}" = "true" ]; then
  echo "Prysm node with beacon DB pruning"
  __prune="--beacon-db-pruning"
else
  echo "Prysm node without beacon DB pruning"
  __prune=""
fi

__strip_empty_args "$@"
set -- "${__args[@]}"

if [[ "${NETWORK}" = "sepolia" ]]; then
  GENESIS=/var/lib/prysm/genesis.ssz
  if [ ! -f "$GENESIS" ]; then
    echo "Fetching genesis file for Sepolia testnet"
    curl -fsSL -o "$GENESIS" https://github.com/eth-clients/sepolia/raw/main/metadata/genesis.ssz
  fi
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" "--genesis-state=$GENESIS" ${__network} ${__checkpoint_sync} ${__prune} ${__mev_boost} ${CL_EXTRAS}
elif [[ "${NETWORK}" = "hoodi" ]]; then
  GENESIS=/var/lib/prysm/genesis.ssz
  if [ ! -f "$GENESIS" ]; then
    echo "Fetching genesis file for Hoodi testnet"
    curl -fsSL -o "$GENESIS" https://github.com/eth-clients/hoodi/raw/main/metadata/genesis.ssz
  fi
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" "--genesis-state=$GENESIS" ${__network} ${__checkpoint_sync} ${__prune} ${__mev_boost} ${CL_EXTRAS}
else
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" ${__network} ${__checkpoint_sync} ${__prune} ${__mev_boost} ${CL_EXTRAS}
fi
