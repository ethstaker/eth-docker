#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f /erpc.ts ]]; then
  echo "eRPC configuration ./erpc/erpc.ts is missing"
  echo "Run \"./ethd update\", or copy ./erpc/erpc.ts.sample to ./erpc/erpc.ts"
  sleep 30
  exit 1
fi

# erpc.yaml serves the chain at the root path, which needs the chain ID
case "${NETWORK}" in
  mainnet) CHAIN_ID=1 ;;
  sepolia) CHAIN_ID=11155111 ;;
  hoodi) CHAIN_ID=560048 ;;
  *)
    while true; do
      if response=$(curl -s -f -m 5 -H "Content-Type: application/json" \
          -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' "${EL_RPC_NODE}"); then
        hex=$(echo "${response}" | jq -r '.result // empty')
        if [[ "${hex}" =~ ^0x[0-9a-fA-F]+$ ]]; then
          CHAIN_ID=$((hex))
          echo "Execution Layer node reports chain ID ${CHAIN_ID}"
          break
        fi
      fi
      echo "Waiting for Execution Layer node at ${EL_RPC_NODE} to report its chain ID..."
      sleep 5
    done
    ;;
esac
export CHAIN_ID

# erpc.ts skips empty entries and ones that still hold the placeholder from default.env
__has_remote=0
__urls="${RPC_URLS:-}"
for url in ${__urls//,/ }; do
  if [[ "${url}" != *"<ApiKey>"* ]]; then
    __has_remote=1
    break
  fi
done
if [[ "${__has_remote}" -eq 0 ]]; then
  echo "No remote RPC providers in RPC_URLS, eRPC will only use the local execution client"
fi

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${PROXY_EXTRAS:-}
