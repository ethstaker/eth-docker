#!/bin/bash
set -Eeuo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R besu:besu /var/lib/besu
  exec gosu besu "${BASH_SOURCE[0]}" "$@"
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
  echo -n "${JWT_SECRET}" > /var/lib/besu/ee-secret/jwtsecret
  echo "JWT secret was supplied in .env"
fi

if [[ ! -f /var/lib/besu/ee-secret/jwtsecret ]]; then
  echo "Generating JWT secret"
  secret1=$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)
  secret2=$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)
  echo -n "${secret1}""${secret2}" > /var/lib/besu/ee-secret/jwtsecret
fi

if [[ -O /var/lib/besu/ee-secret ]]; then
  # In case someone specifies JWT_SECRET but it's not a distributed setup
  chmod 777 /var/lib/besu/ee-secret
fi
if [[ -O /var/lib/besu/ee-secret/jwtsecret ]]; then
  chmod 666 /var/lib/besu/ee-secret/jwtsecret
fi

if [[ "${NETWORK}" =~ ^https?:// ]]; then
  echo "Custom testnet at ${NETWORK}"
  repo=$(awk -F'/tree/' '{print $1}' <<< "${NETWORK}")
  branch=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f1)
  config_dir=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f2-)
  echo "This appears to be the ${repo} repo, branch ${branch} and config directory ${config_dir}."
  if [[ ! -d "/var/lib/besu/testnet/${config_dir}" ]]; then
    mkdir -p /var/lib/besu/testnet
    cd /var/lib/besu/testnet
    git init --initial-branch="${branch}"
    git remote add origin "${repo}"
    git config core.sparseCheckout true
    echo "${config_dir}" > .git/info/sparse-checkout
    git pull origin "${branch}"
  fi
  config_dir_path="/var/lib/besu/testnet/${config_dir}"
  if [[ -f "${config_dir_path}/enodes.txt" ]]; then
    bootnodes="$(paste -sd, "${config_dir_path}/enodes.txt")"
  else
    bootnodes="$(awk -F'- ' '!/^#/ && NF>1 { split($2, a, /[ \t#]/); if (a[1] != "") printf (first++ ? "," : "") a[1] } END { print "" }' "${config_dir_path}/enodes.yaml")"
  fi
  if [[ -f "${config_dir_path}/bootstrap_nodes.txt" ]]; then
    v5_bootnodes="$(paste -sd, "${config_dir_path}/bootstrap_nodes.txt")"
  else
    v5_bootnodes="$(awk -F'- ' '!/^#/ && NF>1 { split($2, a, /[ \t#]/); if (a[1] != "") printf (first++ ? "," : "") a[1] } END { print "" }' "${config_dir_path}/bootstrap_nodes.yaml")"
  fi
  if [[ -n "${bootnodes}" && -n "${v5_bootnodes}" ]]; then
    bootnodes+=",${v5_bootnodes}"
  elif [[ -n "${v5_bootnodes}" ]]; then
    bootnodes="${v5_bootnodes}"
  fi
  __network="--genesis-file=${config_dir_path}/besu.json --bootnodes=${bootnodes} --bonsai-limit-trie-logs-enabled=false"
else
  __network="--network ${NETWORK}"
fi

case "${NODE_TYPE}" in
  archive)
    echo "Besu archive node without pruning"
    __prune="--data-storage-format=FOREST --sync-mode=FULL --snapsync-server-enabled"
    ;;
  full)
    echo "Besu full node without history expiry. Requires \"full\" sync and will take a long time to sync"
    __prune="--sync-mode=FULL --bonsai-limit-trie-logs-enabled=false --snapsync-server-enabled"
    if [[ -n "${ERE_URL}" ]]; then
      echo "Attempting to load Era1 files from ${ERE_URL}. Note Besu does not support EraE yet!"
      __prune+=" --era1-import-prepipeline-enabled=true --era1-data-uri=${ERE_URL}"
    else
      echo "Consider setting \"ERE_URL\" to an Era1 (!) URL in \".env\" to speed up sync."
    fi
    ;;
  pre-merge-expiry)
    case "${NETWORK}" in
      mainnet|sepolia)
        echo "Besu minimal node with pre-merge history expiry"
        __prune="--snapsync-server-enabled"
        ;;
      *)
        echo "There is no pre-merge history for ${NETWORK} network, \"pre-merge-expiry\" has no effect."
        __prune=""
        ;;
    esac
    ;;
  rolling-expiry)
    echo "Besu minimal node with rolling history expiry, keeps ~5 months"
    # 33_024 epochs = 1056768 slots / blocks
    __prune="--snapsync-server-enabled --Xchain-pruning-enabled=ALL --Xchain-pruning-blocks-retained=1056768"
    ;;
  aggressive-expiry)
    echo "Besu minimal node with aggressive expiry"
    __prune="--snapsync-server-enabled --Xchain-pruning-enabled=ALL --Xchain-pruning-blocks-retained=113056"
    ;;
  custom)
    echo "Besu default block retention; adjust as desired by \"EL_EXTRAS\" in \".env\""
    __prune=""
    ;;
  use-cl-zkproofs)
    echo "ERROR: The node type ${NODE_TYPE} is designed to not run an execution layer client"
    echo "Remove \"besu.yml\" from configuration, or change the node type"
    sleep 30
    exit 1
    ;;
  *)
    echo "ERROR: The node type ${NODE_TYPE} is not known to Eth Docker's Besu implementation."
    sleep 30
    exit 1
    ;;
esac

# New or old datadir
if [[ -d /var/lib/besu-og/database ]]; then
  __datadir="--data-path /var/lib/besu-og"
else
  __datadir="--data-path /var/lib/besu"
fi

# DiscV5 for IPV6
if [[ "${IPV6}" = "true" ]]; then
  echo "Configuring Besu for IPv6"
  __ipv6="--p2p-interface-ipv6=:: --p2p-port-ipv6=${EL_P2P_PORT} --p2p-ipv6-outbound-enabled"
# Address discovery on v6 is not implemented
  ipv6_pattern="^[0-9A-Fa-f]{1,4}:" # Sufficient to check the start
  set +e
  public_v6=$(curl -s -m2 -6 https://ifconfig.me)
  set -e
  if [[ "${public_v6}" =~ ${ipv6_pattern} ]]; then
    __ipv6+=" --p2p-host-ipv6=${public_v6}"
  fi
else
  __ipv6=""
fi

__strip_empty_args "$@"
set -- "${__args[@]}"

# Traces
if [[ "${COMPOSE_FILE}" =~ (grafana\.yml|grafana-rootless\.yml) ]]; then
  __trace="--metrics-protocol=opentelemetry"
  export OTEL_METRICS_EXPORTER=none
  export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
  export OTEL_EXPORTER_OTLP_ENDPOINT=http://tempo:4317
  export OTEL_EXPORTER_OTLP_INSECURE=true
  export OTEL_SERVICE_NAME=besu
else
  __trace=""
fi

if [[ -f /var/lib/besu/prune-marker ]]; then
  rm -f /var/lib/besu/prune-marker
  if [[ "${NODE_TYPE}" = "archive" ]]; then
    echo "Besu is an archive node. Not attempting to prune trie-logs: Aborting."
    exit 1
  fi
  echo "Pruning Besu trie-logs"
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec /opt/besu/bin/besu ${__datadir} ${__network} storage trie-log prune
else
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" ${__datadir} ${__network} ${__ipv6} ${__prune} ${__trace} ${EL_EXTRAS}
fi
