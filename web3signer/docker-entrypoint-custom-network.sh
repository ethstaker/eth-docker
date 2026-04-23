#!/usr/bin/env bash
set -Eeuo pipefail

# Because we're oh-so-clever with custom NETWORK, we may need to remove what's already passed in.
__strip_network_args() {
  local arg
  __args=()
  for arg in "$@"; do
    if [[ ! "${arg}" = "--network=${NETWORK}" ]]; then
      __args+=("${arg}")
    fi
  done
}


if [[ "${NETWORK}" =~ ^https?:// ]]; then
  echo "Custom testnet at ${NETWORK}"
  repo=$(awk -F'/tree/' '{print $1}' <<< "${NETWORK}")
  branch=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f1)
  config_dir=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f2-)
  echo "This appears to be the ${repo} repo, branch ${branch} and config directory ${config_dir}."
  # For want of something more amazing, let's just fail if git fails to pull this
  set -e
  if [[ ! -d "/var/lib/web3signer/testnet/${config_dir}" ]]; then
    mkdir -p /var/lib/web3signer/testnet
    cd /var/lib/web3signer/testnet
    git init --initial-branch="${branch}"
    git remote add origin "${repo}"
    git config core.sparseCheckout true
    echo "${config_dir}" > .git/info/sparse-checkout
    git pull origin "${branch}"
  fi
  set +e
  __network="--network=/var/lib/web3signer/testnet/${config_dir}/config.yaml"

  __strip_network_args "$@"
  set -- "${__args[@]}"
else
  __network=""
fi

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${__network}
