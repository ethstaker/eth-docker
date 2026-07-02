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
  cd "${download_dir}" || { echo "Could not change directory to ${download_dir}. This is a bug."; exit 70; }

  # 🔧 Normalize base URL (handle trailing slash)
  case "${download_url}" in
    */)           base_url="${download_url%/}" ;;
    *)            base_url="${download_url}" ;;
  esac

  curl -sS -O "${base_url}/urls.txt"
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
  curl -sS -O "${base_url}/checksums_sha256.txt"
  sha256sum -c checksums_sha256.txt --ignore-missing
  echo "✅ All checksums verified"
}


case "${EL_NODE_TYPE}" in
  archive)
    echo "Nimbus Unified does not support running an archive execution node"
    sleep 30
    exit 1
    ;;
  full)
    echo "Nimbus Unified full execution node without history expiry"
    __prune=""
    ;;
  pre-merge-expiry)
    case "${NETWORK}" in
      mainnet|sepolia)
        echo "Nimbus Unified minimal execution node with pre-merge history expiry"
        __prune="--history-expiry=true"
        ;;
      *)
        echo "There is no pre-merge history for ${NETWORK} network, \"pre-merge-expiry\" has no effect."
        __prune=""
        ;;
    esac
    ;;
  rolling-expiry)
    echo "Nimbus Unified minimal execution node with 33,024 epochs rolling expiry - ~5 months"
    __prune="--prune"
    ;;
  use-cl-zkproofs)
    echo "ERROR: The node type ${EL_NODE_TYPE} is designed to not run an execution layer client"
    echo "nimbus-unified.yml runs an EL by definition. Choose a different node type"
    sleep 30
    exit 1
    ;;
  *)
    echo "ERROR: The node type ${EL_NODE_TYPE} is not known to Eth Docker's Nimbus Unified execution implementation."
    sleep 30
    exit 1
    ;;
esac

case "${CL_NODE_TYPE}" in
  archive)
    echo "Nimbus Unified archive consensus node without history pruning"
    __prune+=" --history=archive --reindex"
    ;;
  full)
    echo "Nimbus Unified full consensus node"
    ;;
  pruned)
    echo "Nimbus Unified pruned consensus node"
    __prune+=" --history=prune"
    ;;
  *)
    echo "ERROR: The node type ${CL_NODE_TYPE} is not known to Eth Docker's Nimbus Unified consensus implementation."
    sleep 30
    exit 1
    ;;
esac

# TODO - adjust for CL and EL bootnodes and network, currently not possible bcs both use the same paraneter names
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
  __network="--bootstrap-node=${bootnodes} --network=${networkid} --network=/var/lib/nimbus/testnet/${config_dir}"
else
  __network="--network=${NETWORK}"
fi

# EraE import, before CL checkpoint sync
if [[ -n "${ERE_URL}" && ! -f /var/lib/nimbus/ere-import-complete && ! "${NETWORK}" =~ ^https?:// ]]; then  # Fresh sync and named network
  if [[ "${EL_NODE_TYPE}" =~ ^(full|archive)$ ]]; then
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
    echo "Nimbus is neither a full nor archive node, it uses ${EL_NODE_TYPE}. Skipping EraE import."
  fi
fi

if [[ -n "${CHECKPOINT_SYNC_URL}" && ! -f /var/lib/nimbus/setupdone ]]; then
  if [[ "${CL_NODE_TYPE}" = "archive" ]]; then
    echo "Starting checkpoint sync with backfill and archive reindex. Nimbus will restart when done."
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
    nimbus trustedNodeSync --backfill=true --reindex ${__network} --data-dir=/var/lib/nimbus --trusted-node-url="${CHECKPOINT_SYNC_URL}"
    touch /var/lib/nimbus/setupdone
  else
    echo "Starting checkpoint sync. Nimbus will restart when done."
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
    nimbus trustedNodeSync --backfill=false ${__network} --data-dir=/var/lib/nimbus --trusted-node-url="${CHECKPOINT_SYNC_URL}"
    touch /var/lib/nimbus/setupdone
  fi
fi

# Check whether we should use MEV Boost
if [[ "${MEV_BOOST}" = "true" ]]; then
  __mev_boost="--payload-builder=true --payload-builder-url=${MEV_NODE:-http://mev-boost:18550}"
  echo "MEV Boost enabled"
else
  __mev_boost=""
fi

__strip_empty_args "$@"
set -- "${__args[@]}"

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${__prune} ${__mev_boost} ${__network} ${EL_EXTRAS} ${CL_EXTRAS}
