#!/bin/bash
set -Eeuo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R nethermind:nethermind /var/lib/nethermind
  exec gosu nethermind "${BASH_SOURCE[0]}" "$@"
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
  echo -n "${JWT_SECRET}" > /var/lib/nethermind/ee-secret/jwtsecret
  echo "JWT secret was supplied in .env"
fi

if [[ ! -f /var/lib/nethermind/ee-secret/jwtsecret ]]; then
  echo "Generating JWT secret"
  secret1=$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)
  secret2=$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)
  echo -n "${secret1}""${secret2}" > /var/lib/nethermind/ee-secret/jwtsecret
fi

if [[ -O /var/lib/nethermind/ee-secret ]]; then
  # In case someone specifies JWT_SECRET but it's not a distributed setup
  chmod 777 /var/lib/nethermind/ee-secret
fi
if [[ -O /var/lib/nethermind/ee-secret/jwtsecret ]]; then
  chmod 666 /var/lib/nethermind/ee-secret/jwtsecret
fi

if [[ "${NETWORK}" =~ ^https?:// ]]; then
  echo "Custom testnet at ${NETWORK}"
  repo=$(awk -F'/tree/' '{print $1}' <<< "${NETWORK}")
  branch=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f1)
  config_dir=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f2-)
  echo "This appears to be the ${repo} repo, branch ${branch} and config directory ${config_dir}."
  if [[ ! -d "/var/lib/nethermind/testnet/${config_dir}" ]]; then
    # For want of something more amazing, let's just fail if git fails to pull this
    set -e
    mkdir -p /var/lib/nethermind/testnet
    cd /var/lib/nethermind/testnet
    git init --initial-branch="${branch}"
    git remote add origin "${repo}"
    git config core.sparseCheckout true
    echo "${config_dir}" > .git/info/sparse-checkout
    git pull origin "${branch}"
    set +e
  fi
  bootnodes="$(awk -F'- ' '!/^#/ && NF>1 {print $2}' "/var/lib/nethermind/testnet/${config_dir}/enodes.yaml" | paste -sd ",")"
  __network="--config none.cfg --Init.ChainSpecPath=/var/lib/nethermind/testnet/${config_dir}/chainspec.json --Discovery.Bootnodes=${bootnodes} --Init.IsMining=false"
  if [[ ! "${NODE_TYPE}" = "archive" ]]; then
    __prune="--Pruning.Mode=None"
  fi
else
  __network="--config ${NETWORK}"
fi

if [[ ! "${NETWORK}" =~ ^https?:// && ! "${NODE_TYPE}" = "archive" ]]; then  # Only configure prune parameters for named networks
  memtotal=$(awk '/MemTotal/ {printf "%d", int($2/1024/1024)}' /proc/meminfo)
  parallel=$(($(nproc)/4))
  if [[ "${parallel}" -lt 2 ]]; then
    parallel=2
  fi
  __prune="--Pruning.FullPruningMaxDegreeOfParallelism=${parallel}"
  if [[ "${AUTOPRUNE_NM}" = true ]]; then
    __prune="${__prune} --Pruning.FullPruningTrigger=VolumeFreeSpace"
    if [[ "${NETWORK}" =~ (mainnet|gnosis) ]]; then
      __prune+=" --Pruning.FullPruningThresholdMb=375810"
    else
      __prune+=" --Pruning.FullPruningThresholdMb=51200"
    fi
  fi
  if [[ "${memtotal}" -ge 30 ]]; then
    __prune+=" --Pruning.FullPruningMemoryBudgetMb=16384 --Init.StateDbKeyScheme=HalfPath"
  fi
fi

case "${NODE_TYPE}" in
  archive)
    echo "Nethermind archive node without pruning"
    __prune="--Sync.DownloadBodiesInFastSync=false --Sync.DownloadReceiptsInFastSync=false --Sync.FastSync=false --Sync.SnapSync=false --Sync.FastBlocks=false --Pruning.Mode=None --Sync.PivotNumber=0"
    ;;
  full)
    echo "Nethermind full node without history expiry"
    __prune+=" --Sync.AncientBodiesBarrier=0 --Sync.AncientReceiptsBarrier=0"
    ;;
  pre-merge-expiry)
    case "${NETWORK}" in
      mainnet)
        echo "Nethermind minimal node with pre-merge history expiry"
        __prune+=" --Sync.AncientBodiesBarrier=15537394 --Sync.AncientReceiptsBarrier=15537394"
        ;;
      sepolia)
        echo "Nethermind minimal node with pre-merge history expiry"
        ;;
      *)
        echo "There is no pre-merge history for ${NETWORK} network, \"pre-merge-expiry\" has no effect."
        ;;
    esac
    ;;
  *)
    echo "ERROR: The node type ${NODE_TYPE} is not known to Eth Docker's Nethermind implementation."
    sleep 30
    exit 1
    ;;
esac

echo "Using pruning parameters:"
echo "${__prune}"

# New or old datadir
if [[ -d /var/lib/nethermind-og/nethermind_db ]]; then
  __datadir="--data-dir /var/lib/nethermind-og"
else
  __datadir="--data-dir /var/lib/nethermind"
fi

__strip_empty_args "$@"
set -- "${__args[@]}"

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${__datadir} ${__network} ${__prune} ${EL_EXTRAS}
