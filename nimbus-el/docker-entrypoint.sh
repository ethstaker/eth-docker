#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R user:user /var/lib/nimbus
  exec gosu user docker-entrypoint.sh "$@"
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


__download_era_files() {
# Copyright (c) 2025 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# Usage: __download_era_files <download_url> <download_path>

  local download_url
  local download_dir
  local base_url
  local urls_raw_file
  local urls_file
  local completed
  local percent
  local total_files
  local aria_pid

  if [[ $# -ne 2 ]]; then
    echo "__download_era_files called without <download_url> <download_path>. This is a bug."
    exit 70
  fi

  download_url="$1"
  download_dir="$2"

  mkdir -p "${download_dir}"
  cd "${download_dir}" || { echo "Could not change directory to ${download_dir}. This is a bug."; exit 70; }

  # Generate safe temp files for URL lists
  urls_raw_file=$(mktemp)
  urls_file=$(mktemp)

  # Scrape and filter
  curl -s "${download_url}" | \
  grep -Eo 'href="[^"]+"' | \
  cut -d'"' -f2 | \
  grep -Ei '\.(era|era1|txt)$' | \
  sort -u > "${urls_raw_file}"

  # Remove trailing file (like index.html) to get actual base path
  base_url=$(echo "${download_url}" | sed -E 's|/[^/]*\.[a-zA-Z0-9]+$||')

  # 🔧 Normalize base URL (handle trailing slash or index.html)
  case "${download_url}" in
    */index.html) base_url="${download_url%/index.html}" ;;
    */)           base_url="${download_url%/}" ;;
    *)            base_url="${download_url}" ;;
  esac

  # Prepend full URL
  awk -v url="${base_url}" '{ print url "/" $0 }' "${urls_raw_file}" > "${urls_file}"

  total_files=$(wc -l < "${urls_file}")

  if [[ "${total_files}" -eq 0 ]]; then
    echo "❌ No .era, .era1, or .txt files found at ${download_url}"
    exit 1
  fi

  aria2c -x 8 -j 5 -c -i "${urls_file}" \
    --dir="." \
    --console-log-level=warn \
    --quiet=true \
    --summary-interval=0 \
    > /dev/null 2>&1 &

  aria_pid=$!

  echo "Downloading Era/Era1 history files"
  echo "📥 Starting download of ${total_files} files..."
  while kill -0 "${aria_pid}" 2> /dev/null; do
    completed=$(find . -type f \( -name '*.era' -o -name '*.era1' -o -name '*.txt' \) | wc -l)
    percent=$(awk "BEGIN { printf \"%.1f\", (${completed}/${total_files})*100 }")
    echo "📦 Download Progress: ${percent}% complete (${completed} / ${total_files} files)"
    sleep 10
  done

  completed=$(find . -type f \( -name '*.era' -o -name '*.era1' -o -name '*.txt' \) | wc -l)
  echo "📦 Download Progress: 100% complete (${completed} / ${total_files} files)"

  # ✅ Cleanup temp files
  rm -f "${urls_raw_file}" "${urls_file}"

  echo "✅ All files downloaded to: ${download_dir}"
}


if [[ -n "${JWT_SECRET}" ]]; then
  echo -n "${JWT_SECRET}" > /var/lib/nimbus/ee-secret/jwtsecret
  echo "JWT secret was supplied in .env"
fi

if [[ ! -f /var/lib/nimbus/ee-secret/jwtsecret ]]; then
  echo "Generating JWT secret"
  secret1=$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)
  secret2=$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)
  echo -n "${secret1}""${secret2}" > /var/lib/nimbus/ee-secret/jwtsecret
fi

if [[ -O /var/lib/nimbus/ee-secret ]]; then
  # In case someone specifies JWT_SECRET but it's not a distributed setup
  chmod 777 /var/lib/nimbus/ee-secret
fi
if [[ -O /var/lib/nimbus/ee-secret/jwtsecret ]]; then
  chmod 666 /var/lib/nimbus/ee-secret/jwtsecret
fi

case "${NODE_TYPE}" in
  archive)
    echo "Nimbus EL does not support running an archive node"
    sleep 30
    exit 1
    ;;
  full)
    echo "Nimbus EL full node without history expiry"
    __prune=""
    ;;
  pre-merge-expiry)
    case "${NETWORK}" in
      mainnet|sepolia)
        echo "Nimbus EL minimal node with pre-merge history expiry"
        __prune="--history-expiry=true"
        ;;
      *)
        echo "There is no pre-merge history for ${NETWORK} network, \"pre-merge-expiry\" has no effect."
        __prune=""
        ;;
    esac
    ;;
  *)
    echo "ERROR: The node type ${NODE_TYPE} is not known to Eth Docker's Nimbus EL implementation."
    sleep 30
    exit 1
    ;;
esac

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
  bootnodes="$(awk -F'- ' '!/^#/ && NF>1 {print $2}' "/var/lib/nimbus/testnet/${config_dir}/enodes.yaml" | paste -sd ",")"
  networkid="$(jq -r '.config.chainId' "/var/lib/nimbus/testnet/${config_dir}/genesis.json")"
  set +e
  __network="--bootstrap-node=${bootnodes} --network=${networkid} --custom-network /var/lib/nimbus/testnet/${config_dir}/genesis.json"
else
  __network="--network=${NETWORK}"
fi

# Era1 and/or Era import
if [[ ! -d /var/lib/nimbus/nimbus && ! "${NETWORK}" =~ ^https?:// ]]; then  # Fresh sync and named network
  __era=""
  if [[ -n "${ERA1_URL}" ]]; then
    __download_era_files "${ERA1_URL}" /var/lib/nimbus/era1
    __era+="--era1-dir=/var/lib/nimbus/era1 "
  fi
  if [[ -n "${ERA_URL}" ]]; then
    if [[ -z "${ERA1_URL}" && "${NETWORK}" =~ (mainnet|sepolia) ]]; then
      echo "The ${NETWORK} network has pre-merge history. You cannot import era files without era1."
      echo "Please set an ERA1_URL and try again"
      sleep 30
      exit 1
    fi
    __download_era_files "${ERA_URL}" /var/lib/nimbus/era
    __era+="--era-dir=/var/lib/nimbus/era"
  fi

  if [[ -n "${ERA1_URL}" || -n "${ERA_URL}" ]]; then
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
    nimbus_execution_client import --network=${NETWORK} --data-dir=/var/lib/nimbus ${__era}
    rm -rf /var/lib/nimbus/era
    rm -rf /var/lib/nimbus/era1
  fi
fi

__strip_empty_args "$@"
set -- "${__args[@]}"

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${__prune} ${__network} ${EL_EXTRAS}
