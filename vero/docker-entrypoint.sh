#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R vero:vero /var/lib/vero
  exec gosu vero docker-entrypoint.sh "$@"
fi

__normalize_int() {
    local v=$1
    if [[ $v =~ ^[0-9]+$ ]]; then
        v=$((10#$v))
    fi
    printf '%s' "$v"
}

if [[ "${NETWORK}" =~ ^https?:// ]]; then
  echo "Custom testnet at ${NETWORK}"
  repo=$(awk -F'/tree/' '{print $1}' <<< "${NETWORK}")
  branch=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f1)
  config_dir=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f2-)
  echo "This appears to be the ${repo} repo, branch ${branch} and config directory ${config_dir}."
  # For want of something more amazing, let's just fail if git fails to pull this
  set -e
  if [[ ! -d "/var/lib/vero/testnet/${config_dir}" ]]; then
    mkdir -p /var/lib/vero/testnet
    cd /var/lib/vero/testnet
    git init --initial-branch="${branch}"
    git remote add origin "${repo}"
    git config core.sparseCheckout true
    echo "${config_dir}" > .git/info/sparse-checkout
    git pull origin "${branch}"
  fi
  set +e
  __network="--network-custom-config-path=/var/lib/vero/testnet/${config_dir}/config.yaml"
else
  __network="--network ${NETWORK}"
fi

# Check whether we should use MEV Boost
if [[ "${MEV_BOOST}" = "true" ]]; then
  __mev_boost="--use-external-builder"
  echo "MEV Boost enabled"

  __build_factor="$(__normalize_int "${MEV_BUILD_FACTOR}")"
  case "${__build_factor}" in
    0)
      __mev_boost=""
      __mev_factor=""
      echo "Disabled MEV Boost because MEV_BUILD_FACTOR is 0."
      echo "WARNING: This conflicts with MEV_BOOST true. Set factor in a range of 1 to 100"
      ;;
    [1-9]|[1-9][0-9])
      __mev_factor="--builder-boost-factor ${__build_factor}"
      echo "Enabled MEV Build Factor of ${__build_factor}"
      ;;
    100)
      __mev_factor="--builder-boost-factor 18446744073709551615"
      echo "Always prefer MEV builder blocks, build factor 100"
      ;;
    "")
      __mev_factor=""
      echo "Use default --builder-boost-factor"
      ;;
    *)
      __mev_factor=""
      echo "WARNING: MEV_BUILD_FACTOR has an invalid value of \"${__build_factor}\""
      ;;
  esac
else
  __mev_boost=""
  __mev_factor=""
fi

# Check whether we should send stats to beaconcha.in
#if [[ -n "${BEACON_STATS_API}" ]]; then
#  __beacon_stats="--monitoring.endpoint https://beaconcha.in/api/v1/client/metrics?apikey=${BEACON_STATS_API}&machine=${BEACON_STATS_MACHINE}"
#  echo "Beacon stats API enabled"
#else
#  __beacon_stats=""
#fi

# Check whether we should enable doppelganger protection
if [[ "${DOPPELGANGER}" = "true" ]]; then
  __doppel="--enable-doppelganger-detection"
  echo "Doppelganger protection enabled, VC will pause for 2 epochs"
else
  __doppel=""
fi

# Web3signer URL
if [[ ! "${WEB3SIGNER}" = "true" ]]; then
  echo "Vero requires the use of web3signer.yml and WEB3SIGNER=true. Please reconfigure to use Web3Signer and start again"
  sleep 60
  exit 1
fi

# Uppercase log level
__log_level="--log-level ${LOG_LEVEL^^}"

if [[ "${DEFAULT_GRAFFITI}" = "true" ]]; then
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" ${__network} ${__mev_boost} ${__mev_factor} ${__log_level} ${__doppel} ${VC_EXTRAS}
else
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" ${__network} "--graffiti" "${GRAFFITI}" ${__mev_boost} ${__mev_factor} ${__log_level} ${__doppel} ${VC_EXTRAS}
fi
