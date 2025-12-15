#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R erigon:erigon /var/lib/erigon
  exec gosu erigon "${BASH_SOURCE[0]}" "$@"
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


if [[ -n "${JWT_SECRET}" ]]; then
  echo -n "${JWT_SECRET}" > /var/lib/erigon/ee-secret/jwtsecret
  echo "JWT secret was supplied in .env"
fi

if [[ ! -f /var/lib/erigon/ee-secret/jwtsecret ]]; then
  echo "Generating JWT secret"
  secret1=$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)
  secret2=$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)
  echo -n "${secret1}""${secret2}" > /var/lib/erigon/ee-secret/jwtsecret
fi

if [[ -O /var/lib/erigon/ee-secret ]]; then
  # In case someone specifies JWT_SECRET but it's not a distributed setup
  chmod 777 /var/lib/erigon/ee-secret
fi
if [[ -O /var/lib/erigon/ee-secret/jwtsecret ]]; then
  chmod 666 /var/lib/erigon/ee-secret/jwtsecret
fi

if [[ "${NETWORK}" =~ ^https?:// ]]; then
  echo "Custom testnet at ${NETWORK}"
  repo=$(awk -F'/tree/' '{print $1}' <<< "${NETWORK}")
  branch=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f1)
  config_dir=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f2-)
  echo "This appears to be the ${repo} repo, branch ${branch} and config directory ${config_dir}."
  # For want of something more amazing, let's just fail if git fails to pull this
  set -e
  if [[ ! -d "/var/lib/erigon/testnet/${config_dir}" ]]; then
    mkdir -p /var/lib/erigon/testnet
    cd /var/lib/erigon/testnet
    git init --initial-branch="${branch}"
    git remote add origin "${repo}"
    git config core.sparseCheckout true
    echo "${config_dir}" > .git/info/sparse-checkout
    git pull origin "${branch}"
  fi
  bootnodes="$(awk -F'- ' '!/^#/ && NF>1 {print $2}' "/var/lib/erigon/testnet/${config_dir}/enodes.yaml" | paste -sd ",")"
  networkid="$(jq -r '.config.chainId' "/var/lib/erigon/testnet/${config_dir}/genesis.json")"
  set +e
  __network="--bootnodes=${bootnodes} --networkid=${networkid}"
  if [[ ! -d /var/lib/erigon/chaindata ]]; then
    erigon init --datadir /var/lib/erigon "/var/lib/erigon/testnet/${config_dir}/genesis.json"
  fi
else
  __network="--chain ${NETWORK}"
fi

case "${NODE_TYPE}" in
  archive)
    echo "Erigon archive node without pruning"
    __prune="--prune.mode=archive --prune.distance=0"
    ;;
  full)
    echo "Erigon full node without history expiry"
    __prune="--prune.mode=blocks --prune.include-commitment-history"
    ;;
  pre-merge-expiry)
    case "${NETWORK}" in
      mainnet|sepolia)
        echo "Erigon minimal node with pre-merge history expiry"
        __prune="--prune.mode=full --persist.receipts=false"
        ;;
      *)
        echo "There is no pre-merge history for ${NETWORK} network, Erigon will use \"full\" pruning."
        __prune="--prune.mode=full --persist.receipts=false"
        ;;
    esac
    ;;
  aggressive-expiry)
    echo "Erigon minimal node with aggressive expiry"
    __prune="--prune.mode=minimal --persist.receipts=false"
    ;;
  *)
    echo "ERROR: The node type ${NODE_TYPE} is not known to Eth Docker's Erigon implementation."
    sleep 30
    exit 1
    ;;
esac

__caplin=""
# shellcheck disable=SC2076
if [[ ! "${COMPOSE_FILE}" =~ "caplin.yml" ]]; then
  __caplin="--externalcl=true"
else
  echo "Running Erigon with internal Caplin consensus layer client"
  __caplin="--caplin.discovery.addr=0.0.0.0 --caplin.discovery.port=${CL_P2P_PORT} --caplin.blobs-immediate-backfill=true"
  __caplin+=" --caplin.discovery.tcpport=${CL_P2P_PORT} --caplin.validator-monitor=true"
  __caplin+=" --caplin.max-peer-count=${CL_MAX_PEER_COUNT}"
  __caplin+=" --beacon.api=beacon,builder,config,debug,events,node,validator,lighthouse"
  __caplin+=" --beacon.api.addr=0.0.0.0 --beacon.api.port=${CL_REST_PORT} --beacon.api.cors.allow-origins=*"
  if [[ "${MEV_BOOST}" = "true" ]]; then
    __caplin+=" --caplin.mev-relay-url=${MEV_NODE}"
    echo "MEV Boost enabled"
  fi
  if [[ "${CL_NODE_TYPE}" = "archive" ]]; then
    echo "Running Caplin archive node"
    __caplin+=" --caplin.states-archive=true --caplin.blobs-archive=true --caplin.blobs-no-pruning=true --caplin.blocks-archive=true"
  fi
  if [[ -n "${CHECKPOINT_SYNC_URL}" ]]; then
    __caplin+=" --caplin.checkpoint-sync-url=${CHECKPOINT_SYNC_URL}/eth/v2/debug/beacon/states/finalized"
    echo "Checkpoint sync enabled"
  else
    __caplin+=" --caplin.checkpoint-sync.disable=true"
  fi
  echo "Caplin parameters: ${__caplin}"
fi

if [[ "${IPV6}" = "true" ]]; then
  echo "Configuring Erigon for discv5 for IPv6 advertisements"
  __ipv6="--v5disc"
else
  __ipv6=""
fi

__strip_empty_args "$@"
set -- "${__args[@]}"

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${__ipv6} ${__network} ${__prune} ${__caplin} ${EL_EXTRAS}
