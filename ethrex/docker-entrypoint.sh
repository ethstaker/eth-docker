#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R ethrex:ethrex /var/lib/ethrex
  exec gosu ethrex "${BASH_SOURCE[0]}" "$@"
fi


# Because we're oh-so-clever with + substitution and maxpeers, we may have empty args. Remove them
__strip_empty_args() {
  local arg
  __args=()
  for arg in "$@"; do
    if [[ -n "${arg}" ]]; then
      __args+=("${arg}")
    fi
  done
}


if [[ -d /var/lib/ethrex/ee-secret ]]; then
  rm -rf /var/lib/ethrex/ee-secret/  # Remove legacy dir
fi

if [[ -n "${JWT_SECRET}" ]]; then
  echo -n "${JWT_SECRET}" > /var/lib/ee-secret/jwtsecret
  echo "JWT secret was supplied in .env"
fi

if [[ ! -f /var/lib/ee-secret/jwtsecret ]]; then
  echo "Generating JWT secret"
  secret1=$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)
  secret2=$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)
  echo -n "${secret1}""${secret2}" > /var/lib/ee-secret/jwtsecret
fi

if [[ -O /var/lib/ee-secret ]]; then
  # In case someone specifies JWT_SECRET but it's not a distributed setup
  chmod 777 /var/lib/ee-secret
fi
if [[ -O /var/lib/ee-secret/jwtsecret ]]; then
  chmod 666 /var/lib/ee-secret/jwtsecret
fi

if [[ "${NETWORK}" =~ ^https?:// ]]; then
  echo "Custom testnet at ${NETWORK}"
  repo=$(awk -F'/tree/' '{print $1}' <<< "${NETWORK}")
  branch=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f1)
  config_dir=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f2-)
  echo "This appears to be the ${repo} repo, branch ${branch} and config directory ${config_dir}."
  # For want of something more amazing, let's just fail if git fails to pull this
  set -e
  if [[ ! -d "/var/lib/ethrex/testnet/${config_dir}" ]]; then
    mkdir -p /var/lib/ethrex/testnet
    cd /var/lib/ethrex/testnet
    git init --initial-branch="${branch}"
    git remote add origin "${repo}"
    git config core.sparseCheckout true
    echo "${config_dir}" > .git/info/sparse-checkout
    git pull origin "${branch}"
  fi
  bootnodes="$(awk -F'- ' '!/^#/ && NF>1 {print $2}' "/var/lib/ethrex/testnet/${config_dir}/enodes.yaml" | paste -sd ",")"
  set +e
  __network="--network /var/lib/ethrex/testnet/${config_dir}/genesis.json --bootnodes ${bootnodes}"
else
  __network="--network ${NETWORK}"
fi

case "${NODE_TYPE}" in
  archive)
    echo "Ethrex does not support running an archive node; or Eth Docker doesn't know how"
    sleep 30
    exit 1
    ;;
  full)
    case ${NETWORK} in
      mainnet|sepolia)
        echo "Ethrex does not support full sync on ${NETWORK}. Running an expired node with snap sync"
        __sync="--syncmode snap"
        ;;
      *)
        echo "There is no pre-merge history for ${NETWORK} network, running a full sync as requested"
        __sync="--syncmode full"
        ;;
    esac
    ;;
  pre-merge-expiry)
    echo "Ethrex minimal node with pre-merge history expiry and snap sync"
    __sync="--syncmode snap"
    ;;
  *)
    echo "ERROR: The node type ${NODE_TYPE} is not known to Eth Docker's Ethrex implementation."
    sleep 30
    exit 1
    ;;
esac

__strip_empty_args "$@"
set -- "${__args[@]}"

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${__network} ${__sync} ${EL_EXTRAS}
