#!/usr/bin/env bash
# Assertions for the check that stops a stack with two validator clients. Needs no Docker:
# it sources "ethd", stubs out compose, and drives __check_double_vc with canned COMPOSE_FILEs.
#
# Deliberately no "set -e": every assertion runs. The exit status is non-zero when any failed.

failures=0

# shellcheck source=/dev/null
if ! ETHD_SOURCE_ONLY=1 source ./ethd; then
  echo "FAIL - ethd can be sourced without running a command"
  exit 1
fi
set +eEuo pipefail  # "ethd" turns these on; this script is deliberately without them

__env_file=$(mktemp)
echo "ENV_VERSION=78" > "${__env_file}"
__me=ethd
__docompose() {
  echo "STUB compose $*"
}

check() {
# Call with a COMPOSE_FILE and the expected exit status
  local output rc

  # shellcheck disable=SC2034  # __check_double_vc reads it
  output=$(COMPOSE_FILE="$1"; __check_double_vc 2>&1)
  rc=$?
  if [[ "${rc}" -ne "$2" ]]; then
    echo "FAIL - ${1} - expected exit ${2}, got ${rc}"
    echo "${output}"
    failures=$(( failures + 1 ))
  elif [[ "$2" -ne 0 && "${output}" != *"STUB compose down --remove-orphans"* ]]; then
    echo "FAIL - ${1} - did not stop the stack"
    echo "${output}"
    failures=$(( failures + 1 ))
  else
    echo "PASS - ${1} - exit ${rc}"
  fi
}

check "teku.yml:geth.yml" 0
check "lighthouse-cl-only.yml:teku-vc-only.yml:grafana.yml:grafana-for-vc.yml" 0
check "teku.yml:teku.yml" 0
check "teku-vc-only.yml:grafana.yml:grafana-vc-only.yml" 0
check "grandine-plugin-cl-only.yml:caplin.yml:web3signer.yml:vc-traefik.yml:allin1-keyapi-shared.yml" 0
check "lighthouse.yml:teku-vc-only.yml" 1
check "nimbus-allin1.yml:reth.yml:vero-vc-only.yml" 1
check "prysm.yml:lodestar.yml:nimbus.yml" 1
check "grandine.yml:lighthouse-vc-only.yml" 1
check "grandine-plugin.yml:nethermind.yml:lighthouse-vc-only.yml" 1

# Remove after Glamsterdam
# Before 78, grandine-plugin.yml had no VC. "update" has to get past the check to rename it
echo "ENV_VERSION=77" > "${__env_file}"
check "grandine-plugin.yml:nethermind.yml:lighthouse-vc-only.yml" 0
rm -f "${__env_file}"

echo
if [[ "${failures}" -gt 0 ]]; then
  echo "${failures} double-VC assertion(s) failed"
  exit 1
fi
echo "All double-VC assertions passed"
