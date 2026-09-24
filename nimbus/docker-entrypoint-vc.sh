#!/usr/bin/env bash

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R user:user /var/lib/nimbus
  exec su-exec user docker-entrypoint-vc.sh "$@"
fi

if [[ "${NETWORK}" = "ephemery" ]]; then
  config_dir_path="$(ephemery-config.sh /var/lib/nimbus/testnet/ephemery)"
  # A new iteration has a new genesis, and slashing protection for the old one is for a dead chain
  __iteration="$(basename "$(dirname "${config_dir_path}")")"
  if [[ -f /var/lib/nimbus/ephemery-iteration ]]; then
    __old_iteration="$(cat /var/lib/nimbus/ephemery-iteration)"
    if [[ ! "${__old_iteration}" = "${__iteration}" ]]; then
      echo "Ephemery reset from ${__old_iteration} to ${__iteration}, removing the old slashing protection DB"
      rm -f /var/lib/nimbus/validators/slashing_protection.sqlite3*
    fi
  fi
  echo "${__iteration}" > /var/lib/nimbus/ephemery-iteration
fi


__normalize_int() {
  local v=$1
  # Strip leading zeros as text. Arithmetic would overflow on the largest boost factors
  if [[ "${v}" =~ ^0*([0-9]+)$ ]]; then
    v="${BASH_REMATCH[1]}"
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

# Check whether we should use MEV Boost
if [[ "${MEV_BOOST}" = "true" ]]; then
  __mev_boost="--payload-builder=true"
  echo "MEV Boost enabled"
  build_factor="$(__normalize_int "${EPBS_BUILD_FACTOR}")"
  if [[ "${build_factor}" = "maxprofit" ]]; then
    build_factor=100  # 100 means profit maximization, as in the keymanager API
  fi
  case "${build_factor}" in
    0|local)
      __mev_boost=""
      __mev_factor=""
      echo "Disabled MEV Boost because EPBS_BUILD_FACTOR is ${build_factor}."
      echo "WARNING: This conflicts with MEV_BOOST true. Set a factor above 0, or maxprofit or always"
      ;;
    always)
      __mev_factor="--builder-boost-factor=18446744073709551615"
      echo "Always prefer MEV builder blocks, EPBS_BUILD_FACTOR always"
      ;;
    "")
      __mev_factor=""
      ;;
    *)
      if [[ "${build_factor}" =~ ^[1-9][0-9]{0,19}$ ]]; then
        # Compare as text, bash arithmetic cannot hold uint64. Equal length makes this a numeric comparison
        # shellcheck disable=SC2071
        if [[ ${#build_factor} -eq 20 && "${build_factor}" > "18446744073709551615" ]]; then
          echo "EPBS_BUILD_FACTOR ${build_factor} exceeds the 64-bit maximum, capping it to 18446744073709551615"
          build_factor=18446744073709551615
        fi
        __mev_factor="--builder-boost-factor=${build_factor}"
        echo "Enabled MEV Build Factor of ${build_factor}"
      else
        __mev_factor=""
        echo "WARNING: EPBS_BUILD_FACTOR has an invalid value of \"${build_factor}\""
      fi
      ;;
  esac
else
  __mev_boost=""
  __mev_factor=""
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
exec "$@" "${__beacon_nodes[@]}" ${__w3s_url} "${__graffiti_args[@]}" ${__doppel} ${__mev_boost} ${__mev_factor} ${__att_aggr} ${VC_EXTRAS}
