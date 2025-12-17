#!/usr/bin/env bash

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R user:user /var/lib/nimbus
  exec gosu user docker-entrypoint.sh "$@"
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


__normalize_int() {
  local v=$1
  if [[ "${v}" =~ ^[0-9]+$ ]]; then
    v=$((10#${v}))
  fi
  printf '%s' "${v}"
}


# Remove old low-entropy token, related to Sigma Prime security audit
# This detection isn't perfect - a user could recreate the token without ./ethd update
if [[ -f /var/lib/nimbus/api-token.txt && "$(date +%s -r /var/lib/nimbus/api-token.txt)" -lt "$(date +%s --date="2023-05-02 09:00:00")" ]]; then
  rm /var/lib/nimbus/api-token.txt
fi

if [[ ! -f /var/lib/nimbus/api-token.txt ]]; then
  token=api-token-0x$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)
  echo "${token}" > /var/lib/nimbus/api-token.txt
fi

if [[ -n "${JWT_SECRET}" ]]; then
  echo -n "${JWT_SECRET}" > /var/lib/nimbus/ee-secret/jwtsecret
  echo "JWT secret was supplied in .env"
fi

if [[ -O /var/lib/nimbus/ee-secret ]]; then
  # In case someone specifies JWT_SECRET but it's not a distributed setup
  chmod 777 /var/lib/nimbus/ee-secret
fi
if [[ -O /var/lib/nimbus/ee-secret/jwtsecret ]]; then
  chmod 666 /var/lib/nimbus/ee-secret/jwtsecret
fi

if [[ "${NETWORK}" =~ ^https?:// ]]; then
  echo "Custom testnet at ${NETWORK}"
  repo=$(awk -F'/tree/' '{print $1}' <<< "${NETWORK}")
  branch=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f1)
  config_dir=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f2-)
  echo "This appears to be the ${repo} repo, branch ${branch} and config directory ${config_dir}."
  # For want of something more amazing, let's just fail if git fails to pull this
  set -e
  if [[ ! -d "/var/lib/nimbus/testnet/${config_dir}" ]]; then
    mkdir -p /var/lib/nimbus/testnet
    cd /var/lib/nimbus/testnet
    git init --initial-branch="${branch}"
    git remote add origin "${repo}"
    git config core.sparseCheckout true
    echo "${config_dir}" > .git/info/sparse-checkout
    git pull origin "${branch}"
  fi
  bootnodes="$(awk -F'- ' '!/^#/ && NF>1 {print $2}' "/var/lib/nimbus/testnet/${config_dir}/bootstrap_nodes.yaml" | paste -sd ",")"
  set +e
  __network="--network=/var/lib/nimbus/testnet/${config_dir} --bootstrap-node=${bootnodes}"
else
  __network="--network=${NETWORK}"
fi

if [[ -n "${CHECKPOINT_SYNC_URL:+x}" && ! -f /var/lib/nimbus/setupdone ]]; then
  if [[ "${NODE_TYPE}" = "archive" ]]; then
    echo "Starting checkpoint sync with backfill and archive reindex. Nimbus will restart when done."
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
    /usr/local/bin/nimbus_beacon_node trustedNodeSync --backfill=true --reindex ${__network} --data-dir=/var/lib/nimbus --trusted-node-url="${CHECKPOINT_SYNC_URL}"
    touch /var/lib/nimbus/setupdone
  else
    echo "Starting checkpoint sync. Nimbus will restart when done."
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
    /usr/local/bin/nimbus_beacon_node trustedNodeSync --backfill=false ${__network} --data-dir=/var/lib/nimbus --trusted-node-url="${CHECKPOINT_SYNC_URL}"
    touch /var/lib/nimbus/setupdone
  fi
fi

# Check whether we should use MEV Boost
if [[ "${MEV_BOOST}" = "true" ]]; then
  __mev_boost="--payload-builder=true --payload-builder-url=${MEV_NODE:-http://mev-boost:18550}"
  echo "MEV Boost enabled"
  if [[ "${EMBEDDED_VC}" = "true" ]]; then
    build_factor="$(__normalize_int "${MEV_BUILD_FACTOR}")"
    case "${build_factor}" in
      0)
        __mev_boost=""
        __mev_factor=""
        echo "Disabled MEV Boost because MEV_BUILD_FACTOR is 0."
        echo "WARNING: This conflicts with MEV_BOOST true. Set factor in a range of 1 to 100"
        ;;
      [1-9]|[1-9][0-9])
        local_factor=$((100 - build_factor))
        __mev_factor="--local-block-value-boost=${local_factor}"
        echo "Enabled MEV local block value boost of ${local_factor}"
        ;;
      100)
        __mev_factor="--local-block-value-boost=0"
        echo "Do not boost local blocks, MEV_BUILD_FACTOR 100"
        echo "This may still build a local block, if it pays more than a builder block"
        ;;
      "")
        __mev_factor=""
        echo "Use default --local-block-value-boost"
        ;;
      *)
        __mev_factor=""
        echo "WARNING: MEV_BUILD_FACTOR has an invalid value of \"${build_factor}\""
        ;;
    esac
  fi
else
  __mev_boost=""
  __mev_factor=""
fi

# Check whether we should enable doppelganger protection
if [[ "${DOPPELGANGER}" = "true" ]]; then
  __doppel=""
  echo "Doppelganger protection enabled, VC will pause for 2 epochs"
else
  __doppel="--doppelganger-detection=false"
fi

__log_level="--log-level=${LOG_LEVEL^^}"

case "${NODE_TYPE}" in
  archive)
    echo "Nimbus archive node without pruning"
    __prune="--history=archive"
    ;;
  full)
    __prune=""
    ;;
  pruned)
    echo "Nimbus pruned node"
    __prune="--history=prune"
    ;;
  *)
    echo "ERROR: The node type ${NODE_TYPE} is not known to Eth Docker's Nimbus implementation."
    sleep 30
    exit 1
    ;;
esac

# Web3signer URL
if [[ "${EMBEDDED_VC}" = "true" && "${WEB3SIGNER}" = "true" ]]; then
  __w3s_url="--web3-signer-url=${W3S_NODE}"
  while true; do
    if curl -s -m 5 "${W3S_NODE}" &> /dev/null; then
      echo "Web3signer is up, starting Nimbus"
      break
    else
      echo "Waiting for Web3signer to be reachable..."
      sleep 5
    fi
  done
else
  __w3s_url=""
fi

__strip_empty_args "$@"
set -- "${__args[@]}"

if [[ "${DEFAULT_GRAFFITI}" = "true" ]]; then
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" ${__network} ${__w3s_url} ${__mev_boost} ${__mev_factor} ${__log_level} ${__doppel} ${__prune} ${CL_EXTRAS} ${VC_EXTRAS}
else
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" ${__network} ${__w3s_url} "--graffiti=${GRAFFITI}" ${__mev_boost} ${__mev_factor} ${__log_level} ${__doppel} ${__prune} ${CL_EXTRAS} ${VC_EXTRAS}
fi
