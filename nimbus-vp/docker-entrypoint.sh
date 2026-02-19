#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R user:user /var/lib/nimbus
  exec gosu user docker-entrypoint.sh "$@"
fi


while true; do
  if curl -s -m 5 "${CL_NODE}" &> /dev/null; then
    echo "Consensus Layer node is up, fetching trusted block root"
    break
  else
    echo "Waiting for Consensus Layer node to be reachable..."
    sleep 5
  fi
done

set +e
  root=$(curl -s -f -m 30 "${CL_NODE}/eth/v1/beacon/headers/finalized" | jq -r '.data.root')
  exitstatus=$?
set -e

if [[ "${exitstatus}" -ne 0 ]]; then
  echo "Failed to fetch trusted block root from ${CL_NODE}"
  echo "Please verify it's reachable"
  sleep 30
  exit 1
fi

__trusted_root="--trusted-block-root=${root}"
i=0
# Verified proxy can get "stuck" if light client bootstrap isn't ready. Check for it here
while true; do
  if curl -s -f -m 30 "${CL_NODE}/eth/v1/beacon/light_client/bootstrap/${root}" &> /dev/null; then
    echo "Consensus Layer node has light client bootstrap available, starting Nimbus Verified Proxy"
    break
  else
    ((++i))
    if [[ "$i" -eq 4 ]]; then
      echo "Failed to get light client bootstrap data four times in a row. Waiting for epoch switchover to try with fresh block root"
      secs=370  # Plus the 15 we already waited, 385. Epoch is 384
      while [ $secs -gt 0 ]; do
       echo "Waiting for $secs seconds"
       sleep 10
       ((secs -= 10)) || true  # To protect against "falsy" evaluation when secs==10, in some version of bash
      done
      exit 1
    else
      echo "Waiting for Consensus Layer node to have light client bootstrap data..."
      sleep 5
    fi
  fi
done

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${__trusted_root}
