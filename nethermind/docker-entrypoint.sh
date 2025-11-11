#!/bin/bash
set -Eeuo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R nethermind:nethermind /var/lib/nethermind
  exec gosu nethermind "${BASH_SOURCE[0]}" "$@"
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


# Move legacy xdai dir to gnosis
if [[ -d /var/lib/nethermind/nethermind_db/xdai ]]; then
  mv /var/lib/nethermind/nethermind_db/xdai /var/lib/nethermind/nethermind_db/gnosis
fi

if [[ -n "${JWT_SECRET}" ]]; then
  echo -n "${JWT_SECRET}" > /var/lib/nethermind/ee-secret/jwtsecret
  echo "JWT secret was supplied in .env"
fi

if [[ ! -f /var/lib/nethermind/ee-secret/jwtsecret ]]; then
  echo "Generating JWT secret"
  __secret1=$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)
  __secret2=$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)
  echo -n "${__secret1}""${__secret2}" > /var/lib/nethermind/ee-secret/jwtsecret
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
  if [[ "${ARCHIVE_NODE}" = "false" ]]; then
    __prune="--Pruning.Mode=None"
  fi
else
  __network="--config ${NETWORK}"
fi

__memtotal=$(awk '/MemTotal/ {printf "%d", int($2/1024/1024)}' /proc/meminfo)
if [[ "${ARCHIVE_NODE}" = "true" ]]; then
  echo "Nethermind archive node without pruning"
  __prune="--Sync.DownloadBodiesInFastSync=false --Sync.DownloadReceiptsInFastSync=false --Sync.FastSync=false --Sync.SnapSync=false --Sync.FastBlocks=false --Pruning.Mode=None --Sync.PivotNumber=0"
elif [[ ! "${NETWORK}" =~ ^https?:// ]]; then  # Only configure prune parameters for named networks
  __parallel=$(($(nproc)/4))
  if [[ "${__parallel}" -lt 2 ]]; then
    __parallel=2
  fi
  __prune="--Pruning.FullPruningMaxDegreeOfParallelism=${__parallel}"
  if [[ "${AUTOPRUNE_NM}" = true ]]; then
    __prune="${__prune} --Pruning.FullPruningTrigger=VolumeFreeSpace"
    if [[ "${NETWORK}" =~ (mainnet|gnosis) ]]; then
      __prune+=" --Pruning.FullPruningThresholdMb=375810"
    else
      __prune+=" --Pruning.FullPruningThresholdMb=51200"
    fi
  fi
  if [[ "${__memtotal}" -ge 30 ]]; then
    __prune+=" --Pruning.FullPruningMemoryBudgetMb=16384 --Init.StateDbKeyScheme=HalfPath"
  fi
  if [[ "${MINIMAL_NODE}" = "true" ]]; then
    case "${NETWORK}" in
      mainnet )
        echo "Nethermind minimal node with pre-merge history expiry"
        __prune+=" --Sync.AncientBodiesBarrier=15537394 --Sync.AncientReceiptsBarrier=15537394"
        ;;
      sepolia )
        echo "Nethermind minimal node with pre-merge history expiry"
        ;;
      * )
        echo "There is no pre-merge history for ${NETWORK} network, EL_MINIMAL_NODE has no effect."
        ;;
    esac
  else  # Full node
    echo "Nethermind full node without history expiry"
    __prune+=" --Sync.AncientBodiesBarrier=0 --Sync.AncientReceiptsBarrier=0"
  fi
  echo "Using pruning parameters:"
  echo "${__prune}"
fi

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
