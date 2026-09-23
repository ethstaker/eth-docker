#!/usr/bin/env bash
# Call with how many seconds to wait for. Polls "ethd keys" until the keymanager API answers,
# then prints how long that took. Some validator clients only open the keymanager port once
# their beacon node is reachable, so this goes through ethd rather than probing a port.

deadline="${1:-300}"

start="$(date +%s)"
elapsed=0

while [[ "${elapsed}" -lt "${deadline}" ]]; do
  out="$(./ethd keys list 2>&1 </dev/null)"
  exitstatus=$?
  if [[ "${exitstatus}" -eq 0 && "${out}" =~ (loaded\ into|No\ keys\ loaded) ]]; then
    echo "The keymanager API answered after ${elapsed} seconds"
    exit 0
  fi
  sleep 10
  elapsed="$(( $(date +%s) - start ))"
done

echo "The keymanager API did not answer within ${deadline} seconds. Last output:"
echo "${out}"
docker compose ps
docker compose logs --tail 200
exit 1
