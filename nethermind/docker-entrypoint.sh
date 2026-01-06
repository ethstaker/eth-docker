#!/bin/bash
set -Eeuo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R nethermind:nethermind /var/lib/nethermind
  chown -R nethermind:nethermind /var/lib/grandine
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


__normalize_int() {
  local v=$1
  if [[ "${v}" =~ ^[0-9]+$ ]]; then
    v=$((10#${v}))
  fi
  printf '%s' "${v}"
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
        __prune+=" --Sync.AncientBodiesBarrier=15537394 --Sync.AncientReceiptsBarrier=15537394 --History.Pruning=UseAncientBarriers"
        ;;
      sepolia)
        echo "Nethermind minimal node with pre-merge history expiry"
        __prune+=" --Sync.AncientBodiesBarrier=1450408 --Sync.AncientReceiptsBarrier=1450408 --History.Pruning=UseAncientBarriers"
        ;;
      *)
        echo "There is no pre-merge history for ${NETWORK} network, \"pre-merge-expiry\" has no effect."
        ;;
    esac
    ;;
  pre-cancun-expiry)
    case "${NETWORK}" in
      mainnet)
        echo "Nethermind minimal node with pre-Cancun history expiry"
        __prune+=" --Sync.AncientBodiesBarrier=19426587 --Sync.AncientReceiptsBarrier=19426587 --History.Pruning=UseAncientBarriers"
        ;;
      sepolia)
        echo "Nethermind minimal node with pre-Cancun history expiry"
        __prune+=" --Sync.AncientBodiesBarrier=5187023 --Sync.AncientReceiptsBarrier=5187023 --History.Pruning=UseAncientBarriers"
        ;;
      *)
        echo "There is no pre-Cancun history for ${NETWORK} network, \"pre-cancun-expiry\" has no effect."
        ;;
    esac
    ;;
  rolling-expiry)
    echo "Nethermind minimal node with rolling history expiry, keeps 1 year by default."
    echo "\"EL_EXTRAS=--history-retentionepochs <epochs>\" in \".env\" can override, minimum <epochs> are 82125."
    __prune+=" --History.Pruning=Rolling"
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

if [[ "${COMPOSE_FILE}" =~ grandine-plugin(-allin1)?\.yml ]]; then
  if [[ ! -f /var/lib/grandine/wallet-password.txt ]]; then
    echo "Creating password for Grandine key wallet"
    head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1 > /var/lib/grandine/wallet-password.txt
  fi
  __grandine="--grandine-disableupnp --grandine-datadir /var/lib/grandine --grandine-httpaddress 0.0.0.0 --grandine-httpport ${CL_REST_PORT:-5052}"
  __grandine+=" --grandine-httpallowedorigins=* --grandine-listenaddress 0.0.0.0 --grandine-libp2pport ${CL_P2P_PORT:-9000} --grandine-discoveryport ${CL_P2P_PORT:-9000}"
  __grandine+=" --grandine-quicport ${CL_QUIC_PORT:-9001} ${CL_MAX_PEER_COUNT:+--grandine-targetpeers} ${CL_MAX_PEER_COUNT:+${CL_MAX_PEER_COUNT}}"
  __grandine+=" --grandine-metrics --grandine-metricsaddress 0.0.0.0 --grandine-metricsport 8008 --grandine-suggestedfeerecipient ${FEE_RECIPIENT}"
  __grandine+=" --grandine-trackliveness"

  if [[ "${EMBEDDED_VC}" = "true" ]]; then
    __grandine+=" --grandine-keystorestoragepasswordfile /var/lib/grandine/wallet-password.txt  --grandine-enablevalidatorapi"
    __grandine+=" --grandine-validatorapiaddress 0.0.0.0 --grandine-validatorapiport ${KEY_API_PORT:-7500} --grandine-validatorapiallowedorigins=*"
  fi

  if [[ "${NETWORK}" =~ ^https?:// ]]; then
    echo "Custom testnet at ${NETWORK}"
    repo=$(awk -F'/tree/' '{print $1}' <<< "${NETWORK}")
    branch=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f1)
    config_dir=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f2-)
    echo "This appears to be the ${repo} repo, branch ${branch} and config directory ${config_dir}."
    # For want of something more amazing, let's just fail if git fails to pull this
    set -e
    if [[ ! -d "/var/lib/grandine/testnet/${config_dir}" ]]; then
      mkdir -p /var/lib/grandine/testnet
      cd /var/lib/grandine/testnet
      git init --initial-branch="${branch}"
      git remote add origin "${repo}"
      git config core.sparseCheckout true
      echo "${config_dir}" > .git/info/sparse-checkout
      git pull origin "${branch}"
    fi
    bootnodes="$(awk -F'- ' '!/^#/ && NF>1 {print $2}' "/var/lib/grandine/testnet/${config_dir}/bootstrap_nodes.yaml" | paste -sd ",")"
    set +e
    __grandine+=" --grandine-configurationdirectory=/var/lib/grandine/testnet/${config_dir} --grandine-bootnodes=${bootnodes}"
  else
    __grandine+=" --grandine-network=${NETWORK}"
  fi

  case "${CL_NODE_TYPE}" in
    archive)
      echo "Grandine archive node without pruning"
      __grandine+=" --grandine-backsync --grandine-archivestorage"
      ;;
    pruned)
      ;;
    aggressive-pruned)
      __grandine+=" --grandine-prunestorage"
      ;;
    full)
      __grandine+=" --grandine-backsync"
      ;;
    *)
      echo "ERROR: The node type ${CL_NODE_TYPE} is not known to Eth Docker's Grandine implementation."
      sleep 30
      exit 1
      ;;
  esac

# Check whether we should rapid sync
  if [[ -n "${CHECKPOINT_SYNC_URL}" ]]; then
    __grandine+=" --grandine-checkpointsyncurl=${CHECKPOINT_SYNC_URL}"
    echo "Grandine checkpoint sync enabled"
  fi

# Check whether we should send stats to beaconcha.in
  if [[ -n "${BEACON_STATS_API}" ]]; then
    __grandine+=" --grandine-remotemetricsurl https://beaconcha.in/api/v1/client/metrics?apikey=${BEACON_STATS_API}&machine=${BEACON_STATS_MACHINE}"
    echo "Grandine beacon stats API enabled"
  fi

# Check whether we should use MEV Boost
  if [[ "${MEV_BOOST}" = "true" ]]; then
    __mev_boost=" --grandine-builderurl ${MEV_NODE:-http://mev-boost:18550}"
    echo "Grandine MEV Boost enabled"
    if [[ "${EMBEDDED_VC}" = "true" ]]; then
      build_factor="$(__normalize_int "${MEV_BUILD_FACTOR}")"
      case "${build_factor}" in
        0)
          __mev_boost=""
          __mev_factor=""
          echo "Disabled MEV Boost because MEV_BUILD_FACTOR is 0."
          echo "WARNING: This conflicts with MEV_BOOST true. Set factor in a range of 1 to 100"
          ;;
        [1-9]|[1-9][0-9])
          #__mev_factor="--default-builder-boost-factor ${build_factor}"
          #echo "Enabled MEV Build Factor of ${build_factor}"
          __mev_factor=""
          echo "WARNING: Embedded Grandine does not support --builder-boost-factor. MEV build factor ${build_factor} not applied."
          ;;
        100)
          #__mev_factor="--default-builder-boost-factor 18446744073709551615"
          #echo "Always prefer MEV builder blocks, MEV_BUILD_FACTOR 100"
          __mev_factor=""
          echo "WARNING: Embedded Grandine does not support --builder-boost-factor. MEV build factor ${build_factor} not applied."
          ;;
        "")
          __mev_factor=""
          #echo "Use default --grandine-defaultbuilderboostfactor"
          ;;
        *)
          __mev_factor=""
          echo "WARNING: MEV_BUILD_FACTOR has an invalid value of \"${build_factor}\""
          ;;
      esac
      __mev_boost+="${__mev_factor}"
    fi
    __grandine+="${__mev_boost}"
  fi

  if [[ "${IPV6}" = "true" ]]; then
    echo "Configuring Grandine to listen on IPv6 ports"
    __grandine+=" --grandine-listenaddressipv6 :: --grandine-libp2pportipv6 ${CL_P2P_PORT:-9000} --grandine-discoveryportipv6 ${CL_P2P_PORT:-9000} \
  --grandine-quicportipv6 ${CL_QUIC_PORT:-9001}"
  # ENR discovery on v6 is not yet working, likely too few peers. Manual for now
    ipv6_pattern="^[0-9A-Fa-f]{1,4}:"  # Sufficient to check the start
    set +e
    public_v6=$(curl -s -6 ifconfig.me)
    set -e
    if [[ "${public_v6}" =~ ${ipv6_pattern} ]]; then
      __grandine+=" --grandine-enraddressipv6 ${public_v6} --grandine-enrtcpportipv6 ${CL_P2P_PORT:-9000} --grandine-enrudpportipv6 ${CL_P2P_PORT:-9000}"
    fi
  fi

# Check whether we should enable doppelganger protection
  if [[ "${EMBEDDED_VC}" = "true" && "${DOPPELGANGER}" = "true" ]]; then
    __grandine+=" --grandine-detectdoppelgangers"
    echo "Grandine Doppelganger protection enabled"
  fi

# Web3signer URL
  if [[ "${EMBEDDED_VC}" = "true" && "${WEB3SIGNER}" = "true" ]]; then
    __grandine+=" --grandine-web3signerurls ${W3S_NODE}"
  fi

  if [[ ! "${DEFAULT_GRAFFITI}" = "true" ]]; then
      __grandine+=" --grandine-graffiti ${GRAFFITI}"
  fi

  __grandine+=" ${CL_EXTRAS} ${VC_EXTRAS}"
else
  __grandine=""
fi

__strip_empty_args "$@"
set -- "${__args[@]}"

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${__datadir} ${__network} ${__prune} ${__grandine} ${EL_EXTRAS}
