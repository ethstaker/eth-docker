#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$(id -u)" = '0' ]; then
  chown -R reth:reth /var/lib/reth
  exec gosu reth "${BASH_SOURCE[0]}" "$@"
fi

if [ -n "${JWT_SECRET}" ]; then
  echo -n "${JWT_SECRET}" > /var/lib/reth/ee-secret/jwtsecret
  echo "JWT secret was supplied in .env"
fi

if [[ ! -f /var/lib/reth/ee-secret/jwtsecret ]]; then
  echo "Generating JWT secret"
  __secret1=$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)
  __secret2=$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)
  echo -n "${__secret1}""${__secret2}" > /var/lib/reth/ee-secret/jwtsecret
fi

if [[ -O "/var/lib/reth/ee-secret" ]]; then
  # In case someone specifies JWT_SECRET but it's not a distributed setup
  chmod 777 /var/lib/reth/ee-secret
fi
if [[ -O "/var/lib/reth/ee-secret/jwtsecret" ]]; then
  chmod 666 /var/lib/reth/ee-secret/jwtsecret
fi

if [[ "${NETWORK}" =~ ^https?:// ]]; then
  echo "Custom testnet at ${NETWORK}"
  repo=$(awk -F'/tree/' '{print $1}' <<< "${NETWORK}")
  branch=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f1)
  config_dir=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f2-)
  echo "This appears to be the ${repo} repo, branch ${branch} and config directory ${config_dir}."
  # For want of something more amazing, let's just fail if git fails to pull this
  set -e
  if [ ! -d "/var/lib/reth/testnet/${config_dir}" ]; then
    mkdir -p /var/lib/reth/testnet
    cd /var/lib/reth/testnet
    git init --initial-branch="${branch}"
    git remote add origin "${repo}"
    git config core.sparseCheckout true
    echo "${config_dir}" > .git/info/sparse-checkout
    git pull origin "${branch}"
  fi
  bootnodes="$(awk -F'- ' '!/^#/ && NF>1 {print $2}' "/var/lib/reth/testnet/${config_dir}/enodes.yaml" | paste -sd ",")"
  set +e
  __network="--chain=/var/lib/reth/testnet/${config_dir}/genesis.json --bootnodes=${bootnodes}"
else
  __network="--chain ${NETWORK}"
fi

# Set verbosity
shopt -s nocasematch
case ${LOG_LEVEL} in
  error)
    __verbosity="-v"
    ;;
  warn)
    __verbosity="-vv"
    ;;
  info)
    __verbosity="-vvv"
    ;;
  debug)
    __verbosity="-vvvv"
    ;;
  trace)
    __verbosity="-vvvvv"
    ;;
  *)
    echo "LOG_LEVEL ${LOG_LEVEL} not recognized"
    __verbosity=""
    ;;
esac

__static=""
if [ -n "${STATIC_DIR}" ] && [ ! "${STATIC_DIR}" = ".nada" ]; then
  echo "Using separate static files directory at ${STATIC_DIR}."
  __static="--datadir.static-files /var/lib/static"
fi

if [ "${ARCHIVE_NODE}" = "true" ]; then
  echo "Reth archive node without pruning"
  __prune=""
elif [ "${MINIMAL_NODE}" = "true" ]; then
  __prune="--block-interval 5 --prune.senderrecovery.full --prune.accounthistory.distance 10064 --prune.storagehistory.distance 10064 --prune.transactionlookup.distance 10064"
  case ${NETWORK} in
    mainnet|sepolia )
      echo "Reth minimal node with pre-merge history expiry"
      __prune+=" --prune.bodies.pre-merge --prune.receipts.pre-merge"
      ;;
    *)
      echo "There is no pre-merge history for ${NETWORK} network, EL_MINIMAL_NODE has no effect."
      __prune+=" --prune.receipts.before 0"
      ;;
  esac
  echo "Pruning parameters: ${__prune}"
else
   echo "Reth full node without pre-merge history expiry"
  __prune="--block-interval 5 --prune.receipts.before 0 --prune.senderrecovery.full --prune.accounthistory.distance 10064 --prune.storagehistory.distance 10064"
  echo "Pruning parameters: ${__prune}"
fi

if [ -f /var/lib/reth/repair-trie ]; then
  if [[ "${NETWORK}" =~ ^https?:// ]]; then
    echo "Can't repair database on custom network"
    rm "var/lib/reth/repair-trie"
  else
    rm "var/lib/reth/repair-trie"  # Remove first in case this panics
    echo "Running Reth database trie repair. This may take up to 2 hours"
# shellcheck disable=SC2086
    reth db --chain "${NETWORK}" --datadir /var/lib/reth ${__static} repair-trie
  fi
fi

if [ -f /var/lib/reth/prune-marker ]; then
  rm -f /var/lib/reth/prune-marker
  if [ "${ARCHIVE_NODE}" = "true" ]; then
    echo "Reth is an archive node. Not attempting to prune database: Aborting."
    exit 1
  fi
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec reth prune ${__network} --datadir /var/lib/reth ${__static}
else
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" ${__network} ${__verbosity} ${__static} ${__prune} ${EL_EXTRAS}
fi
