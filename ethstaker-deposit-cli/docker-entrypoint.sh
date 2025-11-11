#!/bin/bash
set -Eeuo pipefail

# This will be started as root, so the generated files can be copied when done

# Find --uid if it exists, parse and discard. Used to chown after.
# Ditto --folder, since this now copies we need to parse it out
ARGS=()
foundu=0
foundf=0
foundnonint=0
uid=1000
folder="validator_keys"
for var in "$@"; do
  if [[ "$var" = '--uid' ]]; then
    foundu=1
    continue
  fi
  if [[ "$var" = '--folder' ]]; then
    foundf=1
    continue
  fi
  if [[ "$var" = '--non_interactive' ]]; then
    foundnonint=1
    continue
  fi
  if [[ "$foundu" -eq 1 ]]; then
    foundu=0
    if ! [[ "$var" =~ ^[0-9]+$ ]] ; then
      echo "error: Passed user ID is not a number, ignoring"
      continue
    fi
    uid="$var"
    continue
  fi
  if [[ "$foundf" -eq 1 ]]; then
    foundf=0
    folder="$var"
    continue
  fi
  ARGS+=("$var")
done

for i in "${!ARGS[@]}"; do
  if [[ "${ARGS[$i]}" = '/app/staking_deposit/deposit.py' ]]; then
    if [[ "$foundnonint" -eq 1 ]]; then
      # the flag should be before the command
      ARGS=("${ARGS[@]:0:$i+1}" "--non_interactive" "${ARGS[@]:$i+1}")
    fi
    break
  fi
done

gosu depcli "${ARGS[@]}"

if [[ "$*" =~ "generate-bls-to-execution-change" ]]; then
  cp -rp /app/bls_to_execution_changes /app/.eth/
  chown -R "$uid":"$uid" /app/.eth/bls_to_execution_changes
  echo "The change files have been copied to ./.eth/bls_to_execution_changes"
else
  mkdir -p /app/.eth/"$folder"
  cp -p /app/validator_keys/* /app/.eth/"$folder"/
  chown -R "$uid":"$uid" /app/.eth/"$folder"
  echo "The generated files have been copied to ./.eth/$folder/"
fi
