#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R gdvalidator:gdvalidator /var/lib/grandine-vc
  exec gosu gdvalidator docker-entrypoint-vc.sh "$@"
fi


__normalize_int() {
  local v=$1
  if [[ "${v}" =~ ^[0-9]+$ ]]; then
    v=$((10#${v}))
  fi
  printf '%s' "${v}"
}


if [[ ! -f /var/lib/grandine-vc/wallet-password.txt ]]; then
  echo "Creating password for Grandine key wallet"
  head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1 > /var/lib/grandine-vc/wallet-password.txt
fi

if [[ "${NETWORK}" =~ ^https?:// ]]; then
  echo "Custom testnet at ${NETWORK}"
  repo=$(awk -F'/tree/' '{print $1}' <<< "${NETWORK}")
  branch=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f1)
  config_dir=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f2-)
  echo "This appears to be the ${repo} repo, branch ${branch} and config directory ${config_dir}."
  if [[ ! -d "/var/lib/grandine-vc/testnet/${config_dir}" ]]; then
    mkdir -p /var/lib/grandine-vc/testnet
    cd /var/lib/grandine-vc/testnet
    git init --initial-branch="${branch}"
    git remote add origin "${repo}"
    git config core.sparseCheckout true
    echo "${config_dir}" > .git/info/sparse-checkout
    git pull origin "${branch}"
  fi
  config_dir_path="/var/lib/grandine-vc/testnet/${config_dir}"
  __network="--configuration-directory=${config_dir_path} --network=custom"
else
  __network="--network=${NETWORK}"
fi

# Adjust RIGHT after Glamsterdam
# Check whether we should use ePBS
if [[ "${MEV_BOOST}" = "true" ]]; then
  echo "MEV Boost enabled"
  __epbs="--use-builder"
  build_factor="$(__normalize_int "${EPBS_BUILD_FACTOR}")"
  case "${build_factor}" in
    0)
      __epbs+=" --default-builder-boost-factor ${build_factor}"
      #echo "Build blocks locally, use ePBS builders as fallback. EPBS_BUILD_FACTOR is 0."
      echo "Build blocks locally. EPBS_BUILD_FACTOR is 0."
      ;;
    [1-9]|[1-9][0-9])
      __epbs+=" --default-builder-boost-factor ${build_factor}"
      echo "Enabled PBS Build Factor of ${build_factor}"
      ;;
    100)
      __epbs+=" --default-builder-boost-factor 18446744073709551615"
      #echo "Always prefer ePBS builder blocks, EPBS_BUILD_FACTOR 100"
      echo "Always prefer PBS builder blocks, EPBS_BUILD_FACTOR 100"
      ;;
    "")
      echo "Use default --default-builder-boost-factor"
      ;;
    *)
      echo "WARNING: EPBS_BUILD_FACTOR has an invalid value of \"${build_factor}\""
      ;;
  esac
else
#  __epbs="--default-builder-boost-factor 0"
#  echo "Build blocks locally, use ePBS builders as fallback."
  __epbs=""
fi

# Check whether we should enable doppelganger protection
if [[ "${DOPPELGANGER}" = "true" ]]; then
  __doppel="--detect-doppelgangers"
  echo "Doppelganger protection enabled"
else
  __doppel=""
fi

# Web3signer URL
if [[ "${WEB3SIGNER}" = "true" ]]; then
  __w3s_url="--web3signer-urls ${W3S_NODE}"
  while true; do
    if curl -s -m 5 "${W3S_NODE}" &> /dev/null; then
      echo "web3signer is up, starting Grandine"
      break
    else
      echo "Waiting for web3signer to be reachable..."
      sleep 5
    fi
  done
else
  __w3s_url=""
fi

if [[ "${DEFAULT_GRAFFITI}" != "true" ]]; then
  __graffiti_args=(--graffiti "${GRAFFITI}")
else
  __graffiti_args=()
fi

# Traces
if [[ "${COMPOSE_FILE}" =~ (grafana\.yml|grafana-rootless\.yml) ]]; then
  __trace="--telemetry-metrics-url http://tempo:4317 --telemetry-service-name grandine-vc --telemetry-level ${LOG_LEVEL:-info}"
# These may become default in future. Here so Grandine doesn't murder itself in the meantime
  export OTEL_TRACES_SAMPLER=parentbased_traceidratio
  export OTEL_TRACES_SAMPLER_ARG=0.01
  export OTEL_EXPORTER_OTLP_INSECURE=true
  export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
else
  __trace=""
fi

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${__network} ${__w3s_url} "${__graffiti_args[@]}" ${__trace} ${__epbs} ${__doppel} ${VC_EXTRAS}
