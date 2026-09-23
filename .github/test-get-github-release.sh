#!/usr/bin/env bash
# Exercises __get_github_release from ethd on its own, the way "ethd keys prepare-address-change"
# uses it: download ethdo as a tarball and jq as a single binary, both for Linux, and fail cleanly
# on an asset that does not exist. It runs on the host, so this is what catches a missing tool,
# such as wget on macOS.

set -Eeuo pipefail

# The functions only, without running a command. __as_owner and __chmod_sudo default to empty.
# shellcheck source=/dev/null
ETHD_SOURCE_ONLY=1 source ./ethd

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

fail() {
  echo "FAILED: $*"
  exit 1
}

# The downloads are Linux binaries, which do not run on macOS. Check for an ELF executable instead.
check_elf() {
  local file=$1

  [[ -s "${file}" ]] || fail "${file} is missing or empty"
  [[ -x "${file}" ]] || fail "${file} is not executable"
  [[ "$(head -c 4 "${file}" | od -An -c | tr -d ' ')" = '177ELF' ]] || fail "${file} is not an ELF binary"
  echo "${file} is an ELF executable of $(wc -c < "${file}" | tr -d ' ') bytes"
}

echo "=== ethdo, tarball"
__get_github_release wealdtech/ethdo linux-amd64.tar.gz "${tmp}/amd64" __untar__
check_elf "${tmp}/amd64/ethdo"

echo "=== jq, single binary"
__get_github_release jqlang/jq jq-linux-amd64 "${tmp}/amd64" jq
check_elf "${tmp}/amd64/jq"

echo "=== an asset that does not exist"
out="$(__get_github_release jqlang/jq no-such-asset "${tmp}/none" jq 2>&1)" \
  || fail "__get_github_release exited non-zero instead of reporting the failure"
echo "${out}"
grep -q "Could not download the latest version of 'no-such-asset'" <<< "${out}" \
  || fail "no \"Could not download\" message for a missing asset"
[[ ! -s "${tmp}/none/jq" ]] || fail "a file was written for a missing asset"

echo
echo "All __get_github_release checks passed"
