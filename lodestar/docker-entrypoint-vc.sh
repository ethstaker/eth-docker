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


if [[ "${NETWORK}" =~ ^https?:// ]]; then
  echo "Custom testnet at ${NETWORK}"
  repo=$(awk -F'/tree/' '{print $1}' <<< "${NETWORK}")
  branch=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f1)
  config_dir=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f2-)
  echo "This appears to be the ${repo} repo, branch ${branch} and config directory ${config_dir}."
  # For want of something more amazing, let's just fail if git fails to pull this
  set -e
  if [[ ! -d "/var/lib/lodestar/validators/testnet/${config_dir}" ]]; then
    mkdir -p /var/lib/lodestar/validators/testnet
    cd /var/lib/lodestar/validators/testnet
    git init --initial-branch="${branch}"
    git remote add origin "${repo}"
    git config core.sparseCheckout true
    echo "${config_dir}" > .git/info/sparse-checkout
    git pull origin "${branch}"
  fi
  set +e
  __network="--paramsFile=/var/lib/lodestar/validators/testnet/${config_dir}/config.yaml"
else
  __network="--network ${NETWORK}"
fi

# Check whether we should use MEV Boost
if [[ "${MEV_BOOST}" = "true" ]]; then
  __mev_boost="--builder"
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
      __mev_boost="--builder.selection maxprofit"
      __mev_factor="--builder.boostFactor ${build_factor}"
      echo "Enabled MEV Build Factor of ${build_factor}"
      ;;
    100)
      __mev_boost="--builder.selection builderalways"
      __mev_factor=""
      echo "Always prefer MEV builder blocks, MEV_BUILD_FACTOR 100"
      ;;
    "")
      __mev_factor=""
      echo "Use default --builder.boostFactor"
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
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" ${__network} ${__mev_boost} ${__mev_factor} ${__beacon_stats} ${__doppel} ${__w3s_url} ${__att_aggr} ${VC_EXTRAS}
else
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" ${__network} "--graffiti" "${GRAFFITI}" ${__mev_boost} ${__mev_factor} ${__beacon_stats} ${__doppel} ${__w3s_url} ${__att_aggr} ${VC_EXTRAS}
fi
