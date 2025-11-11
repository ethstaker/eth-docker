#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ! -f /var/lib/lighthouse/validators/api-token.txt ]]; then
  echo "Validator client API token not found. Waiting 30s before restarting."
  sleep 30
  exit 1
fi

API_TOKEN=$(cat /var/lib/lighthouse/validators/api-token.txt)
export API_TOKEN

# In case there are multiple consensus nodes, use the first one
export BEACON_URL=${BEACON_URL%%,*}

echo "Log into Siren at https://my-node-ip/${SIREN_PORT} with password ${SESSION_PASSWORD}"
exec /app/docker-assets/docker-entrypoint.sh
