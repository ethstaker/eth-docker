#!/usr/bin/env bash

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R teku:teku /var/lib/teku
  exec gosu teku docker-entrypoint.sh "$@"
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


if [[ -f /var/lib/teku/teku-keyapi.keystore ]]; then
    if [[ "$(date +%s -r /var/lib/teku/teku-keyapi.keystore)" -lt "$(date +%s --date="300 days ago")" ]]; then
       rm /var/lib/teku/teku-keyapi.keystore
    elif ! openssl x509 -noout -ext subjectAltName -in /var/lib/teku/teku-keyapi.crt | grep -q 'DNS:consensus'; then
       rm /var/lib/teku/teku-keyapi.keystore
    fi
fi

if [[ ! -f /var/lib/teku/teku-keyapi.keystore ]]; then
  password=$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum| head -c 32)
  echo "${password}" > /var/lib/teku/teku-keyapi.password
  openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes -keyout /var/lib/teku/teku-keyapi.key -out /var/lib/teku/teku-keyapi.crt -subj '/CN=teku-keyapi-cert' -extensions san -config <( \
    echo '[req]'; \
    echo 'distinguished_name=req'; \
    echo '[san]'; \
    echo 'subjectAltName=DNS:localhost,DNS:consensus,DNS:validator,DNS:vc,IP:127.0.0.1')
  openssl pkcs12 -export -in /var/lib/teku/teku-keyapi.crt -inkey /var/lib/teku/teku-keyapi.key -out /var/lib/teku/teku-keyapi.keystore -name teku-keyapi -passout pass:"${password}"
fi

if [[ -n "${JWT_SECRET}" ]]; then
  echo -n "${JWT_SECRET}" > /var/lib/teku/ee-secret/jwtsecret
  echo "JWT secret was supplied in .env"
fi

if [[ -O /var/lib/teku/ee-secret ]]; then
  # In case someone specifies JWT_SECRET but it's not a distributed setup
  chmod 777 /var/lib/teku/ee-secret
fi
if [[ -O /var/lib/teku/ee-secret/jwtsecret ]]; then
  chmod 666 /var/lib/teku/ee-secret/jwtsecret
fi

# Check whether we should rapid sync
if [[ -n "${CHECKPOINT_SYNC_URL:+x}" ]]; then
  if [[ "${ARCHIVE_NODE}" = "true" ]]; then
    echo "Teku archive node cannot use checkpoint sync: Syncing from genesis."
      __checkpoint_sync="--ignore-weak-subjectivity-period-enabled=true"
    if [[ "${NETWORK}" = "hoodi" ]]; then
      __checkpoint_sync+=" --initial-state=https://checkpoint-sync.hoodi.ethpandaops.io/eth/v2/debug/beacon/states/genesis"
    fi
  else
    __checkpoint_sync="--checkpoint-sync-url=${CHECKPOINT_SYNC_URL}"
    echo "Checkpoint sync enabled"
  fi
else
  __checkpoint_sync="--ignore-weak-subjectivity-period-enabled=true"
  if [[ "${NETWORK}" = "hoodi" ]]; then
    __checkpoint_sync+=" --initial-state=https://checkpoint-sync.hoodi.ethpandaops.io/eth/v2/debug/beacon/states/genesis"
  fi
fi

if [[ "${NETWORK}" =~ ^https?:// ]]; then
  echo "Custom testnet at ${NETWORK}"
  repo=$(awk -F'/tree/' '{print $1}' <<< "${NETWORK}")
  branch=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f1)
  config_dir=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f2-)
  echo "This appears to be the ${repo} repo, branch ${branch} and config directory ${config_dir}."
  # For want of something more amazing, let's just fail if git fails to pull this
  set -e
  if [[ ! -d "/var/lib/teku/testnet/${config_dir}" ]]; then
    mkdir -p /var/lib/teku/testnet
    cd /var/lib/teku/testnet
    git init --initial-branch="${branch}"
    git remote add origin "${repo}"
    git config core.sparseCheckout true
    echo "${config_dir}" > .git/info/sparse-checkout
    git pull origin "${branch}"
  fi
  bootnodes="$(awk -F'- ' '!/^#/ && NF>1 {print $2}' "/var/lib/teku/testnet/${config_dir}/bootstrap_nodes.yaml" | paste -sd ",")"
  set +e
  __checkpoint_sync="--initial-state=/var/lib/teku/testnet/${config_dir}/genesis.ssz --ignore-weak-subjectivity-period-enabled=true"
  __network="--network=/var/lib/teku/testnet/${config_dir}/config.yaml --p2p-discovery-bootnodes=${bootnodes}"
else
  __network="--network=${NETWORK}"
fi

# Check whether we should use MEV Boost
if [[ "${MEV_BOOST}" = "true" ]]; then
  __mev_boost="--builder-endpoint=${MEV_NODE:-http://mev-boost:18550}"
  echo "MEV Boost enabled"
  __mev_boost+=" --validators-builder-registration-default-enabled"
  build_factor="$(__normalize_int "${MEV_BUILD_FACTOR}")"
  case "${build_factor}" in
    0)
      __mev_boost=""
      __mev_factor=""
      echo "Disabled MEV Boost because MEV_BUILD_FACTOR is 0."
      echo "WARNING: This conflicts with MEV_BOOST true. Set factor in a range of 1 to 100"
      ;;
    [1-9]|[1-9][0-9])
      __mev_factor="--builder-bid-compare-factor=${build_factor}"
      echo "Enabled MEV Build Factor of ${build_factor}"
      ;;
    100)
      __mev_factor="--builder-bid-compare-factor=BUILDER_ALWAYS"
      echo "Always prefer MEV builder blocks, MEV_BUILD_FACTOR 100"
      ;;
    "")
      __mev_factor=""
      echo "Use default --builder-bid-compare-factor"
      ;;
    *)
      __mev_factor=""
      echo "WARNING: MEV_BUILD_FACTOR has an invalid value of \"${build_factor}\""
      ;;
  esac
else
  __mev_boost=""
  __mev_factor=""
fi

# Check whether we should send stats to beaconcha.in
if [[ -n "${BEACON_STATS_API}" ]]; then
  __beacon_stats="--metrics-publish-endpoint=https://beaconcha.in/api/v1/client/metrics?apikey=${BEACON_STATS_API}&machine=${BEACON_STATS_MACHINE}"
  echo "Beacon stats API enabled"
else
  __beacon_stats=""
fi

# Check whether we should enable doppelganger protection
if [[ "${DOPPELGANGER}" = "true" ]]; then
  __doppel="--doppelganger-detection-enabled=true"
  echo "Doppelganger protection enabled, VC will pause for 2 epochs"
else
  __doppel=""
fi

if [[ "${ARCHIVE_NODE}" = "true" ]]; then
  echo "Teku archive node without pruning"
  __prune="--data-storage-mode=ARCHIVE"
else
  __prune="--data-storage-mode=MINIMAL"
fi

# Web3signer URL
if [[ "${EMBEDDED_VC}" = "true" && "${WEB3SIGNER}" = "true" ]]; then
  __w3s_url="--validators-external-signer-url ${W3S_NODE}"
#  while true; do
#    if curl -s -m 5 ${W3S_NODE} &> /dev/null; then
#      echo "web3signer is up, starting Teku"
#      break
#    else
#      echo "Waiting for web3signer to be reachable..."
#      sleep 5
#    fi
#  done
else
  __w3s_url=""
fi

if [[ "${IPV6}" = "true" ]]; then
  echo "Configuring Teku to listen on IPv6 ports"
  __ipv6="--p2p-interface 0.0.0.0,:: --p2p-port-ipv6 ${CL_IPV6_P2P_PORT:-9090}"
# ENR discovery on v6 is not yet working, likely too few peers. Manual for now
  ipv4_pattern="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
  ipv6_pattern="^[0-9A-Fa-f]{1,4}:"  # Sufficient to check the start
  set +e
  public_v4=$(curl -s -4 ifconfig.me)
  public_v6=$(curl -s -6 ifconfig.me)
  set -e
  valid_v4=0
  if [[ "${public_v4}" =~ ${ipv4_pattern} ]]; then
    valid_v4=1
  fi
  if [[ "a{$public_v6}" =~ ${ipv6_pattern} ]]; then
    if [[ "${valid_v4}" -eq 1 ]]; then
      __ipv6+=" --p2p-advertised-ips ${public_v4},${public_v6}"
    else
      __ipv6+=" --p2p-advertised-ip ${public_v6}"
    fi
  fi
else
  __ipv6=""
fi

__strip_empty_args "$@"
set -- "${__args[@]}"

if [[ "${DEFAULT_GRAFFITI}" = "true" ]]; then
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" ${__network} ${__w3s_url} ${__mev_boost} ${__mev_factor} ${__checkpoint_sync} ${__prune} ${__beacon_stats} ${__doppel} ${__ipv6} ${CL_EXTRAS} ${VC_EXTRAS}
else
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" ${__network} "--validators-graffiti=${GRAFFITI}" ${__w3s_url} ${__mev_boost} ${__mev_factor} ${__checkpoint_sync} ${__prune} ${__beacon_stats} ${__doppel} ${__ipv6} ${CL_EXTRAS} ${VC_EXTRAS}
fi
