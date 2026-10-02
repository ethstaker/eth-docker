#!/usr/bin/env bash

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R user:user /var/lib/nimbus
  exec su-exec user docker-entrypoint-vc.sh "$@"
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
    [[ "${int_part}" =~ ^0*([0-9]+)$ ]] && int_part="${BASH_REMATCH[1]}"
    if [[ -n "${frac_part}" ]]; then
      v="${int_part}.${frac_part}"
    else
      v="${int_part}"
    fi
  fi
  printf '%s' "${v}"
}


if [[ ! -f /var/lib/nimbus/api-token.txt ]]; then
  token=api-token-0x$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)
  echo "${token}" > /var/lib/nimbus/api-token.txt
fi

# Check whether we should enable doppelganger protection
if [[ "${DOPPELGANGER}" = "true" ]]; then
  __doppel="--doppelganger-detection=true"
  echo "Doppelganger protection enabled, VC will pause for 2 epochs"
else
  __doppel="--doppelganger-detection=false"
fi

# Adjust RIGHT after Glamsterdam
# Check whether we should use ePBS
__epbs=""
if [[ "${MEV_BOOST}" = "true" || "${EPBS_BUILDERS}" = "true" ]]; then
  if [[ "${MEV_BOOST}" = "true" ]]; then
    echo "MEV Boost enabled"
    __epbs="--payload-builder=true"
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
      echo "EPBS_BUILD_FACTOR is ${build_factor}, which essentially disables remote block building / MEV."
      __epbs+=" --builder-boost-factor=0"
      ;;
    always)
      __epbs+=" --builder-boost-factor=18446744073709551615"
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
        __epbs+=" --builder-boost-factor=${build_factor}"
        echo "Enabled ePBS Build Factor of ${build_factor}"
      else
        echo "WARNING: EPBS_BUILD_FACTOR has an invalid value of \"${build_factor}\""
      fi
      ;;
  esac
  if [[ -n "${EPBS_MIN_BID}" ]]; then
    min_bid="$(__normalize_float "${EPBS_MIN_BID}")"
    if [[ "${min_bid}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      #min_bid_gwei=$(awk -v v="${min_bid}" 'BEGIN{printf "%.0f", v * 1000000000}')
      #__epbs+=" --payload-builder-min-bid=${min_bid_gwei}"
      echo "EPBS_MIN_BID is ${min_bid}, but Eth Docker cannot configure Nimbus VC for it."
    else
      echo "WARNING: EPBS_MIN_BID has an invalid value of \"${EPBS_MIN_BID}\", ignoring"
    fi
  fi
  builder_urls="${EPBS_BUILDER_URLS//[[:space:]]/}"
  # Nimbus cannot handle more than one builder URL yet
  if [[ "${builder_urls}" == *,* ]]; then
    builder_urls="${builder_urls%%,*}"
    echo "Nimbus supports only one ePBS builder URL. Using ${builder_urls}, ignoring the rest of EPBS_BUILDER_URLS"
  fi
  if [[ -n "${builder_urls}" ]]; then
    __epbs+=" --payload-builder-url=${builder_urls}"
  fi
else
  echo "Build blocks locally, use ePBS builders as fallback"
fi

# accommodate comma separated list of consensus nodes
nodes=$(echo "$CL_NODE" | tr ',' ' ')
__beacon_nodes=()
for node in ${nodes}; do
  __beacon_nodes+=("--beacon-node=${node}")
done

# Web3signer URL
if [[ "${WEB3SIGNER}" = "true" ]]; then
  __w3s_url="--web3-signer-url=${W3S_NODE}"
  __w3s_wait=300
  __w3s_deadline=$(( SECONDS + __w3s_wait ))
  while true; do
    if curl -sf -m 5 "${W3S_NODE}/upcheck" &> /dev/null; then
      echo "Web3signer is up, starting Nimbus"
      break
    fi
    if (( SECONDS >= __w3s_deadline )); then
      echo "Web3signer at ${W3S_NODE} is not reachable after ${__w3s_wait} seconds, starting Nimbus anyway"
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
  __graffiti_args=(--graffiti="${GRAFFITI}")
fi

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" "${__beacon_nodes[@]}" ${__w3s_url} "${__graffiti_args[@]}" ${__doppel} ${__epbs} ${__att_aggr} ${VC_EXTRAS}
