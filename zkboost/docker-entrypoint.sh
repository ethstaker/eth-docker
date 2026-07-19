#!/usr/bin/env bash
set -Eeuo pipefail

case "${NETWORK}" in
  mainnet)
    NETWORK="https://github.com/eth-clients/mainnet/tree/main/metadata"
    ;;
  sepolia)
    NETWORK="https://github.com/eth-clients/sepolia/tree/main/metadata"
    ;;
  hoodi)
    NETWORK="https://github.com/eth-clients/hoodi/tree/main/metadata"
    ;;
  https://*|http://*)
    ;;
  *)
    echo "Unknown named network ${NETWORK}. Please supply a URL to its github metadata instead"
    echo "Cannot start"
    sleep 30
    exit 1
esac

if [[ "${NETWORK}" =~ ^https?:// ]]; then
  echo "Network config at ${NETWORK}"
  repo=$(awk -F'/tree/' '{print $1}' <<< "${NETWORK}")
  branch=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f1)
  config_dir=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f2-)
  echo "This appears to be the ${repo} repo, branch ${branch} and config directory ${config_dir}."
  rm -rf /var/lib/zkboost/network  # Recreate on every run, so the network can be changed
  mkdir -p /var/lib/zkboost/network
  cd /var/lib/zkboost/network
  git init --initial-branch="${branch}"
  git remote add origin "${repo}"
  git config core.sparseCheckout true
  echo "${config_dir}" > .git/info/sparse-checkout
  git pull origin "${branch}"
  mv "${config_dir}" config
fi

# Traces
if [[ "${COMPOSE_FILE}" =~ (grafana\.yml|grafana-rootless\.yml) ]]; then
# These may become default in future. Here so zkboost doesn't murder itself in the meantime
  export OTEL_TRACES_SAMPLER=parentbased_traceidratio
  export OTEL_TRACES_SAMPLER_ARG=0.01
  export OTEL_EXPORTER_OTLP_INSECURE=true
  export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
  export OTEL_EXPORTER_OTLP_ENDPOINT=http://tempo:4317
  export OTEL_SERVICE_NAME=zkboost
fi

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${ZKBOOST_EXTRAS}
