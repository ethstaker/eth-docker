#!/bin/bash
set -Eeuo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R besu:besu /var/lib/besu
  exec gosu besu "${BASH_SOURCE[0]}" "$@"
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
  echo -n "${JWT_SECRET}" > /var/lib/besu/ee-secret/jwtsecret
  echo "JWT secret was supplied in .env"
fi

if [[ ! -f /var/lib/besu/ee-secret/jwtsecret ]]; then
  echo "Generating JWT secret"
  __secret1=$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)
  __secret2=$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)
  echo -n "${__secret1}""${__secret2}" > /var/lib/besu/ee-secret/jwtsecret
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
  # For want of something more amazing, let's just fail if git fails to pull this
  set -e
  if [[ ! -d "/var/lib/besu/testnet/${config_dir}" ]]; then
    mkdir -p /var/lib/besu/testnet
    cd /var/lib/besu/testnet
    git init --initial-branch="${branch}"
    git remote add origin "${repo}"
    git config core.sparseCheckout true
    echo "${config_dir}" > .git/info/sparse-checkout
    git pull origin "${branch}"
  fi
  bootnodes="$(awk -F'- ' '!/^#/ && NF>1 {print $2}' "/var/lib/besu/testnet/${config_dir}/enodes.yaml" | paste -sd ",")"
  set +e
  __network="--genesis-file=/var/lib/besu/testnet/${config_dir}/besu.json --bootnodes=${bootnodes}"
else
  __network="--network ${NETWORK}"
fi

if [[ "${ARCHIVE_NODE}" = "true" ]]; then
  echo "Besu archive node without pruning"
  __prune="--data-storage-format=FOREST --sync-mode=FULL"
elif [[ "${MINIMAL_NODE}" = "true" ]]; then
  case "${NETWORK}" in
    mainnet | sepolia )
      echo "Besu minimal node with pre-merge history expiry"
      __prune="--snapsync-server-enabled"
      __timestamp_file="/var/lib/besu/prune-history-timestamp.txt"
      if [[ -f "${__timestamp_file}" ]]; then
        __saved_ts=$(<"${__timestamp_file}")
        __current_ts=$(date +%s)
        __diff=$((__current_ts - __saved_ts))

        if (( __diff >= 172800 )); then  # 48 * 60 * 60 - 48 hours have passed
          rm -f "${__timestamp_file}"
        else
          echo "Enabling RocksDB garbage collection after history prune. You should see Besu DB space usage go down."
          echo "This may take 6-12 hours. Eth Docker will keep RocksDB garbage collection on for 48 hours."
          __prune+=" --history-expiry-prune"
        fi
      fi
      ;;
    * )
      echo "There is no pre-merge history for ${NETWORK} network, EL_MINIMAL_NODE has no effect."
      __prune=""
      ;;
  esac
else
  echo "Besu full node without history expiry"
  __prune="--snapsync-synchronizer-pre-checkpoint-headers-only-enabled=false --snapsync-server-enabled"
fi

# New or old datadir
if [[ -d /var/lib/besu-og/database ]]; then
  __datadir="--data-path /var/lib/besu-og"
else
  __datadir="--data-path /var/lib/besu"
fi

# DiscV5 for IPV6
if [[ "${IPV6:-false}" = "true" ]]; then
  echo "Configuring Besu for discv5 for IPv6 advertisements"
  __ipv6="--Xv5-discovery-enabled"
else
  __ipv6=""
fi

__strip_empty_args "$@"
set -- "${__args[@]}"

if [[ -f /var/lib/besu/prune-history-marker ]]; then
  rm -f /var/lib/besu/prune-history-marker
  if [[ "${ARCHIVE_NODE}" = "true" ]]; then
    echo "Besu is an archive node. Not attempting to prune history: Aborting."
    exit 1
  fi
  date +%s > /var/lib/besu/prune-history-timestamp.txt  # Going to leave RocksDB GC on for 48 hours
  echo "Pruning Besu pre-merge history"
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec /opt/besu/bin/besu ${__datadir} ${__network} storage prune-pre-merge-blocks
elif [[ -f /var/lib/besu/prune-marker ]]; then
  rm -f /var/lib/besu/prune-marker
  if [[ "${ARCHIVE_NODE}" = "true" ]]; then
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
  exec "$@" ${__datadir} ${__network} ${__ipv6} ${__prune} ${EL_EXTRAS}
fi
