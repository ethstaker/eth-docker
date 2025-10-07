#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$(id -u)" = '0' ]; then
  chown -R gdconsensus:gdconsensus /var/lib/grandine
  exec gosu gdconsensus docker-entrypoint.sh "$@"
fi

if [ -n "${JWT_SECRET}" ]; then
  echo -n "${JWT_SECRET}" > /var/lib/grandine/ee-secret/jwtsecret
  echo "JWT secret was supplied in .env"
fi

if [[ -O "/var/lib/grandine/ee-secret" ]]; then
  # In case someone specifies JWT_SECRET but it's not a distributed setup
  chmod 777 /var/lib/grandine/ee-secret
fi
if [[ -O "/var/lib/grandine/ee-secret/jwtsecret" ]]; then
  chmod 666 /var/lib/grandine/ee-secret/jwtsecret
fi

if [[ ! -f /var/lib/grandine/wallet-password.txt ]]; then
  echo "Creating password for Grandine key wallet"
  head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1 > /var/lib/grandine/wallet-password.txt
fi

if [[ "${NETWORK}" =~ ^https?:// ]]; then
  echo "Custom testnet at ${NETWORK}"
  repo=$(awk -F'/tree/' '{print $1}' <<< "${NETWORK}")
  branch=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f1)
  config_dir=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f2-)
  echo "This appears to be the ${repo} repo, branch ${branch} and config directory ${config_dir}."
  # For want of something more amazing, let's just fail if git fails to pull this
  set -e
  if [ ! -d "/var/lib/grandine/testnet/${config_dir}" ]; then
    mkdir -p /var/lib/grandine/testnet
    cd /var/lib/grandine/testnet
    git init --initial-branch="${branch}"
    git remote add origin "${repo}"
    git config core.sparseCheckout true
    echo "${config_dir}" > .git/info/sparse-checkout
    git pull origin "${branch}"
  fi
  bootnodes="$(awk -F'- ' '!/^#/ && NF>1 {print $2}' "/var/lib/grandine/testnet/${config_dir}/bootstrap_nodes.yaml" | paste -sd ",")"
  set +e
  __network="--configuration-directory=/var/lib/grandine/testnet/${config_dir} --boot-nodes=${bootnodes}"
else
  __network="--network=${NETWORK}"
fi

if [ "${ARCHIVE_NODE}" = "true" ]; then
  echo "Grandine archive node without pruning"
  __prune="--back-sync"
elif [ "${CL_MINIMAL_NODE}" = "true" ]; then
  __prune="--prune-storage"
else
  __prune=""
fi

# Check whether we should rapid sync
if [ -n "${CHECKPOINT_SYNC_URL}" ]; then
  __checkpoint_sync="--checkpoint-sync-url=${CHECKPOINT_SYNC_URL}"
  echo "Checkpoint sync enabled"
else
  __checkpoint_sync=""
fi

# Check whether we should send stats to beaconcha.in
if [ -n "${BEACON_STATS_API}" ]; then
  __beacon_stats="--remote-metrics-url https://beaconcha.in/api/v1/client/metrics?apikey=${BEACON_STATS_API}&machine=${BEACON_STATS_MACHINE}"
  echo "Beacon stats API enabled"
else
  __beacon_stats=""
fi

# Check whether we should use MEV Boost
if [ "${MEV_BOOST}" = "true" ]; then
  __mev_boost="--builder-url ${MEV_NODE:-http://mev-boost:18550}"
  echo "MEV Boost enabled"
else
  __mev_boost=""
fi

if [ "${IPV6}" = "true" ]; then
  echo "Configuring Grandine to listen on IPv6 ports"
  __ipv6="--listen-address-ipv6 :: --libp2p-port-ipv6 ${CL_P2P_PORT:-9000} --discovery-port-ipv6 ${CL_P2P_PORT:-9000} \
--quic-port-ipv6 ${CL_QUIC_PORT:-9001}"
# ENR discovery on v6 is not yet working, likely too few peers. Manual for now
  __ipv6_pattern="^[0-9A-Fa-f]{1,4}:" # Sufficient to check the start
  set +e
  __public_v6=$(curl -s -6 ifconfig.me)
  set -e
  if [[ "$__public_v6" =~ $__ipv6_pattern ]]; then
    __ipv6+=" --enr-address-ipv6 ${__public_v6} --enr-tcp-port-ipv6 ${CL_P2P_PORT:-9000} --enr-udp-port-ipv6 ${CL_P2P_PORT:-9000}"
  fi
else
  __ipv6=""
fi

# Check whether we should enable doppelganger protection
if [[ "${EMBEDDED_VC}" = "true" && "${DOPPELGANGER}" = "true" ]]; then
  __doppel="--detect-doppelgangers"
  echo "Doppelganger protection enabled"
else
  __doppel=""
fi


# Web3signer URL
if [[ "${EMBEDDED_VC}" = "true" && "${WEB3SIGNER}" = "true" ]]; then
  __w3s_url="--web3signer-urls ${W3S_NODE}"
  while true; do
    if curl -s -m 5 "${W3S_NODE}" &> /dev/null; then
        echo "web3signer is up, starting Grandine"
        break
    else
        echo "Waiting for web3signer to be reachable..."
        sleep 5
    fi
  done
else
  __w3s_url=""
fi

if [ "${DEFAULT_GRAFFITI}" = "true" ]; then
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" ${__network} ${__w3s_url} ${__mev_boost} ${__checkpoint_sync} ${__prune} ${__beacon_stats} ${__ipv6} ${__doppel} ${CL_EXTRAS} ${VC_EXTRAS}
else
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" ${__network} ${__w3s_url} ${__mev_boost} ${__checkpoint_sync} ${__prune} ${__beacon_stats} ${__ipv6} ${__doppel} --graffiti "${GRAFFITI}" ${CL_EXTRAS} ${VC_EXTRAS}
fi
