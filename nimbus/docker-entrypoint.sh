#!/usr/bin/env bash
set -Eeuo pipefail

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


__download_erc_files() {
# Copyright (c) 2025 Status Research & Development GmbH and 2026 Eth Docker maintainers.
# Licensed under either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# Usage: __download_erc_files <download_url> <download_path>

  local download_url
  local download_dir
  local base_url
  local completed
  local percent
  local total_files
  local aria_pid

  if [[ $# -ne 2 ]]; then
    echo "__download_erc_files called without <download_url> <download_path>. This is a bug."
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

  curl -fsS "${base_url}/" | sed -n 's/.*href="\([^"]*\.\(era\|erc\)\)".*/\1/p' > erc_files.txt
  total_files=$(wc -l < erc_files.txt)
  sed -i "s|^|${base_url}/|" erc_files.txt
  aria2c -x 8 -j 5 -c -i erc_files.txt \
    --dir="." \
    --console-log-level=warn \
    --quiet=true \
    --summary-interval=0 \
    --continue=true \
    > /dev/null 2>&1 &

  aria_pid=$!

  echo "Downloading EraC history files"
  echo "📥 Starting download of ${total_files} files..."
  while kill -0 "${aria_pid}" 2> /dev/null; do
    completed=$(find . -type f \( -name '*.era' -o -name '*.erc' \) | wc -l)
    percent=$(awk "BEGIN { printf \"%.1f\", (${completed}/${total_files})*100 }")
    echo "📦 Download Progress: ${percent}% complete (${completed} / ${total_files} files)"
    sleep 10
  done

  wait "${aria_pid}" && exitstatus=0 || exitstatus=$?
  if [[ "${exitstatus}" -ne 0 ]]; then
    echo "EraC download failed with exit code ${exitstatus}"
    exit "${exitstatus}"
  fi

  completed=$(find . -type f \( -name '*.era' -o -name '*.erc' \) | wc -l)
  echo "📦 Download Progress: 100% complete (${completed} / ${total_files} files)"

  echo "✅ All files downloaded to: ${download_dir}"

  rm -f erc_files.txt

  echo "Verifying checksums"
  if curl -fsS -O "${base_url}/checksums_sha256.txt" 2>/dev/null; then
    sha256sum -c checksums_sha256.txt --ignore-missing
    echo "✅ All checksums verified"
  else
    echo "No checksums file available, skipping verification"
  fi

  popd > /dev/null
}


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
  if [[ ! -d "/var/lib/nimbus/testnet/${config_dir}" ]]; then
    mkdir -p /var/lib/nimbus/testnet
    cd /var/lib/nimbus/testnet
    git init --initial-branch="${branch}"
    git remote add origin "${repo}"
    git config core.sparseCheckout true
    echo "${config_dir}" > .git/info/sparse-checkout
    git pull origin "${branch}"
  fi
  bootnodes="$(awk -F'- ' '!/^#/ && NF>1 { split($2, a, /[ \t#]/); if (a[1] != "") printf (first++ ? "," : "") a[1] } END { print "" }' "/var/lib/nimbus/testnet/${config_dir}/bootstrap_nodes.yaml")"
  __network="--network=/var/lib/nimbus/testnet/${config_dir} --bootstrap-node=${bootnodes}"
else
  __network="--network=${NETWORK}"
fi

if [[ -n "${CHECKPOINT_SYNC_URL}" && ! -f /var/lib/nimbus/setupdone ]]; then
  if [[ "${CL_NODE_TYPE}" =~ ^(archive|blob-archive)$ ]]; then
    if [[ -z "${ERC_URL}" ]]; then
      echo "Nimbus cannot build an archive node from only a checkpoint sync. Attempting to sync from genesis"
      echo "It'd be much better to also use \"ERC_URL\" to download EraC files"
    else
      echo "Starting Checkpoint sync. EraC files will be downloaded next."
# shellcheck disable=SC2086
      nimbus_beacon_node trustedNodeSync --backfill=false ${__network} --data-dir=/var/lib/nimbus --trusted-node-url="${CHECKPOINT_SYNC_URL}"
    fi
    touch /var/lib/nimbus/setupdone
  else
    echo "Starting checkpoint sync. Nimbus will restart when done."
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
    nimbus_beacon_node trustedNodeSync --backfill=false ${__network} --data-dir=/var/lib/nimbus --trusted-node-url="${CHECKPOINT_SYNC_URL}"
    touch /var/lib/nimbus/setupdone
  fi
fi

__erc_dir=""
if [[ -n "${ERC_URL}" && ! "${NETWORK}" =~ ^https?:// ]]; then  # Named network
  if [[ "${CL_NODE_TYPE}" =~ ^(archive|blob-archive)$ ]]; then
    if [[ ! -f /var/lib/nimbus/erc-download-complete ]]; then
       if [[ -n "${CHECKPOINT_SYNC_URL}" ]]; then
        echo "Starting EraC history file download from ${ERC_URL}"
        __download_erc_files "${ERC_URL}" /var/lib/nimbus/erc
        touch /var/lib/nimbus/erc-download-complete
      else
        echo "You have EraC files with \"ERC_URL\" but are also genesis syncing. Skipping EraC download."
        echo "You can specify a \"CHECKPOINT_SYNC_URL\" and resync."
      fi
    fi
    if [[ -f /var/lib/nimbus/erc-download-complete ]]; then
      __erc_dir="--era-dir=/var/lib/nimbus/erc"
    fi
  else
    echo "Nimbus is not an archive node, it uses ${CL_NODE_TYPE}. Skipping EraC download."
  fi
fi

# Check whether we should use MEV Boost
if [[ "${MEV_BOOST}" = "true" ]]; then
  __mev_boost="--payload-builder=true --payload-builder-url=${MEV_NODE:-http://mev-boost:18550}"
  __mev_factor=""
  echo "MEV Boost enabled"
  if [[ "${EMBEDDED_VC}" = "true" ]]; then
    build_factor="$(__normalize_int "${MEV_BUILD_FACTOR}")"
    case "${build_factor}" in
      0)
        __mev_boost=""
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
        echo "Use default --local-block-value-boost"
        ;;
      *)
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

case "${CL_NODE_TYPE}" in
  archive|blob-archive)
    echo "Nimbus archive node without history or blob pruning."
    __prune="--history=archive --reindex"
    ;;
  full)
    __prune=""
    ;;
  pruned)
    echo "Nimbus pruned node"
    __prune="--history=prune"
    ;;
  *)
    echo "ERROR: The node type ${CL_NODE_TYPE} is not known to Eth Docker's Nimbus implementation."
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

i=0
while true; do
  if [ -f /var/lib/nimbus/ee-secret/jwtsecret ]; then
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

if [[ "${DEFAULT_GRAFFITI}" = "true" ]]; then
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" ${__network} ${__w3s_url} ${__mev_boost} ${__mev_factor} ${__doppel} ${__prune} ${__erc_dir} ${CL_EXTRAS} ${VC_EXTRAS}
else
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" ${__network} ${__w3s_url} "--graffiti=${GRAFFITI}" ${__mev_boost} ${__mev_factor} ${__doppel} ${__prune} ${__erc_dir} ${CL_EXTRAS} ${VC_EXTRAS}
fi
