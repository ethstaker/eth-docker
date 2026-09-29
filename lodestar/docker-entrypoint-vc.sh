#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R lsvalidator:lsvalidator /var/lib/lodestar
  exec gosu lsvalidator docker-entrypoint-vc.sh "$@"
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
  if [[ "${build_factor}" = "maxprofit" ]]; then
    build_factor=100  # 100 means profit maximization, as in the keymanager API
  fi
  case "${build_factor}" in
    0|local)
      __epbs="--builder.selection executionalways"
      echo "Build blocks locally, use ePBS builders as fallback. EPBS_BUILD_FACTOR is ${build_factor}."
      ;;
    always)
      __epbs="--builder.selection builderalways"
      echo "Always prefer ePBS builder blocks, EPBS_BUILD_FACTOR always"
      ;;
    "")
      __epbs="--builder"
      echo "Use default --builder.boostFactor"
      ;;
    *)
      if [[ "${build_factor}" =~ ^[1-9][0-9]{0,19}$ ]]; then
        # Compare as text, bash arithmetic cannot hold uint64. Equal length makes this a numeric comparison
        # shellcheck disable=SC2071
        if [[ ${#build_factor} -eq 20 && "${build_factor}" > "18446744073709551615" ]]; then
          echo "EPBS_BUILD_FACTOR ${build_factor} exceeds the 64-bit maximum, capping it to 18446744073709551615"
          build_factor=18446744073709551615
        fi
        __epbs="--builder.selection maxprofit --builder.boostFactor ${build_factor}"
        echo "Enabled ePBS Build Factor of ${build_factor}"
      else
        __epbs="--builder"
        echo "WARNING: EPBS_BUILD_FACTOR has an invalid value of \"${build_factor}\""
      fi
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
# Compose keeps the newlines of a multi-line EPBS_BUILDER_URLS, and Lodestar rejects the empty entry that "url,<newline>" creates
  builder_urls="${EPBS_BUILDER_URLS//[[:space:]]/}"
  if [[ -n "${builder_urls}" ]]; then
    __epbs+=" --builder.urls ${builder_urls}"
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
# Lodestar exits if it cannot fetch pubkeys from web3signer at startup, so give web3signer time
# to come up. The image has no curl, but it has node.
  __w3s_wait=300
  __w3s_deadline=$(( SECONDS + __w3s_wait ))
  while true; do
    if node -e 'fetch(process.argv[1], {signal: AbortSignal.timeout(5000)}).then(r => process.exit(r.ok ? 0 : 1), () => process.exit(1))' \
        "${W3S_NODE}/upcheck"; then
      echo "Web3signer is up, starting Lodestar"
      break
    fi
    if (( SECONDS >= __w3s_deadline )); then
      echo "Web3signer at ${W3S_NODE} is not reachable after ${__w3s_wait} seconds, starting Lodestar anyway"
      break
    fi
    echo "Waiting for Web3signer to be reachable..."
    sleep 5
  done
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
