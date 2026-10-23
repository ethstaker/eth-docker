#!/bin/bash
set -Eeuo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R lhvalidator:lhvalidator /var/lib/lighthouse
  exec gosu lhvalidator docker-entrypoint-vc.sh "$@"
fi


__normalize_int() {
  local v=$1
  # Strip leading zeros as text. Arithmetic would overflow on the largest boost factors
  if [[ "${v}" =~ ^0*([0-9]+)$ ]]; then
    v="${BASH_REMATCH[1]}"
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
    # Strip leading zeros as text, as in __normalize_int
    [[ "${int_part}" =~ ^0*([0-9]+)$ ]] && int_part="${BASH_REMATCH[1]}"
    if [[ -n "${frac_part}" ]]; then
      v="${int_part}.${frac_part}"
    else
      v="${int_part}"
    fi
  fi
  printf '%s' "${v}"
}


if [[ "${NETWORK}" = "ephemery" ]]; then
  config_dir_path="$(ephemery-config.sh /var/lib/lighthouse/validators/testnet/ephemery)"
  __network="--testnet-dir=${config_dir_path}"
  # A new iteration has a new genesis, and slashing protection for the old one is for a dead chain
  __iteration="$(basename "$(dirname "${config_dir_path}")")"
  if [[ -f /var/lib/lighthouse/validators/ephemery-iteration ]]; then
    __old_iteration="$(cat /var/lib/lighthouse/validators/ephemery-iteration)"
    if [[ ! "${__old_iteration}" = "${__iteration}" ]]; then
      echo "Ephemery reset from ${__old_iteration} to ${__iteration}, removing the old slashing protection DB"
      rm -f /var/lib/lighthouse/validators/slashing_protection.sqlite*
    fi
  fi
  echo "${__iteration}" > /var/lib/lighthouse/validators/ephemery-iteration
elif [[ "${NETWORK}" =~ ^https?:// ]]; then
  echo "Custom testnet at ${NETWORK}"
  repo=$(awk -F'/tree/' '{print $1}' <<< "${NETWORK}")
  branch=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f1)
  config_dir=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f2-)
  echo "This appears to be the ${repo} repo, branch ${branch} and config directory ${config_dir}."
  if [[ ! -d "/var/lib/lighthouse/validators/testnet/${config_dir}" ]]; then
    mkdir -p /var/lib/lighthouse/validators/testnet
    cd /var/lib/lighthouse/validators/testnet
    git init --initial-branch="${branch}"
    git remote add origin "${repo}"
    git config core.sparseCheckout true
    echo "${config_dir}" > .git/info/sparse-checkout
    git pull origin "${branch}"
  fi
  __network="--testnet-dir=/var/lib/lighthouse/validators/testnet/${config_dir}"
else
  __network="--network=${NETWORK}"
fi

# Adjust RIGHT after each network's Glamsterdam hardfork
# MEV Boost implies ePBS builders only on networks that haven't forked yet
if [[ "${MEV_BOOST}" = "true" && "${NETWORK}" =~ ^(hoodi|mainnet)$ ]]; then
  __mev_active=1
else
  if [[ "${MEV_BOOST}" = "true" ]]; then
    echo "MEV_BOOST is true, but MEV Boost is not used on ${NETWORK}. Ignoring it."
  fi
  __mev_active=0
fi

# Check whether we should use ePBS
__epbs=""
if [[ "${__mev_active}" -eq 1 || "${EPBS_BUILDERS}" = "true" ]]; then
  if [[ "${__mev_active}" -eq 1 ]]; then
    echo "MEV Boost enabled"
    __epbs="--builder-proposals"
    if [[ "${EPBS_BUILDERS}" = "false" ]]; then
      echo "ePBS builders are meant to be disabled, but MEV Boost is true, which will enable them anyway."
      echo "Update Eth Docker again after ${NETWORK}'s Glamsterdam hard fork to fix this."
    else
      echo "Update Eth Docker again after mainnet Glamsterdam hard fork, expected December 2026, to remove MEV Boost."
    fi
  fi
  if [[ "${EPBS_BUILDERS}" = "true" ]]; then
    echo "ePBS builders enabled"
  fi

  build_factor="$(__normalize_int "${EPBS_BUILD_FACTOR}")"
  if [[ "${build_factor}" = "maxprofit" ]]; then
    build_factor=100  # 100 means profit maximization, as in the keymanager API
  fi
  case "${build_factor}" in
    0|local)
      if [[ "${__mev_active}" -eq 1 ]]; then
        __epbs=""
        echo "Disabled MEV Boost because EPBS_BUILD_FACTOR is ${build_factor}."
        echo "WARNING: This conflicts with MEV_BOOST true. Set a factor above 0, or maxprofit or always"
      fi
      __epbs+=" --builder-boost-factor 0"
      echo "Build blocks locally, use ePBS builders as fallback. EPBS_BUILD_FACTOR is ${build_factor}."
      ;;
    always)
      __epbs+=" --prefer-builder-proposals"
      echo "Always prefer ePBS builder blocks, EPBS_BUILD_FACTOR always"
      ;;
    "")
      echo "Use default --builder-boost-factor"
      ;;
    *)
      if [[ "${build_factor}" =~ ^[1-9][0-9]{0,19}$ ]]; then
        # Compare as text, bash arithmetic cannot hold uint64. Equal length makes this a numeric comparison
        # shellcheck disable=SC2071
        if [[ ${#build_factor} -eq 20 && "${build_factor}" > "18446744073709551615" ]]; then
          echo "EPBS_BUILD_FACTOR ${build_factor} exceeds the 64-bit maximum, capping it to 18446744073709551615"
          build_factor=18446744073709551615
        fi
        __epbs+=" --builder-boost-factor ${build_factor}"
        echo "Enabled ePBS Build Factor of ${build_factor}"
      else
        echo "WARNING: EPBS_BUILD_FACTOR has an invalid value of \"${build_factor}\""
      fi
      ;;
  esac
  if [[ -n "${EPBS_MIN_BID}" ]]; then
    min_bid="$(__normalize_float "${EPBS_MIN_BID}")"
    if [[ "${min_bid}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      min_bid_gwei=$(awk -v v="${min_bid}" 'BEGIN{printf "%.0f", v * 1000000000}')
      __epbs+=" --builder-min-bid ${min_bid_gwei}"
    else
      echo "WARNING: EPBS_MIN_BID has an invalid value of \"${EPBS_MIN_BID}\", ignoring"
    fi
  fi
  # Compose keeps the newlines of a multi-line EPBS_BUILDER_URLS
  builder_urls="${EPBS_BUILDER_URLS//[[:space:]]/}"
  if [[ -n "${builder_urls}" ]]; then
    __epbs+=" --builder-urls ${builder_urls}"
  fi
else
  __epbs="--builder-boost-factor 0"
  echo "Build blocks locally, use ePBS builders as fallback"
fi

# Check whether we should send stats to beaconcha.in
if [[ -n "${BEACON_STATS_API}" ]]; then
  __beacon_stats="--monitoring-endpoint https://beaconcha.in/api/v1/client/metrics?apikey=${BEACON_STATS_API}&machine=${BEACON_STATS_MACHINE}"
else
  __beacon_stats=""
fi

# Check whether we should enable doppelganger protection
if [[ "${DOPPELGANGER}" = "true" ]]; then
  __doppel="--enable-doppelganger-protection"
  echo "Doppelganger protection enabled, VC will pause for 2 epochs"
else
  __doppel=""
fi

# Distributed attestation aggregation
if [[ "${ENABLE_DIST_ATTESTATION_AGGR}" =  "true" ]]; then
  __att_aggr="--distributed"
else
  __att_aggr=""
fi

# Web3signer note: Lighthouse uses the URL given to it by the keymanager remote registration. It does
# not use a parameter to connect the VC to Web3signer. This is unique to Lighthouse and Vero

if [[ "${DEFAULT_GRAFFITI}" = "true" ]]; then
  __graffiti_args=()
else
  __graffiti_args=(--graffiti-append --graffiti "${GRAFFITI}")
fi

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${__network} "${__graffiti_args[@]}" ${__epbs} ${__beacon_stats} ${__doppel} ${__att_aggr} ${VC_EXTRAS}
