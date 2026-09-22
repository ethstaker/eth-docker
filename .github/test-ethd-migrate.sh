#!/usr/bin/env bash
# Regression tests for the .env migration in "ethd update".
#
# These guard the ENV_VERSION 53 -> 54 split of COMPOSE_FILE into CORE_FILES plus CUSTOM_FILES.
# Copying COMPOSE_FILE into CORE_FILES when COMPOSE_FILE already refers to CORE_FILES makes that
# variable self-referential, which empties COMPOSE_FILE and loses the client choice.
#
# Run from the root of an eth-docker checkout. It replaces .env, so only run this in CI or in a
# scratch checkout, never against a live node.

set -uo pipefail

if [[ ! -f ./ethd || ! -f ./default.env ]]; then
  echo "Run this from the root of an eth-docker checkout"
  exit 1
fi

__pass=0
__fail=0
# shellcheck disable=SC2016
__literal='${CORE_FILES}${CUSTOM_FILES:+:${CUSTOM_FILES}}'

set_in_env() {  # set_in_env <variable> <value>, appends when the variable is not there yet
  local name="$1"
  local value="$2"
  local line
  local found=0

  : > .env.new
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" = "${name}="* ]]; then
      printf '%s=%s\n' "${name}" "${value}" >> .env.new
      found=1
    else
      printf '%s\n' "${line}" >> .env.new
    fi
  done < .env
  if [[ "${found}" -eq 0 ]]; then
    printf '%s=%s\n' "${name}" "${value}" >> .env.new
  fi
  mv .env.new .env
}

del_from_env() {  # del_from_env <variable>
  grep -v "^$1=" .env > .env.new || true
  mv .env.new .env
}

get_value() {
  grep -m1 "^$1=" .env | cut -d= -f2-
}

check_equals() {  # check_equals <description> <expected> <actual>
  if [[ "$2" = "$3" ]]; then
    echo "  PASS  $1"
    __pass=$((__pass + 1))
  else
    echo "  FAIL  $1"
    echo "        expected: [$2]"
    echo "        actual:   [$3]"
    __fail=$((__fail + 1))
  fi
}

check_output() {  # check_output <description> <needle> <haystack>
  if grep -qF -- "$2" <<< "$3"; then
    echo "  PASS  $1"
    __pass=$((__pass + 1))
  else
    echo "  FAIL  $1 - output did not contain \"$2\""
    __fail=$((__fail + 1))
  fi
}

fresh_env() {
  rm -f .env .env.new .env.source .env.partial .env.bak.*
  cp default.env .env
}

make_pre_54() {  # a .env from before ENV_VERSION 54 had neither, COMPOSE_FILE held the yml files
  del_from_env CORE_FILES
  del_from_env CUSTOM_FILES
}

run_update() {  # ETHDSECUNDO skips the git and screen handling, leaving the migration itself
  ETHDSECUNDO=1 ./ethd update --debug --non-interactive 2>&1
}

echo "== A pre-54 .env is still split into CORE_FILES and COMPOSE_FILE =="
fresh_env
set_in_env ENV_VERSION 42
set_in_env COMPOSE_FILE teku.yml:besu.yml
make_pre_54
output=$(run_update)
check_equals "CORE_FILES taken from the old COMPOSE_FILE" "teku.yml:besu.yml" "$(get_value CORE_FILES)"
check_equals "COMPOSE_FILE combines the two" "${__literal}" "$(get_value COMPOSE_FILE)"

echo "== A stale ENV_VERSION does not clobber a current CORE_FILES =="
fresh_env
set_in_env ENV_VERSION 42
set_in_env CORE_FILES lighthouse.yml:nethermind.yml
output=$(run_update)
check_equals "CORE_FILES is left alone" "lighthouse.yml:nethermind.yml" "$(get_value CORE_FILES)"
check_equals "COMPOSE_FILE combines the two" "${__literal}" "$(get_value COMPOSE_FILE)"
check_output "it says ethd did not write this .env" "does not create that combination" "${output}"
check_output "it points at staging tooling" "such as Ansible" "${output}"

echo "== A missing ENV_VERSION is detected instead of read as 0 =="
fresh_env
set_in_env CORE_FILES lighthouse.yml:nethermind.yml
del_from_env ENV_VERSION
output=$(run_update)
check_equals "CORE_FILES is left alone" "lighthouse.yml:nethermind.yml" "$(get_value CORE_FILES)"
check_output "it warns about ENV_VERSION" "no readable ENV_VERSION" "${output}"
check_output "it works the version out from CORE_FILES" "Assuming version 54" "${output}"

echo "== A CORE_FILES corrupted by an earlier update is repaired from a backup =="
fresh_env
set_in_env CORE_FILES lighthouse.yml:nethermind.yml
cp .env .env.bak.1700000000
set_in_env CORE_FILES "${__literal}"
set_in_env ENV_VERSION 69
output=$(run_update)
check_equals "CORE_FILES is recovered" "lighthouse.yml:nethermind.yml" "$(get_value CORE_FILES)"
check_output "it says what it repaired" "Repaired a corrupted CORE_FILES" "${output}"

echo "== A corrupted CORE_FILES with no backup stops the update =="
fresh_env
set_in_env CORE_FILES "${__literal}"
set_in_env ENV_VERSION 69
output=$(run_update)
check_output "it says there is no backup" "no usable backup" "${output}"
check_output "it points at ethd config" "to choose your clients again" "${output}"
check_equals "the .env is rolled back, not half migrated" "${__literal}" "$(get_value CORE_FILES)"

echo "== Version gated migrations that test COMPOSE_FILE still fire for a pre-54 .env =="
fresh_env
set_in_env ENV_VERSION 42
set_in_env COMPOSE_FILE lighthouse.yml:nethermind.yml
set_in_env CL_NODE_TYPE archive
set_in_env EL_EXTRAS ""
make_pre_54
output=$(run_update)
check_equals "CL_NODE_TYPE becomes blob-archive" "blob-archive" "$(get_value CL_NODE_TYPE)"
check_equals "Nethermind gets its log index" "--LogIndex.Enabled true" "$(get_value EL_EXTRAS)"

# Leave a pristine .env behind, the way the checkout had it before this ran
rm -f .env.new .env.source .env.partial .env.bak.*
cp default.env .env

echo
echo "passed: ${__pass}   failed: ${__fail}"
[[ "${__fail}" -eq 0 ]]
