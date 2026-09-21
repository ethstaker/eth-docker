#!/usr/bin/env bash
# Assertions for "ethd port-check". Call with "offline", for a stack that is not running,
# "online", once the consensus client's Beacon API answers, or "fixtures", which needs
# neither - it sources "ethd" and drives its helpers against a canned ENR.
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

assert_eq() {
# Call with a label, the expected value, and the actual one
  if [[ "$3" = "$2" ]]; then
    pass "$1"
  else
    fail "$1 - expected \"$2\", got \"$3\""
  fi
}

assert_rc() {
# Call with a label, the expected exit status, and the actual one
  if [[ "$3" -eq "$2" ]]; then
    pass "$1"
  else
    fail "$1 - expected exit ${2}, got ${3}"
  fi
}

assert_true() {
# Call with a label and a predicate, with its arguments, that has to return 0
  local label="$1"
  shift
  if "$@"; then
    pass "${label}"
  else
    fail "${label}"
  fi
}

assert_false() {
# Call with a label and a predicate, with its arguments, that has to return non-zero
  local label="$1"
  shift
  if "$@"; then
    fail "${label}"
  else
    pass "${label}"
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

  # --debug implies --troubleshoot, so the unreachable path must read the same
  run_port_check --debug
  assert_status "unreachable API with --debug exits 1" 1 "${status}" "${output}"
  assert_contains "--debug names the compose exec route" \
    "Tried it inside the \"consensus\" service" "${output}"
  assert_contains "--debug names the throwaway container route" \
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

  # The three tiers. A runner has no inbound, so the plain report is the one that points at
  # --troubleshoot, and --troubleshoot is the one that prints the probe commands.
  assert_lacks "plain output stops short of the guidance" \
    "To ensure inbound peer connectivity:" "${plain_output}"
  assert_contains "plain output points at --troubleshoot" \
    "port-check --troubleshoot" "${plain_output}"
  assert_lacks "no ENR in the plain report" "enr:" "${plain_output}"

  run_port_check --troubleshoot
  assert_status "--troubleshoot exits 0" 0 "${status}" "${output}"
  assert_contains "--troubleshoot prints the guidance" \
    "To ensure inbound peer connectivity:" "${output}"
  assert_contains "--troubleshoot prints the IPv4 probe section" \
    "IPv4 - test incoming ports are open" "${output}"
  assert_lacks "--troubleshoot stops short of the diagnostics" "Diagnostics" "${output}"
  # The privacy rule, on the tier that actually carries the probe commands. Only the --debug
  # diagnostics may name the ENR, and by design.
  assert_lacks "no ENR in the probe commands" "enr:" "${output}"

  run_port_check --debug
  assert_status "--debug exits 0" 0 "${status}" "${output}"
  assert_contains "--debug prints the guidance too" \
    "To ensure inbound peer connectivity:" "${output}"
  assert_contains "--debug prints diagnostics" "Diagnostics" "${output}"
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
  output="$(PATH="${shimdir}:${PATH}" ./ethd port-check --debug 2>&1)"
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



# A record nobody owns, so it can live in the repo: its key is the secp256k1 generator point,
# which is to say a private key of 1, and its addresses come from the documentation ranges
# 203.0.113.0/24 and 2001:db8::/32. Every implementation of the curve publishes the two halves
# the generator decompresses to, so the expected public key below is a constant, not arithmetic
# this repo did once and now trusts. The record is properly signed, so any ENR reader can check
# what the assertions claim - paste it into https://enr-viewer.com/, or run
#   docker run --rm ethereum/client-go:alltools-latest devp2p enrdump <enr>
# which prints "INVALID" on a record whose signature does not hold up.
fixture_enr="enr:-Lm4QH2z7bOXo6bYgd6JCZjFF2DzrbFb_OXwGR7Cqse_ytCaSxpqtJ9IO4mO8GB7ryM6T_dptihwtUq\
UkbJZdqokVwQHgmlkgnY0gmlwhMsAcSqDaXA2kCABDbgAAAAAAAAAAAAAAAGEcXVpY4IjKYVxdWljNoIjjYlzZWNwMjU2azG\
hAnm-Zn753LusVaBilc6HCwcCm_zbLc4o2VnygVsW-BeYg3RjcIIjKIN1ZHCCIyiEdWRwNoIjjA"
fixture_hex="0782696482763482697084cb00712a836970369020010db8000000000000000000000001847175696382\
232985717569633682238d89736563703235366b31a10279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f\
2815b16f817988374637082232883756470822328847564703682238c"
fixture_pubkey="79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798\
483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8"

# The same point compressed with the odd y instead - a private key of n-1, whose public key is
# -G - so that the sign half of the decompression is covered as well. A run that got the parity
# wrong would still print 128 hex characters, and only this catches it.
fixture_enr_odd="enr:-IS4QE8kLzo9ZpgKlByn8X72RCzLE9Jc6qo8vVCfYrkxF7unZDkGK3vo0LPobnW1UHGIvje9SKT\
qWeKHqD7JAOLDPjMBgmlkgnY0gmlwhMCoATKJc2VjcDI1NmsxoQN5vmZ--dy7rFWgYpXOhwsHApv82y3OKNlZ8oFbFvgXmIN\
1ZHCCIyg"
fixture_pubkey_odd="79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798\
b7c52588d95c3b9aa25b0403f1eef75702e84bb7597aabe663b82f6f04ef2777"

# Shaped like a real "/eth/v1/node/peers" body: two inbound peers that count, one that must not
# because it is disconnected, one outbound, and one outbound with no address - which clients do.
fixture_peers='{"data":[
{"peer_id":"16Uiu2HAmInboundQuic","enr":null,"last_seen_p2p_address":"/ip4/203.0.113.7/udp/9000/quic-v1","state":"connected","direction":"inbound"},
{"peer_id":"16Uiu2HAmInboundTcp6","enr":null,"last_seen_p2p_address":"/ip6/2001:db8::7/tcp/9000","state":"connected","direction":"inbound"},
{"peer_id":"16Uiu2HAmGoneAway","enr":null,"last_seen_p2p_address":"/ip4/203.0.113.9/tcp/9000","state":"disconnected","direction":"inbound"},
{"peer_id":"16Uiu2HAmOutboundTcp","enr":null,"last_seen_p2p_address":"/ip4/198.51.100.3/tcp/9000","state":"connected","direction":"outbound"},
{"peer_id":"16Uiu2HAmOutboundMute","enr":null,"state":"connected","direction":"outbound"}
],"meta":{"count":5}}'


assert_text_helpers() {
# Call with a label prefix. Everything here is text handling over a fixed input, which is where
# a BSD tool and a GNU one part ways, so the whole set runs twice - once as this host is, once
# with the Darwin branches forced.
  local tag="$1"
  local hex
  local warning
  local inbound_entries outbound_entries inbound_addresses outbound_addresses

  assert_eq "${tag}: base64 decodes to hex" "68656c6c6f" "$(__base64_to_hex "aGVsbG8=")"

  hex=$(__enr_to_hex "${fixture_enr}")
  assert_eq "${tag}: ENR decodes to its RLP" "${fixture_hex}" "${hex}"

  assert_eq "${tag}: ENR ip" "203.0.113.42" "$(__enr_ip "$(__enr_value "${hex}" 826970)")"
  # The one "sed -E" in the feature: a run of zero groups has to collapse to "::"
  assert_eq "${tag}: ENR ip6" "2001:db8::1" "$(__enr_ip "$(__enr_value "${hex}" 83697036)")"
  assert_eq "${tag}: ENR tcp" "9000" "$(__enr_port "$(__enr_value "${hex}" 83746370)")"
  assert_eq "${tag}: ENR udp" "9000" "$(__enr_port "$(__enr_value "${hex}" 83756470)")"
  assert_eq "${tag}: ENR quic" "9001" "$(__enr_port "$(__enr_value "${hex}" 8471756963)")"
  assert_eq "${tag}: ENR udp6" "9100" "$(__enr_port "$(__enr_value "${hex}" 8475647036)")"
  assert_eq "${tag}: ENR quic6" "9101" "$(__enr_port "$(__enr_value "${hex}" 857175696336)")"
  # The RLP of the key "tcp6" followed by the two-byte port 0x238c. It gets a literal rather
  # than a place in the fixture, which is a signed record that adding a key would invalidate
  assert_eq "${tag}: ENR tcp6" "9100" "$(__enr_port "$(__enr_value "847463703682238c" 8474637036)")"
  # The fixture has no "tcp6", which is the case the IPv6 line's fallback to "tcp" is for
  assert_eq "${tag}: absent ENR tcp6" "" "$(__enr_port "$(__enr_value "${hex}" 8474637036)")"
  # "eth2", which this record does not carry. An absent key must read as absent, not as garbage
  assert_eq "${tag}: absent ENR key" "" "$(__enr_value "${hex}" 8465746832)"

  # A record that cannot be read says so on stderr and gives nothing on stdout, so that the
  # report explains itself rather than printing a row of silently empty values. The two ways
  # that happens are separate branches: base64 refusing the text, and text that decodes to
  # something which is not a signed ENR.
  warning=$(__enr_to_hex 'enr:!!!!not base64!!!!' 2>&1 >/dev/null)
  assert_eq "${tag}: unreadable ENR gives no hex" "" "$(__enr_to_hex 'enr:!!!!not base64!!!!' 2>/dev/null)"
  assert_contains "${tag}: unreadable ENR warns on stderr" "could not decode" "${warning}"
  warning=$(__enr_to_hex "enr:notabase64record" 2>&1 >/dev/null)
  assert_eq "${tag}: unsigned ENR gives no hex" "" "$(__enr_to_hex "enr:notabase64record" 2>/dev/null)"
  assert_contains "${tag}: unsigned ENR warns on stderr" "64-byte signature" "${warning}"

  # The boundaries, which is where a case pattern goes wrong
  assert_true  "${tag}: 192.168.1.1 is private" __is_private_v4 "192.168.1.1"
  assert_true  "${tag}: 172.16.0.1 is private" __is_private_v4 "172.16.0.1"
  assert_true  "${tag}: 172.31.255.255 is private" __is_private_v4 "172.31.255.255"
  assert_false "${tag}: 172.15.0.1 is public" __is_private_v4 "172.15.0.1"
  assert_false "${tag}: 172.32.0.1 is public" __is_private_v4 "172.32.0.1"
  assert_false "${tag}: 203.0.113.42 is public" __is_private_v4 "203.0.113.42"
  assert_true  "${tag}: FE80::1 is private" __is_private_v6 "FE80::1"
  assert_true  "${tag}: fd00::1 is private" __is_private_v6 "fd00::1"
  assert_false "${tag}: 2001:db8::1 is public" __is_private_v6 "2001:db8::1"
  assert_true  "${tag}: 100.64.0.0 is CGNAT" __is_cgnat_v4 "100.64.0.0"
  assert_true  "${tag}: 100.127.255.255 is CGNAT" __is_cgnat_v4 "100.127.255.255"
  assert_false "${tag}: 100.63.255.255 is not CGNAT" __is_cgnat_v4 "100.63.255.255"
  assert_false "${tag}: 100.128.0.1 is not CGNAT" __is_cgnat_v4 "100.128.0.1"

  assert_true  "${tag}: a public v4 listen address counts" \
    __listens_globally "/ip4/203.0.113.42/tcp/9000" ip4
  assert_false "${tag}: private v4 listen addresses do not count" \
    __listens_globally "/ip4/10.0.0.5/tcp/9000"$'\n'"/ip4/127.0.0.1/tcp/9000" ip4
  assert_false "${tag}: a v4 address is not a v6 listen" \
    __listens_globally "/ip4/203.0.113.42/tcp/9000" ip6
  assert_true  "${tag}: a public v6 listen address counts" \
    __listens_globally "/ip6/2001:db8::1/tcp/9000" ip6
  assert_false "${tag}: no listen addresses is not a global listen" __listens_globally "" ip4

  peer_entries=$(tr '\n' ' ' <<< "${fixture_peers}" | tr '{' '\n' | grep '"peer_id"')
  inbound_entries=$(__peers_in_direction "${peer_entries}" inbound)
  outbound_entries=$(__peers_in_direction "${peer_entries}" outbound)
  # Three peers say "inbound"; the disconnected one is not one this node can count
  assert_eq "${tag}: inbound peers" "2" "$(__count_lines "${inbound_entries}")"
  assert_eq "${tag}: outbound peers" "2" "$(__count_lines "${outbound_entries}")"
  inbound_addresses=$(__peer_addresses "${inbound_entries}")
  outbound_addresses=$(__peer_addresses "${outbound_entries}")
  # A client may report a peer with no address, so there can be fewer addresses than peers
  assert_eq "${tag}: outbound addresses" "1" "$(__count_lines "${outbound_addresses}")"
  assert_eq "${tag}: inbound QUIC v4" "1" \
    "$(( $(__count_matching "${inbound_addresses}" '/quic') - $(__count_matching "${inbound_addresses}" '/quic' '/ip6/') ))"
  assert_eq "${tag}: inbound TCP v6" "1" "$(__count_matching "${inbound_addresses}" '/tcp/' '/ip6/')"
  assert_eq "${tag}: inbound TCP v4" "0" \
    "$(( $(__count_matching "${inbound_addresses}" '/tcp/') - $(__count_matching "${inbound_addresses}" '/tcp/' '/ip6/') ))"
  assert_eq "${tag}: no peers counts zero" "0" "$(__count_matching "" '/tcp/')"
}


assert_pubkey() {
# Call with a label prefix. The canary: 128 correct hex characters can only come out when
# base64, od, the RLP walk and the point decompression all did their job.
  local tag="$1"
  local key via

  read -r key via <<< "$(__enr_pubkey "$(__enr_to_hex "${fixture_enr}")")"
  assert_eq "${tag}: public key, even y" "${fixture_pubkey}" "${key}"
  if [[ "${via}" = "openssl" || "${via}" = "python3" ]]; then
    pass "${tag}: key read by ${via}"
  else
    fail "${tag}: key read by neither openssl nor python3 - got \"${via}\""
  fi
  read -r key via <<< "$(__enr_pubkey "$(__enr_to_hex "${fixture_enr_odd}")")"
  assert_eq "${tag}: public key, odd y" "${fixture_pubkey_odd}" "${key}"
}


make_bsd_shims() {
# Call with a directory. Writes stand-ins that answer the way the BSD tools do, so that the
# Darwin branches can be walked on a Linux runner. This proves our branches, not the real
# tools: that BSD "ping6 -X" and "route -n get" behave as modelled still needs a Mac.
  local dir="$1"
  local real_base64
  real_base64=$(type -P base64)

  mkdir -p "${dir}"
  cat > "${dir}/base64" <<EOF
#!/bin/sh
# BSD spells decode "-D"; macOS did not take "-d" before Ventura
case "\$1" in
  -d) echo "base64: illegal option -- d" >&2
      echo "usage: base64 [-Dh] [-b num] [-i in_file] [-o out_file]" >&2
      exit 1
      ;;
  -D) shift; exec "${real_base64}" -d "\$@";;
esac
exec "${real_base64}" "\$@"
EOF
  cat > "${dir}/ping" <<'EOF'
#!/bin/sh
# macOS before Sequoia has no IPv6 in "ping" at all - that is "ping6"
for arg in "$@"; do
  case "${arg}" in
    *:*) echo "ping: cannot resolve ${arg}: Unknown host" >&2; exit 68;;
  esac
done
exit 0
EOF
  cat > "${dir}/route" <<'EOF'
#!/bin/sh
cat <<'OUT'
   route to: 1.1.1.1
destination: default
       mask: default
    gateway: 192.168.7.1
  interface: en0
      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
OUT
EOF
  cat > "${dir}/ipconfig" <<'EOF'
#!/bin/sh
[ "$1" = "getifaddr" ] || exit 1
[ "$2" = "en0" ] || exit 1
echo "192.168.7.22"
EOF
  cat > "${dir}/xcode-select" <<'EOF'
#!/bin/sh
echo "xcode-select: error: unable to get active developer directory" >&2
exit 2
EOF
  cat > "${dir}/ping6-up" <<'EOF'
#!/bin/sh
exit 0
EOF
  cat > "${dir}/ping6-down" <<'EOF'
#!/bin/sh
echo "ping6: sendmsg: Network is unreachable" >&2
exit 2
EOF
  cat > "${dir}/openssl-broken" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "${dir}"/*
}


darwin_pass() {
# Runs the same helpers with OSTYPE forced to Darwin and the BSD stand-ins first on PATH
  local dir="${tmpdir}/bsd"
  local saved_path="${PATH}"
  local saved_ostype="${OSTYPE}"
  local local_v4 gateway_v4
  local rc

  make_bsd_shims "${dir}"
  OSTYPE="darwin24"
  PATH="${dir}:${PATH}"

  # The base64 stand-in refuses "-d", so passing here means the "-D" arm did the work
  assert_text_helpers "darwin"
  assert_pubkey "darwin"

  __host_route_v4 "local_v4" "gateway_v4"
  assert_eq "darwin: route source address" "192.168.7.22" "${local_v4}"
  assert_eq "darwin: route gateway" "192.168.7.1" "${gateway_v4}"

  # The bug this was written for: a "ping" that will not take an IPv6 literal has not
  # measured anything, and must not be reported as "this host has no IPv6"
  __host_has_v6; rc=$?
  assert_rc "darwin: ping without IPv6 reads as untested" 2 "${rc}"

  cp "${dir}/ping6-up" "${dir}/ping6"
  __host_has_v6; rc=$?
  assert_rc "darwin: ping6 that answers reads as reachable" 0 "${rc}"

  cp "${dir}/ping6-down" "${dir}/ping6"
  __host_has_v6; rc=$?
  assert_rc "darwin: ping6 that fails reads as unreachable" 1 "${rc}"
  rm -f "${dir}/ping6"

  # Without the Command Line Tools, macOS "python3" is a stub that opens an installer window.
  # With openssl unable to help either, the key is simply not available - and nothing pops up.
  cp "${dir}/openssl-broken" "${dir}/openssl"
  assert_eq "darwin: no key rather than an Xcode installer" "" \
    "$(__enr_pubkey "$(__enr_to_hex "${fixture_enr}")")"
  rm -f "${dir}/openssl"

  PATH="${saved_path}"
  OSTYPE="${saved_ostype}"
}


test_fixtures() {
  local local_v4 gateway_v4
  local rc

  # shellcheck source=/dev/null
  if ! ETHD_SOURCE_ONLY=1 source ./ethd; then
    fail "ethd can be sourced without running a command"
    return 0
  fi
  set +eEuo pipefail  # "ethd" turns these on; this script is deliberately without them
  pass "ethd can be sourced without running a command"

  echo
  echo "--- as this host is ($(uname -s)) ---"
  assert_text_helpers "native"
  assert_pubkey "native"

  # An openssl that fails sends __enr_pubkey down its python3 path. Both must agree.
  if type -P python3 >/dev/null 2>&1; then
    local shimdir="${tmpdir}/noopenssl"
    mkdir -p "${shimdir}"
    printf '#!/bin/sh\nexit 1\n' > "${shimdir}/openssl"
    chmod +x "${shimdir}/openssl"
    assert_eq "native: python3 reads the same key as openssl" "${fixture_pubkey} python3" \
      "$(PATH="${shimdir}:${PATH}" __enr_pubkey "$(__enr_to_hex "${fixture_enr}")")"
  else
    echo "SKIP - no python3 on this host, cannot check the fallback path"
  fi

  # The values cannot be pinned - a runner's address is not ours to know - but the shape can,
  # and on macOS this is the only check that reads real "route -n get" and "ipconfig getifaddr"
  # output. The Darwin pass below shims both, so it cannot stand in for this.
  __host_route_v4 "local_v4" "gateway_v4"
  if [[ -z "${gateway_v4}" || "${gateway_v4}" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
    pass "native: route gateway is an address or nothing"
  else
    fail "native: route gateway is an address or nothing - got \"${gateway_v4}\""
  fi
  # A CI runner always has a default route, so there the parse either worked or it did not.
  # Anywhere else an empty answer is a fair thing for a host to have.
  if [[ -n "${CI:-}" ]]; then
    assert_true "native: a default route was found" test -n "${gateway_v4}"
    assert_true "native: a source address was found" test -n "${local_v4}"
  fi
  __host_has_v6; rc=$?
  if [[ "${rc}" -le 2 ]]; then
    pass "native: IPv6 check answers 0, 1 or 2 - got ${rc}"
  else
    fail "native: IPv6 check answers 0, 1 or 2 - got ${rc}"
  fi

  # What this host actually is. None of it can be asserted - a runner may have no IPv6, and
  # which base64 spelling works is the host's business - but a macOS run that prints "ping6
  # none" or answers "2 (untested)" with a ping6 present has something worth looking into,
  # and that cannot be seen from a pass/fail line.
  echo
  echo "  this host reported:"
  echo "    uname        $(uname -sr)"
  echo "    bash         ${BASH_VERSION}"
  if printf 'Zg==\n' | base64 -d >/dev/null 2>&1; then
    echo "    base64       decodes with -d"
  elif printf 'Zg==\n' | base64 -D >/dev/null 2>&1; then
    echo "    base64       decodes with -D, the BSD spelling"
  else
    echo "    base64       decodes with neither -d nor -D, so openssl did it"
  fi
  echo "    ping6        $(type -P ping6 || echo none)"
  echo "    host route   src ${local_v4:-none} via ${gateway_v4:-none}"
  case "${rc}" in
    0) echo "    host IPv6    0 (reachable)";;
    1) echo "    host IPv6    1 (unreachable)";;
    *) echo "    host IPv6    2 (untested - ping could not be asked)";;
  esac

  echo
  echo "--- with the Darwin branches forced ---"
  darwin_pass
}


case "${mode}" in
  offline) test_offline;;
  online) test_online;;
  fixtures) test_fixtures;;
  *)
    echo "Call with \"offline\", \"online\" or \"fixtures\""
    exit 1
    ;;
esac

echo
if [[ "${failures}" -gt 0 ]]; then
  echo "${failures} port-check assertion(s) failed"
  exit 1
fi
echo "All port-check ${mode} assertions passed"
