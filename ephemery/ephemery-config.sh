#!/usr/bin/env bash
# Fetches the network config of the current Ephemery iteration and prints the directory holding
# config.yaml, genesis.ssz, genesis.json, bootstrap_nodes.txt, enodes.txt and deposit_contract_block.txt.
# Prysm and Geth have no built-in Ephemery. The genesis repo does not keep these files in git, they come
# as a release per iteration, so the git-based custom network path cannot fetch them.
# Each iteration's retention.vars has its genesis time and reset interval. An iteration fetched before
# is used as long as it is live, without asking GitHub. Once it has ended, this looks up the latest
# release, and waits for one that is live if there is none yet: a node on an ended iteration is useless.
# Call with the directory to keep iterations in. Messages go to stderr, the path to stdout.
# Client images get it from the "ephemery" additional build context, see geth.yml and prysm.yml.
set -Eeuo pipefail

base_dir="$1"
repo=https://github.com/ephemery-testnet/ephemery-genesis
retry_secs=60

# Numeric value of a variable in retention.vars. Parsed, not sourced, as it comes from a download.
read_var() {
  sed -n "s/^\(export \)\{0,1\}$2=\"\{0,1\}\([0-9]*\)\"\{0,1\}[[:space:]]*$/\2/p" "$1" 2>/dev/null | head -n 1
}

# Prints live, future or finished. An iteration without readable retention.vars counts as finished.
iteration_state() {
  local genesis interval now
  genesis="$(read_var "${base_dir}/$1/retention.vars" GENESIS_TIMESTAMP)"
  interval="$(read_var "${base_dir}/$1/retention.vars" GENESIS_RESET_INTERVAL)"
  now="$(date +%s)"
  if [[ -z "${genesis}" || -z "${interval}" ]]; then
    echo finished
  elif (( now < genesis )); then
    echo future
  elif (( now < genesis + interval )); then
    echo live
  else
    echo finished
  fi
}

iteration_end() {
  local genesis interval
  genesis="$(read_var "${base_dir}/$1/retention.vars" GENESIS_TIMESTAMP)"
  interval="$(read_var "${base_dir}/$1/retention.vars" GENESIS_RESET_INTERVAL)"
  if [[ -n "${genesis}" && -n "${interval}" ]]; then
    date -u -d "@$(( genesis + interval ))" '+%Y-%m-%d %H:%M UTC'
  else
    echo "an unknown time"
  fi
}

# Iterations fetched before, newest first
cached_tags() {
  for d in "${base_dir}"/*/; do
    [[ -f "${d}metadata/config.yaml" ]] && basename "${d}"
  done 2>/dev/null | sort -rV || true
}

# The "latest" release redirects to its tag, which names the iteration
latest_tag() {
  curl -sfI -m 30 "${repo}/releases/latest" | tr -d '\r' \
    | sed -n 's|^[Ll]ocation: .*/releases/tag/\(.*\)$|\1|p' || true
}

fetch_release() {
  local tag="$1"
  [[ -f "${base_dir}/${tag}/metadata/config.yaml" ]] && return 0
  echo "Fetching the Ephemery network config for ${tag}" >&2
  mkdir -p "${base_dir}/${tag}.tmp"
  if ! curl -sfL -m 120 "${repo}/releases/download/${tag}/network-config.tar.gz" \
      | tar xz -C "${base_dir}/${tag}.tmp"; then
    rm -rf "${base_dir:?}/${tag}.tmp"
    echo "Could not download the Ephemery network config for ${tag}." >&2
    return 1
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
}

tag=""
for t in $(cached_tags); do
  if [[ "$(iteration_state "${t}")" = "live" ]]; then
    tag="${t}"
    break
  fi
done

if [[ -z "${tag}" ]]; then
  newest_cached="$(cached_tags | head -n 1)"
  if [[ -n "${newest_cached}" ]]; then
    echo "Ephemery iteration ${newest_cached} ended at $(iteration_end "${newest_cached}"), looking up the next one" >&2
  fi
  while :; do
    latest="$(latest_tag)"
    if [[ -z "${latest}" ]]; then
      echo "Could not look up the current Ephemery release at ${repo}, retrying in ${retry_secs}s" >&2
    elif fetch_release "${latest}"; then
      state="$(iteration_state "${latest}")"
      if [[ "${state}" = "live" ]]; then
        tag="${latest}"
        break
      elif [[ "${state}" = "future" ]]; then
        echo "Ephemery iteration ${latest} has not started yet, retrying in ${retry_secs}s" >&2
      else
        echo "The latest Ephemery release ${latest} ended at $(iteration_end "${latest}"), waiting for the next one. Retrying in ${retry_secs}s" >&2
      fi
    else
      echo "Retrying in ${retry_secs}s" >&2
    fi
    sleep "${retry_secs}"
  done
fi

# Iterations other than the live one are for chains that are gone
for t in $(cached_tags); do
  if [[ ! "${t}" = "${tag}" && ! "$(iteration_state "${t}")" = "future" ]]; then
    rm -rf "${base_dir:?}/${t}"
  fi
done

echo "Ephemery iteration ${tag}, live until $(iteration_end "${tag}")" >&2
echo "${base_dir}/${tag}/metadata"
