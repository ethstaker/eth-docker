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
