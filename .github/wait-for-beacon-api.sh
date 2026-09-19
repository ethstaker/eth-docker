#!/usr/bin/env bash
# Call with a compose service, its Beacon API port, and how many seconds to wait for.
# Polls until the consensus client answers /eth/v1/node/identity, then prints how long
# that took - the number to size the deadline by. CL_REST_PORT is not published to the
# host in a cl-only deployment, so the probe runs inside the container.

service="$1"
port="$2"
deadline="$3"

start="$(date +%s)"
elapsed=0

while [[ "${elapsed}" -lt "${deadline}" ]]; do
  if docker compose exec -T "${service}" \
      sh -c "curl -sf http://localhost:${port}/eth/v1/node/identity" >/dev/null 2>&1; then
    echo "${service} answered /eth/v1/node/identity after ${elapsed} seconds"
    exit 0
  fi
  sleep 5
  elapsed="$(( $(date +%s) - start ))"
done

echo "${service} did not answer /eth/v1/node/identity within ${deadline} seconds"
docker compose ps "${service}"
docker compose logs "${service}"
exit 1
