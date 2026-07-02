#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R user:user /var/lib/nimbus
  exec gosu user docker-entrypoint.sh "$@"
fi

# accommodate comma separated list of consensus nodes
nodes=$(echo "${CL_NODE}" | tr ',' ' ')
__beacon_urls=()
for node in ${nodes}; do
  __beacon_urls+=("--beacon-api-url=${node}")
done

# accommodate comma separated list of RPC URLs
urls=$(echo "${RPC_URLS}" | tr ',' ' ')
__rpc_urls=()
for url in ${urls}; do
  __rpc_urls+=("--execution-api-url=${url}")
done

while true; do
  for node in ${nodes}; do
    if curl -s -m 5 -o /dev/null -w "%{http_code}" "${node}/eth/v1/node/health" | grep -q "^[23]"; then
      echo "Consensus Layer node is up, fetching trusted block root"
      break 2
    fi
  done
  echo "Waiting for Consensus Layer node to be reachable..."
  sleep 5
done

if ! response=$(curl -s -f -m 30 "${node}/eth/v1/beacon/headers/finalized"); then
  echo "Failed to fetch trusted block root from ${node}"
  echo "Please verify it's reachable"
  sleep 30
  exit 1
fi

root=$(echo "${response}" | jq -r '.data.root')

# Guard against empty or "null" results from jq
if [[ -z "${root}" || "${root}" == "null" ]]; then
  echo "Error: Received invalid data structure from ${node}"
  echo "Received ${response}, which does not contain \".data.root\""
  sleep 30
  exit 1
fi

__trusted_root="--trusted-block-root=${root}"
i=0
# Verified proxy can get "stuck" if light client bootstrap isn't ready. Check for it here
while true; do
  if curl -s -f -m 30 "${node}/eth/v1/beacon/light_client/bootstrap/${root}" &> /dev/null; then
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
      echo "Restarting"
      exit 0
    else
      echo "Waiting for Consensus Layer node to have light client bootstrap data..."
      sleep 5
    fi
  fi
done

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" "${__beacon_urls[@]}" "${__rpc_urls[@]}" ${__trusted_root} ${PROXY_EXTRAS}
