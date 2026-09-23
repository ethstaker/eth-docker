#!/usr/bin/env bash
# Exercise "ethd keys" against a running validator client, with or without web3signer.
# Expects the stack to be up, the keymanager API to answer, and the three Hoodi test keys
# from .github/keymanager-keys in .eth/validator_keys. The keys are not deposited, which the
# script checks before importing them, so nothing here is slashable, and sign-exit can only take
# its "not on the beacon chain" path.
#
# Environment:
#   W3S              true when web3signer is in use
#   PRYSM_WALLET     true to test create-prysm-wallet and get-prysm-wallet
#   GRANDINE_WALLET  true to test get-grandine-wallet
#   NO_BUILDER_API   true when the client does not serve the builder configuration API yet
#   CL_SERVICE       the compose service serving the beacon API, consensus by default
#   KEYSTORE_PASSWORD  password of the test keys, for import --non-interactive
#
# The workflow sets GRAFFITI=eth-docker-default, the process-wide default that delete-graffiti
# has to restore.
#
# keymanager.sh exits 0 on several soft failures, so the checks match on output as well.

set -Eeuo pipefail

w3s="${W3S:-false}"
prysm_wallet="${PRYSM_WALLET:-false}"
grandine_wallet="${GRANDINE_WALLET:-false}"
no_builder_api="${NO_BUILDER_API:-false}"
recipient=0x1111111111111111111111111111111111111111
builder_url=https://builder.example.org:18550

if [[ -z "${KEYSTORE_PASSWORD:-}" ]]; then
  echo "KEYSTORE_PASSWORD has to be set to the password of the test keys"
  exit 1
fi
export KEYSTORE_PASSWORD

pubkeys=()
for keyfile in .eth/validator_keys/keystore-*.json; do
  pubkeys+=( "0x$(jq -r '.pubkey' "${keyfile}")" )
done
if [[ "${#pubkeys[@]}" -ne 3 ]]; then
  echo "Expected three keystore files in .eth/validator_keys, found ${#pubkeys[@]}"
  exit 1
fi
pk1=${pubkeys[0]}
pk2=${pubkeys[1]}
pk3=${pubkeys[2]}

# The keys and their deposit data are public, so anyone can deposit them. Refuse to import them
# anywhere if that happened: parallel jobs would sign with the same keys, and the sign-exit checks
# would no longer mean anything. Same probe as wait-for-beacon-api.sh, as not every client image
# ships curl and the REST port is not always published.
consensus_container="$(docker compose ps -q "${CL_SERVICE:-consensus}")"
for key in "${pubkeys[@]}"; do
  # Retry, so a dropped connection is not mistaken for either answer
  for attempt in 1 2 3; do
    code="$(docker run --rm --network "container:${consensus_container}" curlimages/curl:8.22.0 \
      -s -m 10 -o /dev/null -w '%{http_code}' \
      "http://localhost:5052/eth/v1/beacon/states/head/validators/${key}" || true)"
    [[ "${code}" =~ ^(200|404)$ ]] && break
    echo "Checking test key ${key} on the beacon chain, attempt ${attempt} got HTTP code \"${code}\""
    sleep 5
  done
  case "${code}" in
    404) ;;
    200)
      echo "Test key ${key} is on the beacon chain: someone deposited it."
      echo "Generate new test keys for .github/keymanager-keys; these can no longer be used safely."
      exit 1
      ;;
    *)
      echo "Could not check whether test key ${key} is on the beacon chain, HTTP code \"${code}\"."
      exit 1
      ;;
  esac
done
echo "None of the test keys are on the beacon chain"

default_recipient="$(sed -n 's/^FEE_RECIPIENT=//p' .env)"
slashing_file=".eth/validator_keys/slashing_protection-${pk1::10}--${pk1:90}.json"

__out=""
__rc=0
__step=""


# Call as run "<description>" [input] -- ethd keys arguments
run() {
  local input=""

  __step=$1
  shift
  if [[ "$1" != "--" ]]; then
    input=$1
    shift
  fi
  shift
  echo
  echo "=== ${__step}: ethd keys $*"
  set +e
  __out="$(./ethd keys "$@" 2>&1 <<< "${input}")"
  __rc=$?
  set -e
  __out="${__out//$'\r'/}"
  echo "${__out}"
  echo "--- exit code ${__rc}"
}


# Call as run_json "<description>" -- ethd keys arguments
# Like run, but only stdout is captured, the way a user redirects --json output. Docker compose
# writes its progress to stderr, and that would otherwise end up in front of the JSON.
run_json() {
  local errfile

  __step=$1
  shift 2
  errfile="$(mktemp)"
  echo
  echo "=== ${__step}: ethd keys $*"
  set +e
  __out="$(./ethd keys "$@" 2>"${errfile}" </dev/null)"
  __rc=$?
  set -e
  __out="${__out//$'\r'/}"
  cat "${errfile}"
  rm -f "${errfile}"
  echo "${__out}"
  echo "--- exit code ${__rc}"
}


fail() {
  echo
  echo "FAILED at \"${__step}\": $*"
  exit 1
}


expect_rc() {
  [[ "${__rc}" -eq "$1" ]] || fail "expected exit code $1, got ${__rc}"
}


expect_out() {
  grep -Eqi -- "$1" <<< "${__out}" || fail "expected output matching \"$1\""
}


expect_no_out() {
  if grep -Eqi -- "$1" <<< "${__out}"; then
    fail "did not expect output matching \"$1\""
  fi
}


# Call as check_count N. With web3signer, the keys have to be both in web3signer and
# registered with the validator client.
check_count() {
  run "count is $1" -- count
  expect_rc 0
  expect_out "Validator keys loaded into [a-z0-9-]+: $1\$"
  if [[ "${w3s}" = "true" ]]; then
    expect_out "Remote Validator keys registered with [a-z0-9-]+: $1\$"
    expect_no_out "number of keys loaded into Web3signer and registered with the validator client differ"
  fi
}


# Call as check_listed "yes|no" 0xPUBKEY...
check_listed() {
  local want=$1
  local key

  shift
  run "list" -- list
  expect_rc 0
  for key in "$@"; do
    if [[ "${want}" = "yes" ]]; then
      expect_out "${key}"
    else
      expect_no_out "${key}"
    fi
  done
}


test_builder() {
  local json_file

# Clients without the builder configuration API only get the "not served" path checked. Once a
# client serves it, this fails, and its no_builder_api line in the workflow can go.
  if [[ "${no_builder_api}" = "true" ]]; then
    run "get-builder, API not served" -- get-builder "${pk1}"
    expect_rc 0
    expect_out "did not serve the builder configuration API"
    return
  fi

  json_file="$(mktemp)"

  run "get-builder" -- get-builder "${pk1}"
  expect_rc 0
  expect_out "builder configuration in effect"

  run_json "get-builder --json" -- get-builder "${pk1}" --json
  expect_rc 0
  jq -e 'type == "object"' <<< "${__out}" >/dev/null || fail "get-builder --json did not print a JSON object"
  echo "${__out}" > "${json_file}"

  run "set-builder none" -- set-builder "${pk1}" none
  expect_rc 0
  expect_out "builder configuration for the validator with public key ${pk1} was updated"
  run "get-builder after none" -- get-builder "${pk1}"
  expect_out "p2p bids only"

  run "set-builder options" -- set-builder "${pk1}" --min-bid 0.01 --boost-factor maxprofit
  expect_rc 0
  expect_out "was updated"
  run_json "get-builder after options" -- get-builder "${pk1}" --json
  expect_rc 0
  jq -e '(.min_bid | tostring) == "10000000" and (.builder_boost_factor | tostring) == "100"' \
    <<< "${__out}" >/dev/null || fail "min_bid and builder_boost_factor were not stored"

  run "set-builder --from-json" -- set-builder "${pk1}" --from-json "${json_file}"
  expect_rc 0
  expect_out "was updated"

  run "set-builder list of keys" -- set-builder "${pk2},${pk3}" "${builder_url}"
  expect_rc 0
  expect_out "Updated the builder configuration for 2 of 2 validators"
  run "get-builder after url" -- get-builder "${pk2}"
  expect_out "${builder_url}"

  run "delete-builder all" -- delete-builder all
  expect_rc 0
  expect_out "Removed the builder configuration for 3 of 3 validators"

  rm -f "${json_file}"
}


run "get-api-token" -- get-api-token
expect_rc 0
grep -Eq '^[[:graph:]]{16,}$' <<< "${__out}" || fail "no API token printed"

if [[ "${prysm_wallet}" = "true" ]]; then
  run "get-prysm-wallet" -- get-prysm-wallet
  expect_rc 0
  if [[ "${w3s}" = "true" ]]; then
    expect_out "No stored password found for a Prysm wallet"
  else
    expect_out "The password for the Prysm wallet is:"
  fi
fi

if [[ "${grandine_wallet}" = "true" ]]; then
  run "get-grandine-wallet" -- get-grandine-wallet
  expect_rc 0
  expect_out "The password for the Grandine wallet is:"
fi

check_count 0
check_listed no "${pk1}" "${pk2}" "${pk3}"

run "import" -- import --non-interactive
expect_rc 0
expect_out "Imported 3 keys"
if [[ "${w3s}" = "true" ]]; then
  expect_out "Registered 3 keys with the validator client"
fi
check_count 3
check_listed yes "${pk1}" "${pk2}" "${pk3}"

run "import duplicates" -- import --non-interactive
expect_rc 0
expect_out "Imported 0 keys"
expect_out "Skipped 3 keys"
check_count 3

run "register" -- register
if [[ "${w3s}" = "true" ]]; then
  expect_rc 0
  expect_out "Skipped registration of 3 keys"
  check_count 3
else
  expect_rc 1
  expect_out "WEB3SIGNER is not \"true\""
fi

run "set-recipient" -- set-recipient "${pk1}" "${recipient}"
expect_rc 0
expect_out "fee recipient for the validator with public key ${pk1} was updated"
run "get-recipient" -- get-recipient "${pk1}"
expect_rc 0
expect_out "${recipient}"
run "delete-recipient" -- delete-recipient "${pk1}"
expect_rc 0
expect_out "set back to default"
run "get-recipient after delete" -- get-recipient "${pk1}"
expect_rc 0
expect_out "${default_recipient}"

run "set-gas" -- set-gas "${pk1}" 36000000
expect_rc 0
expect_out "gas limit for the validator with public key ${pk1} was updated"
run "get-gas" -- get-gas "${pk1}"
expect_rc 0
expect_out "^36000000\$"
run "delete-gas" -- delete-gas "${pk1}"
expect_rc 0
expect_out "set back to default"
run "get-gas after delete" -- get-gas "${pk1}"
expect_rc 0
expect_out "execution gas limit for the validator"

run "set-graffiti" -- set-graffiti "${pk1}" eth-docker-ci
expect_rc 0
expect_out "graffiti for the validator with public key ${pk1} was updated"
run "get-graffiti" -- get-graffiti "${pk1}"
expect_rc 0
expect_out "eth-docker-ci"
run "delete-graffiti" -- delete-graffiti "${pk1}"
expect_rc 0
expect_out "set back to default"
run "get-graffiti after delete" -- get-graffiti "${pk1}"
expect_rc 0
expect_no_out "eth-docker-ci"
expect_out "eth-docker-default"

test_builder

run "sign-exit" -- sign-exit "${pk1}"
expect_rc 0
expect_out "has to be active with an index on the beacon chain"
expect_out "Signed exit messages for 0 keys"
if compgen -G ".eth/exit_messages/*.json" >/dev/null; then
  fail "an exit message was written for a key that is not on the beacon chain"
fi

run "send-exit" -- send-exit
expect_rc 1
expect_out "No exit message files found"

rm -f "${slashing_file}"
run "delete one" -- delete "${pk1}"
expect_rc 0
expect_out "Validator ${pk1} deleted"
expect_out "Slashing protection data written"
if [[ "${w3s}" = "true" ]]; then
  expect_out "Remote registration for validator ${pk1} deleted"
fi
[[ -s "${slashing_file}" ]] || fail "no slashing protection file at ${slashing_file}"
jq -e '.metadata.interchange_format_version' "${slashing_file}" >/dev/null \
  || fail "${slashing_file} is not an EIP-3076 interchange file"
# A key that never signed may be left out of the export entirely, as web3signer does, or be listed
# with empty history, as Lodestar does. Re-import takes a different path for each. The comparison
# ignores case, so a signer writing the key in another case trips keymanager.sh's grep and fails.
if jq -e --arg pk "${pk1,,}" 'any(.data[]; (.pubkey | ascii_downcase) == $pk)' "${slashing_file}" >/dev/null; then
  slashing_lists_key=true
else
  slashing_lists_key=false
fi
echo "Slashing protection file lists ${pk1}: ${slashing_lists_key}"
check_count 2
check_listed no "${pk1}"
check_listed yes "${pk2}" "${pk3}"

run "re-import" -- import --non-interactive
expect_rc 0
expect_out "Imported 1 keys"
expect_out "Skipped 2 keys"
if [[ "${slashing_lists_key}" = "true" ]]; then
  expect_out "Found slashing protection import file .*slashing_protection-${pk1::10}"
else
  expect_out "No viable slashing protection import file found for ${pk1}"
fi
check_count 3

run "delete all, declined" "no" -- delete all
expect_rc 130
expect_out "Aborting key deletion"
check_count 3

run "delete all" "yes" -- delete all
expect_rc 0
expect_out "Deleting key 3 of 3"
check_count 0

echo
echo "All keymanager checks passed"
