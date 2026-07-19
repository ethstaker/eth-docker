#!/usr/bin/env bash
set -Eeuo pipefail

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


__download_ere_files() {
# Copyright (c) 2025 Status Research & Development GmbH and 2026 Eth Docker maintainers.
# Licensed under either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# Usage: __download_ere_files <download_url> <download_path>

  local download_url
  local download_dir
  local base_url
  local completed
  local percent
  local total_files
  local aria_pid

  if [[ $# -ne 2 ]]; then
    echo "__download_ere_files called without <download_url> <download_path>. This is a bug."
    exit 70
  fi

  download_url="$1"
  download_dir="$2"

  mkdir -p "${download_dir}"
  pushd "${download_dir}" > /dev/null || { echo "Could not change directory to ${download_dir}. This is a bug."; exit 70; }

  # 🔧 Normalize base URL (handle trailing slash)
  case "${download_url}" in
    */)           base_url="${download_url%/}" ;;
    *)            base_url="${download_url}" ;;
  esac

  curl -fsS -O "${base_url}/urls.txt"
  total_files=$(wc -l < urls.txt)
  aria2c -x 8 -j 5 -c -i urls.txt \
    --dir="." \
    --console-log-level=warn \
    --quiet=true \
    --summary-interval=0 \
    --continue=true \
    > /dev/null 2>&1 &

  aria_pid=$!

  echo "Downloading EraE history files"
  echo "📥 Starting download of ${total_files} files..."
  while kill -0 "${aria_pid}" 2> /dev/null; do
    completed=$(find . -type f \( -name '*.erae' -o -name '*.ere' \) | wc -l)
    percent=$(awk "BEGIN { printf \"%.1f\", (${completed}/${total_files})*100 }")
    echo "📦 Download Progress: ${percent}% complete (${completed} / ${total_files} files)"
    sleep 10
  done

  wait "${aria_pid}" && exitstatus=0 || exitstatus=$?
  if [[ "${exitstatus}" -ne 0 ]]; then
    echo "EraE download failed with exit code ${exitstatus}"
    exit "${exitstatus}"
  fi

  completed=$(find . -type f \( -name '*.erae' -o -name '*.ere' \) | wc -l)
  echo "📦 Download Progress: 100% complete (${completed} / ${total_files} files)"

  echo "✅ All files downloaded to: ${download_dir}"

  echo "Verifying checksums"
  curl -fsS -O "${base_url}/checksums_sha256.txt"
  sha256sum -c checksums_sha256.txt --ignore-missing
  echo "✅ All checksums verified"

  popd > /dev/null
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
  rolling-expiry)
    echo "Nimbus EL minimal node with 33,024 epochs rolling expiry - ~5 months"
    __prune="--prune"
    ;;
  use-cl-zkproofs)
    echo "ERROR: The node type ${NODE_TYPE} is designed to not run an execution layer client"
    echo "Remove \"nimbus-el.yml\" from configuration, or change the node type"
    sleep 30
    exit 1
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
  if [[ ! -d "/var/lib/nimbus/testnet/${config_dir}" ]]; then
    mkdir -p /var/lib/nimbus/testnet
    cd /var/lib/nimbus/testnet
    git init --initial-branch="${branch}"
    git remote add origin "${repo}"
    git config core.sparseCheckout true
    echo "${config_dir}" > .git/info/sparse-checkout
    git pull origin "${branch}"
  fi
  config_dir_path="/var/lib/nimbus/testnet/${config_dir}"
  if [[ -f "${config_dir_path}/enodes.yaml" ]]; then
    bootnodes="$(awk -F'- ' '!/^#/ && NF>1 { split($2, a, /[ \t#]/); if (a[1] != "") printf (first++ ? "," : "") a[1] } END { print "" }' "${config_dir_path}/enodes.yaml")"
  else
    bootnodes="$(paste -sd, "${config_dir_path}/enodes.txt")"
  fi
  __network="--bootstrap-node=${bootnodes} --network=${config_dir_path}/genesis.json"
else
  __network="--network=${NETWORK}"
fi

# EraE import
if [[ -n "${ERE_URL}" && ! -f /var/lib/nimbus/ere-import-complete && ! "${NETWORK}" =~ ^https?:// ]]; then  # Fresh sync and named network
  if [[ "${NODE_TYPE}" =~ ^(full|archive)$ ]]; then
    echo "Starting EraE history import from ${ERE_URL}"
    if [[ ! -f /var/lib/nimbus/ere-download-complete ]]; then
      __download_ere_files "${ERE_URL}" /var/lib/nimbus/ere
      touch /var/lib/nimbus/ere-download-complete
    fi
    # Rename legacy erae files. This can be removed once pandaops publishes .ere
    find /var/lib/nimbus/ere -type f -name '*.erae' -exec sh -c '
      for f; do
        mv -- "$f" "${f%.erae}-noproofs.ere"
      done
    ' sh {} +
    # shellcheck disable=SC2086
    nimbus import --network=${NETWORK} --data-dir=/var/lib/nimbus --ere-dir=/var/lib/nimbus/ere
    touch /var/lib/nimbus/ere-import-complete
    rm -rf /var/lib/nimbus/ere
  else
    echo "Nimbus is neither a full nor archive node, it uses ${NODE_TYPE}. Skipping EraE import."
  fi
fi

__strip_empty_args "$@"
set -- "${__args[@]}"

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${__prune} ${__network} ${EL_EXTRAS}
