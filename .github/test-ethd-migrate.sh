#!/usr/bin/env bash
# Regression tests for the .env migration in "ethd update".
#
# These guard the ENV_VERSION 53 -> 54 split of COMPOSE_FILE into CORE_FILES plus CUSTOM_FILES.
# Copying COMPOSE_FILE into CORE_FILES when COMPOSE_FILE already refers to CORE_FILES makes that
# variable self-referential, which empties COMPOSE_FILE and loses the client choice.
# They also cover later value migrations, such as the EPBS_BUILD_FACTOR meaning of 100, and the
# move from MEV_BOOST and MEV_RELAYS to EPBS_BUILDERS and EPBS_BUILDER_URLS after Glamsterdam.
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

del_from_env() {  # del_from_env <variable>, also drops the continuation lines of a multi-line quoted value
  awk -v var="$1" '
    skip { if ($0 ~ /"$/) { skip = 0 } next }
    index($0, var "=") == 1 {
      value = substr($0, length(var) + 2)
      if (value ~ /^"/ && (value == "\"" || value !~ /"$/)) { skip = 1 }
      next
    }
    { print }
  ' .env > .env.new
  mv .env.new .env
}

get_value() {
  grep -m1 "^$1=" .env | cut -d= -f2-
}

get_raw_value() {  # get_raw_value <variable>, prints the value as written, with the quotes and newlines of a multi-line value
  awk -v var="$1" '
    inside { out = out "\n" $0; if ($0 ~ /"$/) { print out; exit } next }
    index($0, var "=") == 1 {
      out = substr($0, length(var) + 2)
      if (out ~ /^"/ && (out == "\"" || out !~ /"$/)) { inside = 1; next }
      print out
      exit
    }
  ' .env
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

sepolia_mev_env() {  # sepolia_mev_env <env_version>, a Sepolia .env that used MEV Boost before ePBS
  fresh_env
  set_in_env ENV_VERSION "$1"
  set_in_env NETWORK sepolia
  set_in_env MEV_BOOST true
  set_in_env EPBS_BUILDERS false
  set_in_env EPBS_BUILDER_URLS ""
}

set_relays() {  # set_relays <value>, replaces the multi-line default MEV_RELAYS
  del_from_env MEV_RELAYS
  set_in_env MEV_RELAYS "$1"
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

echo "== EPBS_BUILD_FACTOR 100 meant always before ENV_VERSION 72, and now means maxprofit =="
fresh_env
set_in_env ENV_VERSION 71
set_in_env EPBS_BUILD_FACTOR 100
output=$(run_update)
check_equals "100 becomes always" "always" "$(get_value EPBS_BUILD_FACTOR)"
set_in_env EPBS_BUILD_FACTOR 100
output=$(run_update)
check_equals "a 100 set after the migration stays 100" "100" "$(get_value EPBS_BUILD_FACTOR)"
fresh_env
set_in_env ENV_VERSION 71
set_in_env EPBS_BUILD_FACTOR 90
output=$(run_update)
check_equals "90 stays 90" "90" "$(get_value EPBS_BUILD_FACTOR)"
fresh_env
set_in_env ENV_VERSION 60
del_from_env EPBS_BUILD_FACTOR
set_in_env MEV_BUILD_FACTOR 100
output=$(run_update)
check_equals "an old MEV_BUILD_FACTOR 100 becomes always" "always" "$(get_value EPBS_BUILD_FACTOR)"

# Adjust RIGHT after each network's Glamsterdam hardfork
__titan_relay="https://0xabc@sepolia.titanrelay.xyz"
__titan_urls=$'"\nhttps://sepolia.titanrelay.xyz\n"'

echo "== MEV Boost on Sepolia before ENV_VERSION 73 moves to ePBS builders =="
sepolia_mev_env 72
set_relays "${__titan_relay}"
output=$(run_update)
check_equals "MEV_BOOST is turned off" "false" "$(get_value MEV_BOOST)"
check_equals "MEV_RELAYS is emptied" "" "$(get_raw_value MEV_RELAYS)"
check_equals "EPBS_BUILDERS is turned on" "true" "$(get_value EPBS_BUILDERS)"
check_equals "EPBS_BUILDER_URLS holds the builder matching the relay" "${__titan_urls}" "$(get_raw_value EPBS_BUILDER_URLS)"
check_output "it says MEV Boost was disabled" "Disabled MEV Boost on sepolia" "${output}"
check_output "it says ePBS was enabled" "Enabled ePBS on sepolia" "${output}"
check_output "it says builder URLs were set" "Set ePBS builder URLs on sepolia" "${output}"

echo "== A relay without a matching Sepolia builder falls back to all builders =="
sepolia_mev_env 72
set_relays "https://0xabc@boost-relay-sepolia.flashbots.net"
output=$(run_update)
__urls="$(get_raw_value EPBS_BUILDER_URLS)"
check_output "EPBS_BUILDER_URLS has Titan" "https://sepolia.titanrelay.xyz" "${__urls}"
check_output "EPBS_BUILDER_URLS has NFlaig Dev" "https://builder-sepolia.nflaig.dev" "${__urls}"

echo "== A .env from before ePBS gets EPBS_BUILDERS and EPBS_BUILDER_URLS on Sepolia =="
sepolia_mev_env 60
del_from_env EPBS_BUILDERS
del_from_env EPBS_BUILDER_URLS
set_relays "${__titan_relay}"
output=$(run_update)
check_equals "EPBS_BUILDERS is turned on" "true" "$(get_value EPBS_BUILDERS)"
check_equals "EPBS_BUILDER_URLS holds the builder matching the relay" "${__titan_urls}" "$(get_raw_value EPBS_BUILDER_URLS)"
check_output "it says ePBS was enabled" "Enabled ePBS on sepolia" "${output}"

echo "== Builder URLs the user set are kept =="
sepolia_mev_env 72
set_in_env EPBS_BUILDER_URLS https://example.builder
set_relays "${__titan_relay}"
output=$(run_update)
check_equals "EPBS_BUILDER_URLS is left alone" "https://example.builder" "$(get_raw_value EPBS_BUILDER_URLS)"
check_equals "EPBS_BUILDERS is turned on" "true" "$(get_value EPBS_BUILDERS)"

echo "== Sepolia without MEV Boost keeps ePBS builders off =="
sepolia_mev_env 72
set_in_env MEV_BOOST false
output=$(run_update)
check_equals "EPBS_BUILDERS stays false" "false" "$(get_value EPBS_BUILDERS)"
check_equals "EPBS_BUILDER_URLS stays empty" "" "$(get_raw_value EPBS_BUILDER_URLS)"

echo "== Hoodi keeps MEV Boost until its own Glamsterdam =="
sepolia_mev_env 72
set_in_env NETWORK hoodi
__relays="$(get_raw_value MEV_RELAYS)"
output=$(run_update)
check_equals "MEV_BOOST stays true" "true" "$(get_value MEV_BOOST)"
check_equals "MEV_RELAYS is kept" "${__relays}" "$(get_raw_value MEV_RELAYS)"
check_equals "EPBS_BUILDERS stays false" "false" "$(get_value EPBS_BUILDERS)"
check_equals "EPBS_BUILDER_URLS stays empty" "" "$(get_raw_value EPBS_BUILDER_URLS)"

echo "== A Sepolia .env already at ENV_VERSION 73 is not migrated again =="
sepolia_mev_env 73
set_relays "${__titan_relay}"
output=$(run_update)
check_equals "MEV_BOOST stays true" "true" "$(get_value MEV_BOOST)"
check_equals "EPBS_BUILDERS stays false" "false" "$(get_value EPBS_BUILDERS)"

# Leave a pristine .env behind, the way the checkout had it before this ran
rm -f .env.new .env.source .env.partial .env.bak.*
cp default.env .env

echo
echo "passed: ${__pass}   failed: ${__fail}"
[[ "${__fail}" -eq 0 ]]
