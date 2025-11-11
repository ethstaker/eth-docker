#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R geth:geth /var/lib/geth
  exec su-exec geth docker-entrypoint.sh "$@"
fi


# Because we're oh-so-clever with + substitution and maxpeers, we may have empty args. Remove them
__strip_empty_args() {
  local __arg
  __args=()
  for __arg in "$@"; do
    if [[ -n "$__arg" ]]; then
      __args+=("$__arg")
    fi
  done
}


if [[ -n "${JWT_SECRET}" ]]; then
  echo -n "${JWT_SECRET}" > /var/lib/geth/ee-secret/jwtsecret
  echo "JWT secret was supplied in .env"
fi

if [[ ! -f /var/lib/geth/ee-secret/jwtsecret ]]; then
  echo "Generating JWT secret"
  __secret1=$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)
  __secret2=$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)
  echo -n "${__secret1}""${__secret2}" > /var/lib/geth/ee-secret/jwtsecret
fi

if [[ -O /var/lib/geth/ee-secret ]]; then
  # In case someone specifies JWT_SECRET but it's not a distributed setup
  chmod 777 /var/lib/geth/ee-secret
fi
if [[ -O /var/lib/geth/ee-secret/jwtsecret ]]; then
  chmod 666 /var/lib/geth/ee-secret/jwtsecret
fi

__ancient=""

if [[ -n "${ANCIENT_DIR}" && ! "${ANCIENT_DIR}" = ".nada" ]]; then
  echo "Using separate ancient directory at ${ANCIENT_DIR}."
  __ancient="--datadir.ancient /var/lib/ancient"
fi

if [[ "${NETWORK}" =~ ^https?:// ]]; then
  echo "Custom testnet at ${NETWORK}"
  repo=$(awk -F'/tree/' '{print $1}' <<< "${NETWORK}")
  branch=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f1)
  config_dir=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f2-)
  echo "This appears to be the ${repo} repo, branch ${branch} and config directory ${config_dir}."
  # For want of something more amazing, let's just fail if git fails to pull this
  set -e
  if [[ ! -d "/var/lib/geth/testnet/${config_dir}" ]]; then
    mkdir -p /var/lib/geth/testnet
    cd /var/lib/geth/testnet
    git init --initial-branch="${branch}"
    git remote add origin "${repo}"
    git config core.sparseCheckout true
    echo "${config_dir}" > .git/info/sparse-checkout
    git pull origin "${branch}"
  fi
  bootnodes="$(awk -F'- ' '!/^#/ && NF>1 {print $2}' "/var/lib/geth/testnet/${config_dir}/enodes.yaml" | paste -sd ",")"
  networkid="$(jq -r '.config.chainId' "/var/lib/geth/testnet/${config_dir}/genesis.json")"
  set +e
  __network="--bootnodes=${bootnodes} --networkid=${networkid}"
  if [[ ! -d /var/lib/geth/geth/chaindata/ ]]; then
    geth init --datadir /var/lib/geth "/var/lib/geth/testnet/${config_dir}/genesis.json"
  fi
else
  __network="--${NETWORK}"
fi

# New or old datadir
if [[ -d /var/lib/goethereum/geth/chaindata ]]; then
  __datadir="--datadir /var/lib/goethereum"
else
  __datadir="--datadir /var/lib/geth"
fi

# Set verbosity
shopt -s nocasematch
case ${LOG_LEVEL} in
  error)
    __verbosity="--verbosity 1"
    ;;
  warn)
    __verbosity="--verbosity 2"
    ;;
  info)
    __verbosity="--verbosity 3"
    ;;
  debug)
    __verbosity="--verbosity 4"
    ;;
  trace)
    __verbosity="--verbosity 5"
    ;;
  *)
    echo "LOG_LEVEL ${LOG_LEVEL} not recognized"
    __verbosity=""
    ;;
esac

if [[ "${ARCHIVE_NODE}" = "true" ]]; then
  echo "Geth archive node without pruning"
  if [[ ! -d /var/lib/geth/geth/chaindata && ! -d /var/lib/goethereum/geth/chaindata ]]; then
    touch /var/lib/geth/path-archive
  fi
  if [[ -f /var/lib/geth/path-archive ]]; then
    __prune="--syncmode=full --state.scheme=path --history.state=0"
  else
    __prune="--syncmode=full --gcmode=archive"
  fi
elif [[ "${MINIMAL_NODE}" = "true" ]]; then
  case "${NETWORK}" in
    mainnet | sepolia )
       echo "Geth minimal node with pre-merge history expiry"
      __prune="--history.chain postmerge"
      ;;
    * )
      echo "There is no pre-merge history for ${NETWORK} network, EL_MINIMAL_NODE has no effect."
      __prune=""
      ;;
  esac
else
  echo "Geth full node without history expiry"
  __prune=""
fi

__strip_empty_args "$@"
set -- "${__args[@]}"

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
if [[ -f /var/lib/geth/prune-marker ]]; then
  rm -f /var/lib/geth/prune-marker
  if [[ "${ARCHIVE_NODE}" = "true" ]]; then
    echo "Geth is an archive node. Not attempting to prune: Aborting."
    exit 1
  fi
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" ${__datadir} ${__ancient} ${__network} ${EL_EXTRAS} prune-history
else
  exec "$@" ${__datadir} ${__ancient} ${__network} ${__prune} ${__verbosity} ${EL_EXTRAS}
fi
