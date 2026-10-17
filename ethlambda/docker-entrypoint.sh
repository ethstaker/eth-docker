#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R ethlambda:ethlambda /var/lib/ethlambda
  exec gosu ethlambda docker-entrypoint.sh "$@"
fi

if [[ "${IPV6:-false}" = "true" ]]; then
  echo "WARNING: IPV6 is true, but ethlambda only listens on IPv4. IPv6 is ignored."
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


if [[ -n "${JWT_SECRET}" ]]; then
  echo -n "${JWT_SECRET}" > /var/lib/ethlambda/ee-secret/jwtsecret
  echo "JWT secret was supplied in .env"
fi

if [[ -O /var/lib/ethlambda/ee-secret ]]; then
  # In case someone specifies JWT_SECRET but it's not a distributed setup
  chmod 777 /var/lib/ethlambda/ee-secret
fi
if [[ -O /var/lib/ethlambda/ee-secret/jwtsecret ]]; then
  chmod 666 /var/lib/ethlambda/ee-secret/jwtsecret
fi

# Without a persistent node key, ethlambda generates one on every start, and the PeerId and ENR change
if [[ ! -f /var/lib/ethlambda/node.key ]]; then
  echo "Creating P2P node key"
  od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > /var/lib/ethlambda/node.key
  chmod 600 /var/lib/ethlambda/node.key
fi

__builtin_network=0
if [[ "${NETWORK}" = "ephemery" ]]; then
  config_dir_path="$(ephemery-config.sh /var/lib/ethlambda/testnet/ephemery)"
  # A new iteration has a new genesis, and the beacon DB of the old one is for a dead chain
  __iteration="$(basename "$(dirname "${config_dir_path}")")"
  if [[ -f /var/lib/ethlambda/ephemery-iteration ]]; then
    __old_iteration="$(cat /var/lib/ethlambda/ephemery-iteration)"
    if [[ ! "${__old_iteration}" = "${__iteration}" ]]; then
      echo "Ephemery reset from ${__old_iteration} to ${__iteration}, removing the old beacon chain data"
      rm -rf /var/lib/ethlambda/beacon
    fi
  fi
  echo "${__iteration}" > /var/lib/ethlambda/ephemery-iteration
  __network="--network ${config_dir_path}"
elif [[ "${NETWORK}" =~ ^https?:// ]]; then
  echo "Custom testnet at ${NETWORK}"
  repo=$(awk -F'/tree/' '{print $1}' <<< "${NETWORK}")
  branch=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f1)
  config_dir=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f2-)
  echo "This appears to be the ${repo} repo, branch ${branch} and config directory ${config_dir}."
  if [[ ! -d "/var/lib/ethlambda/testnet/${config_dir}" ]]; then
    mkdir -p /var/lib/ethlambda/testnet
    cd /var/lib/ethlambda/testnet
    git init --initial-branch="${branch}"
    git remote add origin "${repo}"
    git config core.sparseCheckout true
    echo "${config_dir}" > .git/info/sparse-checkout
    git pull origin "${branch}"
  fi
  __network="--network /var/lib/ethlambda/testnet/${config_dir}"
elif [[ "${NETWORK}" =~ ^(mainnet|hoodi|sepolia)$ ]]; then
  __builtin_network=1
  __network="--network ${NETWORK}"
else
  echo "ERROR: ethlambda does not support the network ${NETWORK}."
  sleep 30
  exit 1
fi

case "${NODE_TYPE}" in
  full|pruned)
    ;;
  *)
    echo "ERROR: The node type ${NODE_TYPE} is not supported by Eth Docker's ethlambda implementation."
    sleep 30
    exit 1
    ;;
esac

if [[ "${EL_NODE_TYPE}" = "use-cl-zkproofs" ]]; then
  echo "ERROR: ethlambda does not support zkProof verification."
  sleep 30
  exit 1
fi

# Check whether we should rapid sync
if [[ -n "${CHECKPOINT_SYNC_URL}" ]]; then
  __checkpoint_sync="--checkpoint-sync-url ${CHECKPOINT_SYNC_URL}"
  echo "Checkpoint sync enabled"
else
  __checkpoint_sync=""
  # A custom network can anchor at its own genesis.ssz, a built-in one cannot
  if [[ "${__builtin_network}" -eq 1 && ! -d /var/lib/ethlambda/beacon ]]; then
    echo "ERROR: ethlambda cannot sync ${NETWORK} from genesis. Please set CHECKPOINT_SYNC_URL in \".env\"."
    sleep 30
    exit 1
  fi
fi

if [[ "${MEV_BOOST}" = "true" ]]; then
  echo "MEV_BOOST is true, but ethlambda does not support MEV Boost. Ignoring it."
fi

__strip_empty_args "$@"
set -- "${__args[@]}"

i=0
while true; do
  if [ -f /var/lib/ethlambda/ee-secret/jwtsecret ]; then
    break
  else
    if [[ "$i" -eq 5 ]]; then
      echo "Did not see the JWT secret file six times in a row. This is either a bug or a very slow execution layer client startup."
      echo "Starting consensus layer client anyway: It may fail."
      break
    else
      echo "Waiting for JWT secret file to be created by execution layer client"
      sleep 5
      ((++i))
    fi
  fi
done

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${__network} ${__checkpoint_sync} --execution-endpoint ${EL_NODE} \
  --execution-jwt-secret /var/lib/ethlambda/ee-secret/jwtsecret ${CL_EXTRAS}
