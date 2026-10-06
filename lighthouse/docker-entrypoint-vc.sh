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

# Check whether we should use MEV Boost
if [[ "${__mev_active}" -eq 1 ]]; then
  __mev_boost="--builder-proposals"
  echo "MEV Boost enabled"
else
  __mev_boost=""
fi

# Check whether we should use ePBS
if [[ "${__mev_active}" -eq 1 || "${EPBS_BUILDERS}" = "true" ]]; then
  if [[ "${__mev_active}" -eq 1 ]]; then
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
        __mev_boost=""
        __mev_factor=""
        echo "Disabled MEV Boost because EPBS_BUILD_FACTOR is ${build_factor}."
        echo "WARNING: This conflicts with MEV_BOOST true. Set a factor above 0, or maxprofit or always"
      else
        __mev_factor="--builder-boost-factor 0"
        echo "Build blocks locally, use ePBS builders as fallback. EPBS_BUILD_FACTOR is ${build_factor}."
      fi
      ;;
    always)
      __mev_factor="--prefer-builder-proposals"
      echo "Always prefer ePBS builder blocks, EPBS_BUILD_FACTOR always"
      ;;
    "")
      __mev_factor=""
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
        __mev_factor="--builder-boost-factor ${build_factor}"
        echo "Enabled ePBS Build Factor of ${build_factor}"
      else
        __mev_factor=""
        echo "WARNING: EPBS_BUILD_FACTOR has an invalid value of \"${build_factor}\""
      fi
      ;;
  esac
  # Adjust once Lighthouse supports ePBS CLI parameters, to pass them here like Prysm does
  # Compose keeps the newlines of a multi-line EPBS_BUILDER_URLS
  builder_urls="${EPBS_BUILDER_URLS//[[:space:]]/}"
  if [[ -n "${builder_urls}" || -n "${EPBS_MIN_BID}" ]]; then
    echo "Lighthouse does not support ePBS CLI parameters for builder URLs or minimum bid yet. Ignoring EPBS_BUILDER_URLS and EPBS_MIN_BID."
    echo "Use \"./ethd keys set-builder\" to configure ePBS builders."
  fi
else
  __mev_factor="--builder-boost-factor 0"
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
exec "$@" ${__network} "${__graffiti_args[@]}" ${__mev_boost} ${__mev_factor} ${__beacon_stats} ${__doppel} ${__att_aggr} ${VC_EXTRAS}
