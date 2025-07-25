#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$(id -u)" = '0' ]; then
  chown -R vero:vero /var/lib/vero
  exec gosu vero docker-entrypoint.sh "$@"
fi

if [[ "${NETWORK}" =~ ^https?:// ]]; then
  echo "Custom testnet at ${NETWORK}"
  repo=$(awk -F'/tree/' '{print $1}' <<< "${NETWORK}")
  branch=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f1)
  config_dir=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f2-)
  echo "This appears to be the ${repo} repo, branch ${branch} and config directory ${config_dir}."
  # For want of something more amazing, let's just fail if git fails to pull this
  set -e
  if [ ! -d "/var/lib/vero/testnet/${config_dir}" ]; then
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
if [ "${MEV_BOOST}" = "true" ]; then
  __mev_boost="--use-external-builder"
  echo "MEV Boost enabled"
else
  __mev_boost=""
fi

# Check whether we should send stats to beaconcha.in
#if [ -n "${BEACON_STATS_API}" ]; then
#  __beacon_stats="--monitoring.endpoint https://beaconcha.in/api/v1/client/metrics?apikey=${BEACON_STATS_API}&machine=${BEACON_STATS_MACHINE}"
#  echo "Beacon stats API enabled"
#else
#  __beacon_stats=""
#fi

# Check whether we should enable doppelganger protection
if [ "${DOPPELGANGER}" = "true" ]; then
  __doppel="--enable-doppelganger-detection"
  echo "Doppelganger protection enabled, VC will pause for 2 epochs"
else
  __doppel=""
fi

# Web3signer URL
if [ ! "${WEB3SIGNER}" = "true" ]; then
  echo "Vero requires the use of web3signer.yml and WEB3SIGNER=true. Please reconfigure to use Web3Signer and start again"
  sleep 60
  exit 1
fi

# Uppercase log level
__log_level="--log-level ${LOG_LEVEL^^}"

__nodes=$(echo "$CL_NODE" | tr ',' ' ')
__cl_up=0
__count=0
while [ "${__count}" -lt 36 ]; do
  for __node in $__nodes; do
    if curl -s -m 5 "${__node}" &> /dev/null; then
      echo "Consensus Layer client ${__node} is up, starting Vero"
      __cl_up=1
      break
    else
      echo "Consensus Layer client ${__node} is not yet up."
    fi
  done
  if [[ "${__cl_up}" -eq 1 ]]; then
    break
  fi
  echo "Waiting for Consensus Layer client to be reachable..."
  sleep 5
  (( ++__count ))
done
if [ "${__cl_up}" -eq 0 ]; then
  echo "Consensus Layer client(s) ${CL_NODE} remained unreachable for 3 minutes. Please check its/their logs."
  exit 1
fi

if [ "${DEFAULT_GRAFFITI}" = "true" ]; then
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" ${__network} ${__mev_boost} ${__log_level} ${__doppel} ${VC_EXTRAS}
else
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" ${__network} "--graffiti" "${GRAFFITI}" ${__mev_boost} ${__log_level} ${__doppel} ${VC_EXTRAS}
fi
