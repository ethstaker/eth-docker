#!/usr/bin/env bash
# Assertions for "ethd port-check". Call with "offline", for a stack that is not running,
# or "online", once the consensus client's Beacon API answers.
#
# Deliberately no "set -e": every assertion runs, so one CI run reports every problem
# rather than stopping at the first. The exit status is non-zero when any of them failed.

mode="${1:-}"
failures=0
output=""
status=0

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

pass() {
  echo "PASS - $1"
}

fail() {
# Call with a label and, optionally, the output that disproves it
  echo "FAIL - $1"
  if [[ -n "${2:-}" ]]; then
    echo "----- output -----"
    echo "$2"
    echo "------------------"
  fi
  failures=$(( failures + 1 ))
}

assert_status() {
# Call with a label, the expected exit status, the actual one, and the output
  if [[ "$3" -eq "$2" ]]; then
    pass "$1"
  else
    fail "$1 - expected exit ${2}, got ${3}" "$4"
  fi
}

assert_contains() {
# Call with a label, the text to find, and the output to search
  if grep -qF -- "$2" <<< "$3"; then
    pass "$1"
  else
    fail "$1 - did not find \"$2\"" "$3"
  fi
}

assert_lacks() {
# Call with a label, the text that must be absent, and the output to search
  if grep -qF -- "$2" <<< "$3"; then
    fail "$1 - found \"$2\", which must not be there" "$3"
  else
    pass "$1"
  fi
}

run_port_check() {
# Call with any port-check arguments. Sets "output" and "status". Errors are folded into
# the output because the unknown-option message goes to stderr.
  output="$(./ethd port-check "$@" 2>&1)"
  status=$?
}

extract_pubkey() {
# Call with port-check output. Echoes the 128 hex characters of the first "Public key" row,
# which __wrapped_row prints as two 64-character lines.
  awk '/^  Public key /{ print $3; getline; print $1; exit }' <<< "$1" | tr -d '\n'
}


test_offline() {
  run_port_check --bogus
  assert_status "unknown option exits 1" 1 "${status}" "${output}"
  assert_contains "unknown option is named" "Error: Unknown option: --bogus" "${output}"

  # Also confirms client detection: nimbus-cl-only.yml must resolve to Nimbus
  run_port_check
  assert_status "unreachable API exits 1" 1 "${status}" "${output}"
  assert_contains "unreachable API names the client and port" \
    "Unable to reach Nimbus's Beacon API on port 5052" "${output}"

  run_port_check --troubleshoot
  assert_status "unreachable API with --troubleshoot exits 1" 1 "${status}" "${output}"
  assert_contains "--troubleshoot names the compose exec route" \
    "Tried it inside the \"consensus\" service" "${output}"
  assert_contains "--troubleshoot names the throwaway container route" \
    "throwaway container" "${output}"
}


test_online() {
  local plain_output
  local pubkey
  local shim_pubkey
  local shimdir

  run_port_check
  assert_status "port-check exits 0" 0 "${status}" "${output}"
  assert_contains "report names the client" "Nimbus port check" "${output}"
  assert_contains "report has a CGNAT row" "CGNAT" "${output}"
  assert_contains "report has a Dual-stack row" "Dual-stack" "${output}"
  assert_contains "report has a Peer ID row" "Peer ID" "${output}"
  assert_contains "report has an Inbound row" "Inbound" "${output}"
  plain_output="${output}"

  # The canary. This can only pass when base64, od, the RLP walk and the point
  # decompression all worked, so it catches a BSD/GNU tool difference that would
  # otherwise degrade the report silently while still exiting 0.
  pubkey="$(extract_pubkey "${plain_output}")"
  if [[ "${#pubkey}" -eq 128 && "${pubkey}" =~ ^[0-9a-f]+$ ]]; then
    pass "public key is 128 hex characters"
  else
    fail "public key is not 128 hex characters - got \"${pubkey}\"" "${plain_output}"
  fi

  # A runner has no inbound, so the guidance with the probe commands prints - the case
  # the privacy rule is about. The --troubleshoot diagnostics do carry the ENR by design.
  assert_lacks "no ENR in the probe commands" "enr:" "${plain_output}"

  run_port_check --troubleshoot
  assert_status "--troubleshoot exits 0" 0 "${status}" "${output}"
  assert_contains "--troubleshoot prints diagnostics" "Diagnostics" "${output}"
  assert_contains "Beacon API row names the compose exec route" \
    "docker compose exec consensus" "${output}"

  # macOS ships LibreSSL, which may reject "ec -conv_form uncompressed". Falling through
  # to python3 there is correct, so only Linux pins which tool did the work.
  if [[ "$OSTYPE" = "darwin"* ]]; then
    if grep -qE "decompressed with (openssl|python3)" <<< "${output}"; then
      pass "public key was decompressed by openssl or python3"
    else
      fail "public key was decompressed by neither openssl nor python3" "${output}"
    fi
  else
    assert_contains "public key was decompressed by openssl" "decompressed with openssl" "${output}"
  fi

  # An openssl that fails sends __enr_pubkey down its python3 path. Both must agree.
  if ! type -P python3 >/dev/null 2>&1; then
    echo "SKIP - no python3 on this host, cannot check the fallback path"
    return 0
  fi
  shimdir="${tmpdir}/shim"
  mkdir -p "${shimdir}"
  printf '#!/bin/sh\nexit 1\n' > "${shimdir}/openssl"
  chmod +x "${shimdir}/openssl"
  output="$(PATH="${shimdir}:${PATH}" ./ethd port-check --troubleshoot 2>&1)"
  status=$?
  assert_status "port-check exits 0 without a working openssl" 0 "${status}" "${output}"
  assert_contains "python3 reads the key when openssl cannot" \
    "decompressed with python3" "${output}"
  shim_pubkey="$(extract_pubkey "${output}")"
  if [[ "${shim_pubkey}" = "${pubkey}" ]]; then
    pass "openssl and python3 agree on the public key"
  else
    fail "openssl gave \"${pubkey}\" but python3 gave \"${shim_pubkey}\"" "${output}"
  fi
}


case "${mode}" in
  offline) test_offline;;
  online) test_online;;
  *)
    echo "Call with \"offline\" or \"online\""
    exit 1
    ;;
esac

echo
if [[ "${failures}" -gt 0 ]]; then
  echo "${failures} port-check assertion(s) failed"
  exit 1
fi
echo "All port-check ${mode} assertions passed"
