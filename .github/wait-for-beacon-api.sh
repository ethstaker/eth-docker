#!/usr/bin/env bash
# Call with a compose service, its Beacon API port, and how many seconds to wait for.
# Polls until the consensus client answers /eth/v1/node/identity, then prints how long
# that took - the number to size the deadline by. CL_REST_PORT is not published to the
# host in a cl-only deployment, so the probe shares the service's network namespace and
# asks localhost. It runs in its own curl container, because not every client image ships curl.

service="$1"
port="$2"
deadline="$3"
curl_image=curlimages/curl:8.22.0

if ! docker pull -q "${curl_image}" >/dev/null; then
  echo "Could not pull ${curl_image}"
  exit 1
fi

start="$(date +%s)"
elapsed=0

while [[ "${elapsed}" -lt "${deadline}" ]]; do
  # Empty until compose has created the container
  container="$(docker compose ps -q "${service}")"
  if [[ -n "${container}" ]] && docker run --rm --network "container:${container}" "${curl_image}" \
      -sf -m 5 "http://localhost:${port}/eth/v1/node/identity" >/dev/null 2>&1; then
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
