#!/bin/bash
set -Eeuo pipefail

# Copy keys, then restart script without root
if [[ "$(id -u)" -eq 0 ]]; then
  mkdir /keys
  cp -r /validator_keys/* /keys/
  chown lhvalidator:lhvalidator /keys/*
  exec gosu lhvalidator "${BASH_SOURCE[0]}" "$@"
fi

nodes=$(echo "${CL_NODE}" | tr ',' ' ')
for node in ${nodes}; do
  if curl -s -m 5 -o /dev/null -w "%{http_code}" "${node}" | grep -q "^[23]"; then
    node_reachable=1
    break
  fi
done

if [[ "${node_reachable}" -eq 0 ]]; then
  echo "No consensus client node is reachable via any URL in ${CL_NODE}"
  sleep 30
  exit 1
fi

# Insert the --beacon-node after the 4th position
set -- "${@:1:4}" "--beacon-node" "${node}" "${@:5}"

exec "$@"
