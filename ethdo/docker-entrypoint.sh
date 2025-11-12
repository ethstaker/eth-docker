#!/bin/bash
set -Eeuo pipefail

# This will be started as root, so the generated files can be copied when done

# Find --uid if it exists, parse and discard. Used to chown after.
# Ditto --folder, since this now copies we need to parse it out
__args=()
__uid=1000
__sending=0
foundu=0

for var in "$@"; do
  if [[ "${var}" = '--uid' ]]; then
    foundu=1
    continue
  fi
  if [[ "${foundu}" -eq 1 ]]; then
    foundu=0
    if ! [[ "${var}" =~ ^[0-9]+$ ]] ; then
      echo "error: Passed user ID is not a number, ignoring"
      continue
    fi
    __uid="${var}"
    continue
  fi
  __args+=( "${var}" )
done

if [[ "$*" =~ "validator credentials set" && ! "$*" =~ "--prepare-offline" ]]; then
  if [[ -f /app/.eth/ethdo/change-operations.json ]]; then
    __sending=1
    cp /app/.eth/ethdo/change-operations.json /app
    chown ethdo:ethdo /app/change-operations.json
    echo "Scanning addresses: "
    address=$(jq -r .[0].message.to_execution_address < /app/change-operations.json)
    echo "${address}"
    count=$(jq '. | length' < /app/change-operations.json)
    addresses=$(jq -r .[].message.to_execution_address < /app/change-operations.json)
    # Check whether they're all the same
    unique=1
    while IFS= read -r check_address; do
      if ! [[ "${address}" =~ ${check_address} ]]; then
        ((unique++))
        address="${address} ${check_address}"
        echo "${check_address}"
      fi
    done <<< "${addresses}"
    echo

    if [[ "${unique}" -eq 1 ]]; then
      echo "You are about to change the withdrawal address(es) of ${count} validators to Ethereum address ${address}"
      echo "Please make TRIPLY sure that you control this address."
      echo
      read -rp "I have verified that I control ${address}, change the withdrawal address (No/Yes): " yn
      case "${yn}" in
        [Yy][Ee][Ss] ) ;;
        * ) echo "Aborting"; exit 0;;
      esac
    else
      echo "You are about to change the withdrawal addresses of ${count} validators to ${unique} different Ethereum addresses"
      echo "Please make TRIPLY sure that they are all correct."
      echo
      read -rp "I have verified that the addresses are correct, change the withdrawal addresses (No/Yes): " yn
      case "${yn}" in
        [Yy][Ee][Ss] ) ;;
        * ) echo "Aborting"; exit 0;;
      esac
    fi
  else
    echo "No change-operations.json found in ./.eth/ethdo. Aborting."
    exit 0
  fi
fi

if [[ "$*" =~ "--offline" ]]; then
  if [[ ! -f /app/.eth/ethdo/offline-preparation.json ]]; then
    echo "Offline preparation file ./.eth/ethdo/offline-preparation.json not found"
    echo "Please create it, for example with ./ethd keys prepare-address-change, and try again"
    exit 1
  else
    cp /app/.eth/ethdo/offline-preparation.json /app
    chown ethdo:ethdo /app/offline-preparation.json
  fi
else
  # Get just the first CL_NODE
  __args=( "${__args[@]:0:1}" "--connection" "$(cut -d, -f1 <<<"${CL_NODE}")" "${__args[@]:1}" )
fi

set +e
gosu ethdo "${__args[@]}"
exitstatus=$?
if [[ "${__sending}" -eq 1 ]]; then
  if [[ "${exitstatus}" -eq 0 ]]; then
    echo "Change sent successfully"
  else
    echo "Something went wrong when sending the change, error code ${exitstatus}"
  fi
fi
set -e

if [[ "$*" =~ "--prepare-offline" ]]; then
  if [[ "${NETWORK}" = "mainnet" ]]; then
    butta="https://beaconcha.in"
  else
    butta="https://${NETWORK}.beaconcha.in"
  fi
  cp -p /app/offline-preparation.json /app/.eth/ethdo/
  chown "${__uid}":"${__uid}" /app/.eth/ethdo/offline-preparation.json
  echo "The preparation file has been copied to ./.eth/ethdo/offline-preparation.json"
  echo "It contains a list of all validators on chain, $(jq .validators[].index </app/.eth/ethdo/offline-preparation.json | wc -l) in total"
  echo "You can verify that this matches the total validator count at ${butta}/validators"
fi
