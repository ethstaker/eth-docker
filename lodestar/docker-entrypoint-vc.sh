#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R lsvalidator:lsvalidator /var/lib/lodestar
  exec gosu lsvalidator docker-entrypoint-vc.sh "$@"
fi


__normalize_int() {
  local v=$1

  if [[ "${v}" =~ ^[0-9]+$ ]]; then
    v=$((10#${v}))
  fi
  printf '%s' "${v}"
}

__normalize_float() {
  local v=$1
  local int_part
  local frac_part

  if [[ "${v}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    int_part="${v%%.*}"
    frac_part=""
    if [[ "${v}" == *.* ]]; then
      frac_part="${v#*.}"
    fi
    int_part=$((10#${int_part}))
    if [[ -n "${frac_part}" ]]; then
      v="${int_part}.${frac_part}"
    else
      v="${int_part}"
    fi
  fi
  printf '%s' "${v}"
}


if [[ "${NETWORK}" =~ ^https?:// ]]; then
  echo "Custom testnet at ${NETWORK}"
  repo=$(awk -F'/tree/' '{print $1}' <<< "${NETWORK}")
  branch=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f1)
  config_dir=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f2-)
  echo "This appears to be the ${repo} repo, branch ${branch} and config directory ${config_dir}."
  if [[ ! -d "/var/lib/lodestar/validators/testnet/${config_dir}" ]]; then
    mkdir -p /var/lib/lodestar/validators/testnet
    cd /var/lib/lodestar/validators/testnet
    git init --initial-branch="${branch}"
    git remote add origin "${repo}"
    git config core.sparseCheckout true
    echo "${config_dir}" > .git/info/sparse-checkout
    git pull origin "${branch}"
  fi
  __network="--paramsFile=/var/lib/lodestar/validators/testnet/${config_dir}/config.yaml"
else
  __network="--network ${NETWORK}"
fi

# Adjust RIGHT after Glamsterdam
# Check whether we should use ePBS
if [[ "${MEV_BOOST}" = "true" || "${EPBS_BUILDERS}" = "true" ]]; then
  if [[ "${MEV_BOOST}" = "true" ]]; then
    echo "MEV Boost enabled"
    if [[ "${EPBS_BUILDERS}" = "false" ]]; then
      echo "ePBS builders are meant to be disabled, but MEV Boost is true, which will enable them anyway."
      echo "Update Eth Docker again after mainnet Glamsterdam hard fork, expected December 2026, to fix this."
    else
      echo "Update Eth Docker again after mainnet Glamsterdam hard fork, expected December 2026, to remove MEV Boost."
    fi
  fi
  if [[ "${EPBS_BUILDERS}" = "true" ]]; then
    echo "ePBS builders enabled"
  fi

  build_factor="$(__normalize_int "${EPBS_BUILD_FACTOR}")"
  case "${build_factor}" in
    0)
      __epbs="--builder.selection executionalways"
      echo "Build blocks locally, use ePBS builders as fallback. EPBS_BUILD_FACTOR is 0."
      ;;
    [1-9]|[1-9][0-9])
      __epbs="--builder.selection maxprofit --builder.boostFactor ${build_factor}"
      echo "Enabled ePBS Build Factor of ${build_factor}"
      ;;
    100)
      __epbs="--builder.selection builderalways"
      echo "Always prefer ePBS builder blocks, EPBS_BUILD_FACTOR 100"
      ;;
    "")
      __epbs="--builder"
      echo "Use default --builder.boostFactor"
      ;;
    *)
      __epbs="--builder"
      echo "WARNING: EPBS_BUILD_FACTOR has an invalid value of \"${build_factor}\""
      ;;
  esac
  if [[ -n "${EPBS_MIN_BID}" ]]; then
    min_bid="$(__normalize_float "${EPBS_MIN_BID}")"
    if [[ "${min_bid}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      min_bid_gwei=$(awk -v v="${min_bid}" 'BEGIN{printf "%.0f", v * 1000000000}')
      __epbs+=" --builder.minBid ${min_bid_gwei}"
    else
      echo "WARNING: EPBS_MIN_BID has an invalid value of \"${EPBS_MIN_BID}\", ignoring"
    fi
  fi
  if [[ -n "${EPBS_BUILDER_URLS}" ]]; then
    __epbs+=" --builder.urls ${EPBS_BUILDER_URLS}"
  fi
else
  __epbs="--builder.selection executionalways"
  echo "Build blocks locally, use ePBS builders as fallback"
fi

# Check whether we should send stats to beaconcha.in
if [[ -n "${BEACON_STATS_API}" ]]; then
  __beacon_stats="--monitoring.endpoint https://beaconcha.in/api/v1/client/metrics?apikey=${BEACON_STATS_API}&machine=${BEACON_STATS_MACHINE}"
  echo "Beacon stats API enabled"
else
  __beacon_stats=""
fi

# Check whether we should enable doppelganger protection
if [[ "${DOPPELGANGER}" = "true" ]]; then
  __doppel="--doppelgangerProtection"
  echo "Doppelganger protection enabled, VC will pause for 2 epochs"
else
  __doppel=""
fi

# Web3signer URL
if [[ "${WEB3SIGNER}" = "true" ]]; then
  __w3s_url="--externalSigner.url ${W3S_NODE} --externalSigner.fetch"
else
  __w3s_url=""
fi

# Distributed attestation aggregation
if [[ "${ENABLE_DIST_ATTESTATION_AGGR}" =  "true" ]]; then
  __att_aggr="--distributed"
else
  __att_aggr=""
fi

if [[ "${DEFAULT_GRAFFITI}" = "true" ]]; then
  __graffiti_args=()
else
  __graffiti_args=(--graffiti "${GRAFFITI}")
fi

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${__network} ${__w3s_url} "${__graffiti_args[@]}" ${__epbs} ${__beacon_stats} ${__doppel} ${__att_aggr} ${VC_EXTRAS}
