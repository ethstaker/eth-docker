## ethd config test paths

Only the paths that have been touched in a PR need to be tested

Test legacy detection
`CORE_FILES=teku-allin1.yml:geth.yml`

Test config without `.env` present

Test config with custom network

Test IPv6 is detected on a dual-stack machine

Test absence of IPv6 is detected on an IPv4-only machine

Test with Graffiti

Test default Graffiti queried and used/not used if Graffiti is empty

Test `CUSTOM_FILES=contributoor.yml` is preserved

Test without MEV

Test with MEV

Test relays missing from `MEV_RELAYS` are off by default in the query when running `./ethd config` again
Test with Flashbots, Titan Global, Titan Regional, Ultrasound, Ultrasound Filtered
On Hoodi and Mainnet

Test that MEV build factor 95 means no factor query or speedtest

Test that MEV build factor "empty, 90 or 100" means factor query and speedtest
Test Grafana with rootful Docker and active UFW: verify the node-exporter rules are added using `NODE_EXPORTER_PORT`
Test Grafana with rootful Docker and existing node-exporter UFW rules: verify no duplicate rules are added
Test Grafana with rootless Docker or Podman: verify no node-exporter UFW rules are added
Test Grafana with inactive or unavailable UFW: verify configuration continues without adding rules

Test all networks once, verify the expected choices are seen, configure a node on each
Test Nimbus on Gnosis, verify that `Dockerfile.sourcegnosis` was configured for it

Test that Reth on mainnet with history expiry prompts for snapshot

Test node and Lido CSM with Caplin, prompts for VC

Test Lido CSM without `.env` present, and key generation on Hoodi
Ditto with existing `.env`
Test Lido CSM without `.env` present, and key generation on mainnet
Test that disabled relays during Lido CSM config will be default-off
during the next run of Lido CSM config
Test for Flashbots, Titan (Global and Regional on mainnet), Ultrasound, Ultrasound Filtered

Delete SSV secrets in `ssv-config`
Test SSV with SSV Node on Hoodi without DKG
Verify that secrets get created
Verify `ssv-config/config.yaml` has the right network in it
Verify that `.env` has all Hoodi relays for SSV

Keep SSV secrets in place
Test SSV with SSV Node on Hoodi with DKG
Verify DKG shows the public key, and the operator ID workflow works
Verify the Operator ID was written into `ssv-config/dkg-config.yaml`

Delete SSV secrets in `ssv-config`
Test SSV with Anchor on mainnet with Reth and with DKG
Verify that secrets get created
Verify `ssv-config/config.yaml` has the right network in it
Verify DKG shows the public key, and the operator ID workflow works
Verify the Operator ID was written into `ssv-config/dkg-config.yaml`
Observe that SSV on mainnet queries for history expiry, and Reth snapshot
Verify that `.env` has all mainnet relays for SSV

Test RPC

Test validator on gnosis, ephemery, hoodi and mainnet
Test Nimbus on Gnosis, verify that `Dockerfile.sourcegnosis` was configured for it
Verify that `deposit-cli.yml` is added to `CORE_FILES` on Hoodi only
Test with and without MEV Boost and verify that `MEV_BOOST` is set accordingly

Remove `.env`
Test rocket and verify that the remote beacon is prompted as `http://eth2:5052`
Set `DOCKER_EXT_NETWORK=foo`
Set `CL_NODE=http://node.example.com`
Test rocket and verify `ext-network.yml` got added, and `DOCKER_EXT_NETWORK=rocketpool_net`
Verify that remote beacon prompt kept the manual `CL_NODE`
Test that on Hoodi and Mainnet, verify that `deposit-cli.yml` is added to `CORE_FILES` on Hoodi only

Lido Obol can't be tested without a live Obol cluster, but run through it as far as possible to rule out obvious issues

Lido SSV is identical to SSV

## Multi-user test paths

tests/test-multiuser.sh encodes the below tests

Tests the code with directory ownership `eve:test-ethd-admins`; `eve`, `alice` and `bob` part of the `test-ethd-admins` group, `alice` part
of the `sudo` group and `bob` not, and setgid set or not on the directory, `g+s` and `g-s`. `charlie` is not in `test-ethd-admins`, and should fail
before `ethd` can sudo because the user cannot enter the directory.

Also test a regular `alice:alice` setup of eth-docker, and that the code works well in that case.

Test scenarios
- dir `alice:alice` `g-s` and 775/664 permissions, `alice` umask 022
- dir `alice:alice` `g-s` and 700/600 permissions, `alice` with umask 077
- dir `alice:alice` `g-s` and 775/664 permissions, `root` umask 022
- dir `eve:test-ethd-admins` `g-s` and 775/664 permissions, `alice` with umask 022
- dir `eve:test-ethd-admins` `g+s` and 775/664 permissions, `alice` with umask 022
- dir `eve:test-ethd-admins` `g-s` and 770/660 permissions, `alice` with umask 077
- dir `eve:test-ethd-admins` `g+s` and 770/660 permissions, `alice` with umask 077
- dir `eve:test-ethd-admins` `g-s` and 775/664 permissions, `bob` umask 022 (can't sudo)
- dir `eve:test-ethd-admins` `g+s` and 775/664 permissions, `bob` umask 022 (can't sudo)
- dir `eve:test-ethd-admins` `g-s` and 770/660 permissions, `bob` umask 077 (can't sudo) after `alice` first runs
- dir `eve:test-ethd-admins` `g+s` and 770/660 permissions, `bob` umask 077 (can't sudo) after `alice` first runs
- dir `eve:test-ethd-admins` `g-s` and 775/664 permissions, `root` umask 022
- dir `eve:test-ethd-admins` `g-s` and 770/660 permissions, `bob` umask 077 (can't sudo) without `alice` first run, should fail
- dir `eve:test-ethd-admins` `g-s` and 775/664 permissions, `charlie` (can sudo), should fail because user can't cd in

- `./ethd space` and check `.env` ownership and permissions. Should be `user:user` when solo, `user:owner-group` when the running user creates or updates it in a group-writable directory, `previous-user:owner-group` when another group member can already write it, and `owner:owner-group` when the running user's group doesn't have write rights (invoke sudo)
- Likewise config files, same ownership expectations, and o+r permissions
- `./ethd space` a second time, no message that `.env` permissions are being fixed should be seen
- Ditto check ownership and permissions of bind-mounted files in alloy, alloy-obol, prometheus, loki, tempo, ssv-config. They need to be `other` readable.

## ethd port-check

The `Test ethd port-check` workflow, label `check-ethd-port-check`, already covers part of this
list on Ubuntu: option parsing, the unreachable-client path, the `Peer ID` and
`Public key` rows, the openssl and python3 key paths agreeing, no `enr:` appearing in the
printed probe commands, and the boundaries between the three output tiers - plain stops before
the guidance and points at `--troubleshoot`, `--troubleshoot` prints the guidance and the probe
sections but no diagnostics, `--debug` prints both. It runs Nimbus against hoodi with no inbound,
so everything below that needs real peers, a NAT, IPv6, or a specific client is still manual.
The Teku and Grandine direction-split check in particular cannot be automated: a freshly started
node has no peers, and a table of all zeroes is mirrored whether or not the split works.

- `./ethd port-check --troubleshoot` on a node with no inbound peers: the discv5 and QUIC probe commands print, and both run clean when pasted on another machine with Docker
- `./ethd port-check --troubleshoot` on a node behind port-translating NAT: the discv5 probe command must carry `CL_P2P_PORT`, not the port the ENR advertises, and the report must say why the two differ
- `./ethd port-check --troubleshoot` on a dual-stack node: the IPv6 pair prints as well, creating an `ethd-v6-probe` docker network instead of using `--network host`
- `./ethd port-check --troubleshoot` on an IPv4-only node: the `IPv6 - test incoming ports are open` banner must not stand alone. It says there is no global IPv6 address to test instead
- `./ethd port-check` on Teku or Grandine: the inbound and outbound rows must not be identical. Both clients ignore the `state` and `direction` query parameters on `/eth/v1/node/peers`, so a mirrored table means the direction split regressed to trusting the API's filters
- `./ethd port-check` on any node: the `Peer ID` and `Public key` rows print, healthy or not. The key must match the one geth reads out of the same ENR: `docker run --rm ethereum/client-go:alltools-latest devp2p enrdump <enr> | grep URLv4`
- `./ethd port-check --troubleshoot` with inbound not working: no command it prints may contain an `enr:` string, and the closing note about blanking out the IP must appear. Only the `--debug` diagnostics may carry the ENR
- `./ethd port-check --debug` on a host without `openssl`: the python3 path must produce the same public key. Without `python3` either, the discv5 command falls back to carrying the ENR and the closing note does not print
- `./ethd port-check` with any option other than `--troubleshoot` or `--debug` exits 1 with `Error: Unknown option:`
- `./ethd port-check` with no flag: the output ends at the peers table. When inbound is 0 or unmeasurable it also names that, and points at `--troubleshoot` - a pointer that must not print when `--troubleshoot` was the flag that got you there
- `./ethd port-check --troubleshoot`: adds the guidance, the `IPv4` probe section and the `IPv6` one, and nothing else. `--debug` adds the diagnostics block on top of that
- On a node whose inbound works, `--troubleshoot` prints a preamble saying so, then the guidance verbatim
- On a client that does not report peer direction - Teku or Grandine - the preamble names that rather than claiming inbound works, and the `--debug` `Peers` row says `direction not reported`. No `bash: [[: ?: arithmetic syntax error` may appear anywhere in the output: `inbound` is `?` there, not a number
- The `--debug` `Beacon API` row says `throwaway container` on Lodestar, whose image ships neither wget nor curl, and `docker compose exec` elsewhere. `Public key` names openssl or python3, whichever read it
- With the consensus client unreachable, `--troubleshoot` prints both routes it tried before exiting 1
- The `--troubleshoot` guidance must tell the reader to probe from a public IP address and warn that a probe sourced from an RFC1918 or Docker-bridge address can be dropped silently by the consensus client. Verified against Teku 26.8.0: it answers public peers but never replies to a discv5 PING sourced from 172.18.0.0/16, with no ICMP and nothing in its debug log, so the probe reads as a closed port on a port that is open
- Cross-check the counts against the client's own gauge, which is the independent source of truth: `./ethd cmd exec consensus sh -c 'wget -qO- http://localhost:8008/metrics' | grep beacon_peer_count` for Teku, the equivalent gauge for other clients

### macOS

`./.github/test-port-check.sh fixtures` runs on both Ubuntu and macOS in the same workflow, needs
neither Docker nor a running client, and takes about a second. It sources `ethd` with
`ETHD_SOURCE_ONLY=1` and drives the helpers directly: the ENR decode, the address and port
formatting, the CGNAT and private-address classification, the peer counting, and the public key.
It then runs the whole set a second time with `OSTYPE` forced to `darwin` and stand-ins for the
BSD tools first on `PATH`, so the Darwin branches are walked on a Linux runner too.

Its two ENRs are properly signed and carry documentation-range addresses. To confirm for yourself
that the expected values in the script are the right ones, paste either into
<https://enr-viewer.com/>, or run
`docker run --rm ethereum/client-go:alltools-latest devp2p enrdump <enr>`, which prints `INVALID`
for a record whose signature does not hold up.

What that cannot tell you is how the real BSD tools behave - only that our branches handle the
output we believe they produce. On an actual Mac, still check:

- `./ethd port-check --debug` on a Mac behind NAT: `Host route` must name a real `src` and
  `via`, from `route -n get` and `ipconfig getifaddr`, and the `IPv4` row must say `(behind NAT)`.
  `Host route` is a diagnostics row, so `--troubleshoot` alone will not show it
- `./ethd port-check --debug` on a Mac with working IPv6: `Dual-stack` must not say `this host has
  no IPv6 connectivity`, and `Host IPv6` must say `reachable` rather than `unreachable` or
  `untested`
- Same on a Mac with no IPv6: `Host IPv6` must say `unreachable`, not `untested`
- On a Mac without the Xcode Command Line Tools: no installer window may appear. If `openssl` also
  cannot read the key, the `Public key` row says so and the discv5 command falls back to the ENR
- On macOS before Ventura, whose `base64` has no `-d`: every ENR-derived row must still print
- On Lodestar or Caplin, which take `__cl_api_query`'s throwaway-container path: the `--debug`
  `Beacon API` row must name the compose network, which means `docker compose config` was parsed
  with `gawk`
