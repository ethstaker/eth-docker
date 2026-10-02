#!/usr/bin/env bash
# Fetches the network config of the current Ephemery iteration and prints the directory holding
# config.yaml, genesis.ssz, genesis.json, bootstrap_nodes.txt, enodes.txt and deposit_contract_block.txt.
# Prysm, Geth and Nimbus have no built-in Ephemery. The genesis repo does not keep these files in git,
# they come as a release per iteration, so the git-based custom network path cannot fetch them.
# Call with the directory to keep iterations in. Messages go to stderr, the path to stdout.
# Identical copy in prysm/, geth/, nimbus/ and nimbus-el/, as each client builds from its own directory;
# keep them in sync.
set -Eeuo pipefail

base_dir="$1"
repo=https://github.com/ephemery-testnet/ephemery-genesis

# The "latest" release redirects to its tag, which names the iteration
tag="$(curl -sfI -m 30 "${repo}/releases/latest" | tr -d '\r' \
  | sed -n 's|^[Ll]ocation: .*/releases/tag/\(.*\)$|\1|p' || true)"

if [[ -z "${tag}" ]]; then
  # Keep a node running through a GitHub outage, on the iteration it already has
  tag="$(for d in "${base_dir}"/*/; do [[ -f "${d}metadata/config.yaml" ]] && basename "${d}"; done 2>/dev/null \
    | sort -V | tail -n 1 || true)"
  if [[ -z "${tag}" ]]; then
    echo "Could not look up the current Ephemery release at ${repo}, and none was fetched before." >&2
    exit 1
  fi
  echo "Could not look up the current Ephemery release, using the one fetched before: ${tag}" >&2
fi

if [[ ! -f "${base_dir}/${tag}/metadata/config.yaml" ]]; then
  echo "Fetching the Ephemery network config for ${tag}" >&2
  mkdir -p "${base_dir}/${tag}.tmp"
  if ! curl -sfL -m 120 "${repo}/releases/download/${tag}/network-config.tar.gz" \
      | tar xz -C "${base_dir}/${tag}.tmp"; then
    rm -rf "${base_dir:?}/${tag}.tmp"
    echo "Could not download the Ephemery network config for ${tag}." >&2
    exit 1
  fi
  # Ephemery's config stops at Fulu. Prysm then takes the Gloas fork version from mainnet, and
  # refuses to start because it clashes with its built-in mainnet config. Give Gloas a version
  # of Ephemery's own, never activated.
  if ! grep -q '^GLOAS_FORK_VERSION:' "${base_dir}/${tag}.tmp/metadata/config.yaml"; then
    printf '\n# Added by eth-docker: Gloas is not scheduled on Ephemery\nGLOAS_FORK_VERSION: 0x8000101b\nGLOAS_FORK_EPOCH: 18446744073709551615\n' \
      >> "${base_dir}/${tag}.tmp/metadata/config.yaml"
  fi
  rm -rf "${base_dir:?}/${tag}"
  mv "${base_dir}/${tag}.tmp" "${base_dir}/${tag}"
fi

echo "Ephemery iteration ${tag}" >&2
echo "${base_dir}/${tag}/metadata"
