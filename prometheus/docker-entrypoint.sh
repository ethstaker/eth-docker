#!/bin/sh

set -eu

cd /etc/prometheus

select_clients() {
  num_files=0

  # Start from scratch every time
  rm -rf rootless.d
  mkdir rootless.d

  case "${CLIENT}" in
    *lighthouse.yml* )  cp ./rootless/lh-prom.yml ./rootless.d ;;
    *lighthouse-cl-only* ) cp ./rootless/lhcc-prom.yml ./rootless.d ;;
    *prysm.yml* ) cp ./rootless/prysm-prom.yml ./rootless.d ;;
    *prysm-cl-only* ) cp ./rootless/prysmcc-prom.yml ./rootless.d ;;
    *nimbus.yml* ) cp ./rootless/nimbus-prom.yml ./rootless.d ;;
    *nimbus-cl-only* ) cp ./rootless/nimbus-prom.yml ./rootless.d ;;
    *teku.yml* ) cp ./rootless/teku-prom.yml ./rootless.d ;;
    *teku-cl-only* ) cp ./rootless/teku-prom.yml ./rootless.d ;;
    *lodestar.yml* ) cp ./rootless/ls-prom.yml ./rootless.d ;;
    *lodestar-cl-only* ) cp ./rootless/lscc-prom.yml ./rootless.d ;;
    *vero-vc-only* ) cp ./rootless/vero-prom.yml ./rootless.d ;;
    * ) ;;
  esac

  case "${CLIENT}" in
    *geth* ) cp ./rootless/geth-prom.yml ./rootless.d ;;
    *erigon* ) cp ./rootless/erigon-prom.yml ./rootless.d ;;
    *besu* ) cp ./rootless/besu-prom.yml ./rootless.d ;;
    *nethermind* ) cp ./rootless/nethermind-prom.yml ./rootless.d ;;
    *reth* ) cp ./rootless/reth-prom.yml ./rootless.d ;;
  esac

  case "${CLIENT}" in
    *web3signer.yml* ) cp ./rootless/web3signer-prom.yml ./rootless.d ;;
  esac

  case "${CLIENT}" in
    *ssv.yml* ) cp ./rootless/ssv-prom.yml ./rootless.d ;;
  esac

  case "${CLIENT}" in
    *lido-obol.yml* ) cp ./rootless/lido-obol-prom.yml ./rootless.d ;;
  esac

  case "${CLIENT}" in
    *traefik-* ) cp ./rootless/traefik-prom.yml ./rootless.d ;;
  esac

  num_files="$(find ./rootless.d -type f | wc -l)"
  if [ "${num_files}" -gt 0 ]; then
    echo "Activated ${num_files} configuration files"
  else
    echo "No Prometheus configurations have been enabled based on the provided CLIENT variable"
  fi
}

__config_file=/etc/prometheus/prometheus.yml
prepare_config() {
  base_config=""

  # CLIENT is only set for rootless mode
  if [ -z "${CLIENT:-}" ]; then
    echo "No Client information passed, running in Docker target detection mode"
    base_config=base-config.yml
  else
    echo "Client information detected, compiling prometheus config"
    select_clients
    base_config=rootless-base-config.yml
  fi

  # Merge custom config overrides, if provided
  if [ -s custom-prom.yml ]; then
    echo "Applying custom configuration"
    # $item isn't a shell variable, single quotes OK here
    # shellcheck disable=SC2016
    yq eval-all '. as $item ireduce ({}; . *+ $item)' "${base_config}" custom-prom.yml > "${__config_file}"
  else
    echo "No custom configuration detected"
    cp "${base_config}" "${__config_file}"
  fi
}

# Check if --config.file was passed in the command arguments
# If it was, then display a warning and skip all our manual processing
for arg in "$@"; do
  case "${arg}" in
    --config.file* )
      echo "WARNING - Manual setting of --config.file found, bypassing automated config preparation in favour of supplied argument"
      /bin/prometheus "$@"
  esac
done

prepare_config
exec /bin/prometheus "$@" --config.file="${__config_file}"
