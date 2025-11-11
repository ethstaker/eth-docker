#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R web3signer /var/lib/web3signer
  exec gosu web3signer docker-entrypoint.sh "$@"
fi

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
else
  __network="--network=${NETWORK}"
fi

if [[ -f /var/lib/web3signer/.migration_fatal_error ]]; then
    echo "An error occurred during slashing protection database migration, that makes it unsafe to start Web3signer."
    echo "Until this is manually remedied, Web3signer will refuse to start up."
    echo "Aborting."
    exit 1
fi

/flyway/flyway migrate -url="jdbc:postgresql://${PG_ALIAS}/web3signer" -user=postgres -password=postgres -locations=filesystem:/opt/web3signer/migrations/postgresql

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${__network}
