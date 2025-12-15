#!/usr/bin/env bash

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R user:user /var/lib/nimbus
  exec su-exec user docker-entrypoint-vc.sh "$@"
fi


__normalize_int() {
  local v=$1
  if [[ "${v}" =~ ^[0-9]+$ ]]; then
    v=$((10#${v}))
  fi
  printf '%s' "${v}"
}


# Remove old low-entropy token, related to Sigma Prime security audit
# This detection isn't perfect - a user could recreate the token without ./ethd update
if [[ -f /var/lib/nimbus/api-token.txt && "$(date +%s -r /var/lib/nimbus/api-token.txt)" -lt "$(date +%s --date="2023-05-02 09:00:00")" ]]; then
  rm /var/lib/nimbus/api-token.txt
fi

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
  build_factor="$(__normalize_int "${MEV_BUILD_FACTOR}")"
  case "${build_factor}" in
    0)
      __mev_boost=""
      __mev_factor=""
      echo "Disabled MEV Boost because MEV_BUILD_FACTOR is 0."
      echo "WARNING: This conflicts with MEV_BOOST true. Set factor in a range of 1 to 100"
      ;;
    [1-9]|[1-9][0-9])
      __mev_factor="--builder-boost-factor ${build_factor}"
      echo "Enabled MEV Build Factor of ${build_factor}"
      ;;
    100)
      __mev_factor="--builder-boost-factor 18446744073709551615"
      echo "Always prefer MEV builder blocks, MEV_BUILD_FACTOR 100"
      ;;
    "")
      __mev_factor=""
      ;;
    *)
      __mev_factor=""
      echo "WARNING: MEV_BUILD_FACTOR has an invalid value of \"${build_factor}\""
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

__log_level="--log-level=${LOG_LEVEL^^}"

# Web3signer URL
if [[ "${WEB3SIGNER}" = "true" ]]; then
  __w3s_url="--web3-signer-url=${W3S_NODE}"
  while true; do
    if curl -s -m 5 "${W3S_NODE}" &> /dev/null; then
      echo "Web3signer is up, starting Nimbus"
      break
    else
      echo "Waiting for Web3signer to be reachable..."
      sleep 5
    fi
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
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" "${__beacon_nodes[@]}" ${__w3s_url} ${__log_level} ${__doppel} ${__mev_boost} ${__mev_factor} ${__att_aggr} ${VC_EXTRAS}
else
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" "${__beacon_nodes[@]}" ${__w3s_url} "--graffiti=${GRAFFITI}" ${__log_level} ${__doppel} ${__mev_boost} ${__mev_factor} ${__att_aggr} ${VC_EXTRAS}
fi
