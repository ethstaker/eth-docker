#!/usr/bin/env bash

service="$1"

containerID="$(docker compose ps -q "${service}")"

restart_count="$(docker inspect --format '{{ .RestartCount }}' "$containerID")"
is_running="$(docker inspect --format '{{ .State.Running }}' "$containerID")"

if [[ "${is_running}" != "true" || "${restart_count}" -gt 1 ]]; then
  echo "${service} is either not running or continuously restarting"
  docker compose ps "${service}"
  docker compose logs "${service}"
  exit 1
else
  echo "${service} is running"
  docker compose ps "${service}"
  exit 0
fi
