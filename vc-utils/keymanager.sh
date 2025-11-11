#!/usr/bin/env bash

call_api() {
    set +e
    if [[ -z "${__api_data}" ]]; then
        if [[ "${__api_tls}" = "true" ]]; then
            __code=$(curl -k -m 60 -s --show-error -o /tmp/result.txt -w "%{http_code}" -X "${__http_method}" -H "Accept: application/json" -H "Authorization: Bearer $__token" \
                https://"${__api_container}":"${__api_port}"/"${__api_path}")
        else
            __code=$(curl -m 60 -s --show-error -o /tmp/result.txt -w "%{http_code}" -X "${__http_method}" -H "Accept: application/json" -H "Authorization: Bearer $__token" \
                http://"${__api_container}":"${__api_port}"/"${__api_path}")
        fi
    else
        if [[ "${__api_tls}" = "true" ]]; then
            __code=$(curl -k -m 60 -s --show-error -o /tmp/result.txt -w "%{http_code}" -X "${__http_method}" -H "Accept: application/json" -H "Content-Type: application/json" -H "Authorization: Bearer $__token" \
                --data "${__api_data}" https://"${__api_container}":"${__api_port:-7500}"/"${__api_path}")
        else
            __code=$(curl -m 60 -s --show-error -o /tmp/result.txt -w "%{http_code}" -X "${__http_method}" -H "Accept: application/json" -H "Content-Type: application/json" -H "Authorization: Bearer $__token" \
                --data "${__api_data}" http://"${__api_container}":"${__api_port:-7500}"/"${__api_path}")
        fi
    fi
    __return=$?
    if [[ "${__debug}" -eq 1 ]]; then
      echo "Called ${__api_container}:${__api_port}/${__api_path} with method ${__http_method} and the following data"
      if [[ -n "${__api_data}" ]]; then
        echo "${__api_data}"
      else
        echo "This was a call without data"
      fi
      echo "The token was ${__token} from ${__token_file}"
      echo "The return code was ${__code} and if we had result data, here it is."
      if [[ -f /tmp/result.txt ]]; then
        cat /tmp/result.txt
        echo
      fi
    fi

    if [[ $__return -ne 0 ]]; then
        echo "Error encountered while trying to call the keymanager API via curl."
        echo "Please make sure the ${__service} service is up and its logs show the key manager API, port ${__api_port}, enabled."
        echo "Error code $__return"
        exit $__return
    fi
    if [[ -f /tmp/result.txt ]]; then
        __result=$(cat /tmp/result.txt)
    else
        echo "Error encountered while trying to call the keymanager API via curl."
        echo "HTTP code: ${__code}"
        exit 1
    fi
}

call_cl_api() {
  set +e
  if [[ -z "${__api_data}" ]]; then
    __code=$(curl -m 60 -s --show-error -o /tmp/result.txt -w "%{http_code}" -X "${__http_method}" -H "Accept: application/json" \
        "${CL_NODE}"/"${__api_path}")
  else
    __code=$(curl -m 60 -s --show-error -o /tmp/result.txt -w "%{http_code}" -X "${__http_method}" -H "Accept: application/json" -H "Content-Type: application/json" \
        --data "${__api_data}" "${CL_NODE}"/"${__api_path}")
  fi
  __return=$?
  if [[ $__return -ne 0 ]]; then
    echo "Error encountered while trying to call the consensus client REST API via curl."
    echo "Please make sure the ${CL_NODE} URL is reachable."
    echo "Error code $__return"
    exit $__return
  fi
  if [[ -f /tmp/result.txt ]]; then
    __result=$(cat /tmp/result.txt)
  else
    echo "Error encountered while trying to call the consensus client REST API via curl."
    echo "HTTP code: ${__code}"
    exit 1
  fi
}

get-token() {
set +e
  __token=$(tail -n 1 "${__token_file}")
  __return=$?
  if [[ $__return -ne 0 ]]; then
    echo "Error encountered while trying to get the keymanager API token."
    echo "Please make sure the ${__service} service is up and its logs show the key manager API, port ${__api_port}, enabled."
    exit $__return
  fi
  if [[ -z "${__token}" ]]; then
    echo "The keymnanager API token in ${__token_file_client} is empty."
    echo "The token path is relative to the ${__service} container."
    echo "This could happen if the file ends with an empty line, which is a client bug."
    echo "Please report this on Github. Aborting."
    exit 1
  fi
set -e
}

print-api-token() {
    get-token
    echo "${__token}"
}

__check_pubkey() {
  if [[ -z "$1" ]]; then
    echo "Please specify a validator public key"
    exit 0
  fi
  if [[ $1 != 0x* ]]; then
    echo "The validator public key has to start with \"0x\""
    exit 0
  fi
  if [[ ${#1} -ne 98 ]]; then
    echo "Wrong length for the validator public key - was it truncated?"
    exit 0
  fi
  if [[ ! $1 =~ ^0x[0-9a-fA-F]+$ ]]; then
    echo "The validator public key needs to be a hexadecimal value starting with 0x"
    exit 0
  fi
}

__check_address() {
  if [[ -z "$1" ]]; then
    echo "Please specify an Ethereum address"
    exit 0
  fi
  if [[ $1 != 0x* ]]; then
    echo "The Ethereum address has to start with \"0x\""
    exit 0
  fi
  if [[ ${#1} -ne 42 ]]; then
    echo "Wrong length for the Ethereum address - was it truncated?"
    exit 0
  fi
  if [[ ! $1 =~ ^0x[0-9a-fA-F]+$ ]]; then
    echo "The Ethereum address needs to be a hexadecimal value starting with 0x"
    exit 0
  fi
}

get-prysm-wallet() {
    if [[ -f /var/lib/prysm/password.txt ]]; then
        echo "The password for the Prysm wallet is:"
        cat /var/lib/prysm/password.txt
    else
        echo "No stored password found for a Prysm wallet."
    fi
}

get-grandine-wallet() {
    if [[ -f /var/lib/grandine/wallet-password.txt ]]; then
        echo "The password for the Grandine wallet is:"
        cat /var/lib/grandine/wallet-password.txt
    else
        echo "No stored password found for a Grandine wallet."
    fi
}

recipient-get() {
    __check_pubkey "${__pubkey}"
    get-token
    __api_path=eth/v1/validator/$__pubkey/feerecipient
    __api_data=""
    __http_method=GET
    call_api
    case $__code in
        200) echo "The fee recipient for the validator with public key $__pubkey is:"; echo "$__result" | jq -r '.data.ethaddress'; exit 0;;
        401) echo "No authorization token found. This is a bug. Error: $(echo "$__result" | jq -r '.message')"; exit 70;;
        403) echo "The authorization token is invalid. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        404) echo "Path not found error. Was that the right pubkey? Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        500) echo "Internal server error. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        *) echo "Unexpected return code $__code. Result: $__result"; exit 1;;
    esac
}

recipient-set() {
    __check_pubkey "${__pubkey}"
    __check_address "${__address}"
    get-token
    __api_path=eth/v1/validator/$__pubkey/feerecipient
    __api_data="{\"ethaddress\": \"$__address\" }"
    __http_method=POST
    call_api
    case $__code in
        202) echo "The fee recipient for the validator with public key $__pubkey was updated."; exit 0;;
        400) echo "The pubkey or address was formatted wrong. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        401) echo "No authorization token found. This is a bug. Error: $(echo "$__result" | jq -r '.message')"; exit 70;;
        403) echo "The authorization token is invalid. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        404) echo "Path not found error. Was that the right pubkey? Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        500) echo "Internal server error. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        *) echo "Unexpected return code $__code. Result: $__result"; exit 1;;
    esac
}

recipient-delete() {
    __check_pubkey "${__pubkey}"
    get-token
    __api_path=eth/v1/validator/$__pubkey/feerecipient
    __api_data=""
    __http_method=DELETE
    call_api
    case $__code in
        204) echo "The fee recipient for the validator with public key $__pubkey was set back to default."; exit 0;;
        401) echo "No authorization token found. This is a bug. Error: $(echo "$__result" | jq -r '.message')"; exit 70;;
        403) echo "A fee recipient was found, but cannot be deleted. It may be in a configuration file. Message: $(echo "$__result" | jq -r '.message')"; exit 0;;
        404) echo "The key was not found on the server, nothing to delete. Message: $(echo "$__result" | jq -r '.message')"; exit 0;;
        500) echo "Internal server error. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        *) echo "Unexpected return code $__code. Result: $__result"; exit 1;;
    esac
}

gas-get() {
    __check_pubkey "${__pubkey}"
    get-token
    __api_path=eth/v1/validator/$__pubkey/gas_limit
    __api_data=""
    __http_method=GET
    call_api
    case $__code in
        200) echo "The execution gas limit for the validator with public key $__pubkey is:"; echo "$__result" | jq -r '.data.gas_limit'; exit 0;;
        400) echo "The pubkey was formatted wrong. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        401) echo "No authorization token found. This is a bug. Error: $(echo "$__result" | jq -r '.message')"; exit 70;;
        403) echo "The authorization token is invalid. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        404) echo "Path not found error. Was that the right pubkey? Error: $(echo "$__result" | jq -r '.message')"; exit 0;;
        500) echo "Internal server error. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        *) echo "Unexpected return code $__code. Result: $__result"; exit 1;;
    esac
}

gas-set() {
    __check_pubkey "${__pubkey}"
    if [[ -z "$__limit" ]]; then
      echo "Please specify a gas limit"
      exit 0
    fi
    if [[ ! $__limit =~ ^[0-9]+$ ]]; then
      echo "The gas limit needs to be a decimal number"
      exit 0
    fi
    get-token
    __api_path=eth/v1/validator/$__pubkey/gas_limit
    __api_data="{\"gas_limit\": \"$__limit\" }"
    __http_method=POST
    call_api
    case $__code in
        202) echo "The gas limit for the validator with public key $__pubkey was updated."; exit 0;;
        400) echo "The pubkey or limit was formatted wrong. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        401) echo "No authorization token found. This is a bug. Error: $(echo "$__result" | jq -r '.message')"; exit 70;;
        403) echo "The authorization token is invalid. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        404) echo "Path not found error. Was that the right pubkey? Error: $(echo "$__result" | jq -r '.message')"; exit 0;;
        500) echo "Internal server error. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        *) echo "Unexpected return code $__code. Result: $__result"; exit 1;;
    esac
}

gas-delete() {
    __check_pubkey "${__pubkey}"
    get-token
    __api_path=eth/v1/validator/$__pubkey/gas_limit
    __api_data=""
    __http_method=DELETE
    call_api
    case $__code in
        204) echo "The gas limit for the validator with public key $__pubkey was set back to default."; exit 0;;
        400) echo "The pubkey was formatted wrong. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        401) echo "No authorization token found. This is a bug. Error: $(echo "$__result" | jq -r '.message')"; exit 70;;
        403) echo "A gas limit was found, but cannot be deleted. It may be in a configuration file. Message: $(echo "$__result" | jq -r '.message')"; exit 0;;
        404) echo "The key was not found on the server, nothing to delete. Message: $(echo "$__result" | jq -r '.message')"; exit 0;;
        500) echo "Internal server error. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        *) echo "Unexpected return code $__code. Result: $__result"; exit 1;;
    esac
}

graffiti-get() {
    __check_pubkey "${__pubkey}"
    get-token
    __api_path=eth/v1/validator/$__pubkey/graffiti
    __api_data=""
    __http_method=GET
    call_api
    case $__code in
        200) echo "The graffiti for the validator with public key $__pubkey is:"; echo "$__result" | jq -r '.data.graffiti'; exit 0;;
        400) echo "The pubkey was formatted wrong. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        401) echo "No authorization token found. This is a bug. Error: $(echo "$__result" | jq -r '.message')"; exit 70;;
        403) echo "The authorization token is invalid. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        404) echo "Path not found error. Was that the right pubkey? Error: $(echo "$__result" | jq -r '.message')"; exit 0;;
        500) echo "Internal server error. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        *) echo "Unexpected return code $__code. Result: $__result"; exit 1;;
    esac
}

graffiti-set() {
    __check_pubkey "${__pubkey}"
    if [[ -z "$__graffiti" ]]; then
      echo "Please specify a graffiti string"
      exit 0
    fi
    if [[ $(echo -n "${__graffiti}" | wc -c) -gt 32 ]]; then
      echo "The graffiti string cannot be longer than 32 characters. Emojis count as 4, each."
      exit 0
    fi
    get-token
    __api_path=eth/v1/validator/$__pubkey/graffiti
    __api_data="{\"graffiti\": \"$__graffiti\" }"
    __http_method=POST
    call_api
    case $__code in
        202) echo "The graffiti for the validator with public key $__pubkey was updated."; exit 0;;
        400) echo "The pubkey or limit was formatted wrong. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        401) echo "No authorization token found. This is a bug. Error: $(echo "$__result" | jq -r '.message')"; exit 70;;
        403) echo "The authorization token is invalid. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        404) echo "Path not found error. Was that the right pubkey? Error: $(echo "$__result" | jq -r '.message')"; exit 0;;
        500) echo "Internal server error. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        *) echo "Unexpected return code $__code. Result: $__result"; exit 1;;
    esac
}

graffiti-delete() {
    __check_pubkey "${__pubkey}"
    get-token
    __api_path=eth/v1/validator/$__pubkey/graffiti
    __api_data=""
    __http_method=DELETE
    call_api
    case $__code in
        204) echo "The graffiti for the validator with public key $__pubkey was set back to default."; exit 0;;
        400) echo "The pubkey was formatted wrong. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        401) echo "No authorization token found. This is a bug. Error: $(echo "$__result" | jq -r '.message')"; exit 70;;
        403) echo "A graffiti was found, but cannot be deleted. It may be in a configuration file. Message: $(echo "$__result" | jq -r '.message')"; exit 0;;
        404) echo "The key was not found on the server, nothing to delete. Message: $(echo "$__result" | jq -r '.message')"; exit 0;;
        500) echo "Internal server error. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        *) echo "Unexpected return code $__code. Result: $__result"; exit 1;;
    esac
}

exit-sign() {
    if [[ -z "${__pubkey}" ]]; then
      echo "Please specify a validator public key to sign an exit message for, or \"all\""
      exit 0
    fi
    if [[ ! "${__pubkey}" = "all" ]]; then
      __check_pubkey "${__pubkey}"
    fi
    __pubkeys=()
    __api_path=eth/v1/keystores
    if [[ "${__pubkey}" = "all" ]]; then
      if [[ "${WEB3SIGNER}" = "true" ]]; then
        __token=NIL
        __vc_api_container=${__api_container}
        __api_container=${__w3s_container}
        __vc_service=${__service}
        __service=web3signer
        __vc_api_port=${__api_port}
        __api_port=${__w3s_port}
        __vc_api_tls=${__api_tls}
        __api_tls=false
      else
        get-token
      fi
      __validator-list-call
      if [[ "$(echo "$__result" | jq '.data | length')" -eq 0 ]]; then
        echo "No keys loaded, cannot sign anything"
        return
      else
        __keys_to_array=$(echo "$__result" | jq -r '.data[].validating_pubkey' | tr '\n' ' ')
# Word splitting is desired for the array
# shellcheck disable=SC2206
        __pubkeys+=( ${__keys_to_array} )
        if [[ "${WEB3SIGNER}" = "true" ]]; then
            __api_container=${__vc_api_container}
            __api_port=${__vc_api_port}
            __api_tls=${__vc_api_tls}
            __service=${__vc_service}
        fi
      fi
    else
      __pubkeys+=( "${__pubkey}" )
    fi

    __skipped=0
    __signed=0
    get-token
    for __pubkey in "${__pubkeys[@]}"; do
      __api_data=""
      __http_method=POST
      __api_path=eth/v1/validator/$__pubkey/voluntary_exit
      call_api
      case $__code in
        200) echo "Signed voluntary exit for validator with public key $__pubkey"; (( __signed+=1 ));;
        400) echo "The pubkey or limit was formatted wrong. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        401) echo "No authorization token found. This is a bug. Error: $(echo "$__result" | jq -r '.message')"; exit 70;;
        403) echo "The authorization token is invalid. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        404)
          echo "Path not found error. The key ${__pubkey} has to be active with an index on the beacon chain to be able to sign an exit message."
          echo "Error: $(echo "$__result" | jq -r '.message')"
          (( __skipped+=1 ))
          continue
          ;;
        500) echo "Internal server error. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        *) echo "Unexpected return code $__code. Result: $__result"; exit 1;;
      esac
      # This is only reached for 200
      __result=$(echo "${__result}" | jq -c '.data')

      echo "${__result}" >"/exit_messages/${__pubkey::10}--${__pubkey:90}-exit.json"
# shellcheck disable=SC2320
      exitstatus=$?
      if [[ "${exitstatus}" -eq 0 ]]; then
        echo "Writing the exit message into file ./.eth/exit_messages/${__pubkey::10}--${__pubkey:90}-exit.json succeeded"
      else
        echo "Error writing exit json to file ./.eth/exit_messages/${__pubkey::10}--${__pubkey:90}-exit.json"
      fi
      echo
    done

    echo "Signed exit messages for ${__signed} keys"
    echo "Skipped ${__skipped} keys because they weren't found or were not active on the beacon chain"
}


exit-send() {
    shopt -s nullglob
    json_files=(/exit_messages/*.json)

    if [[ ${#json_files[@]} -eq 0 ]]; then
        echo "No exit message files found in \"./.eth/exit_messages\"."
        echo "Aborting."
        exit 1
    fi

    for file in "${json_files[@]}"; do
        validator_index=$(jq '.message.validator_index' "$file" 2>/dev/null || true)

        if [[ $validator_index != "null" && -n $validator_index ]]; then
            __api_path=eth/v1/beacon/pool/voluntary_exits
            __api_data="$(cat "${file}")"
            __http_method=POST
            call_cl_api
            case $__code in
                200) echo "Loaded voluntary exit message for validator index $validator_index";;
                400) echo "Unable to load the voluntary exit message. Error: $(echo "$__result" | jq -r '.message')";;
                500) echo "Internal server error. Error: $(echo "$__result" | jq -r '.message')";;
                *) echo "Unexpected return code $__code. Result: $__result";;
            esac
            echo ""
        else
            echo "./.eth/exit_messages/$(basename "$file") is not a pre-signed exit message."
            echo "Skipping."
        fi
    done
}


__validator-list-call() {
    __api_data=""
    __http_method=GET
    call_api
    case $__code in
        200);;
        401) echo "No authorization token found. This is a bug. Error: $(echo "$__result" | jq -r '.message')"; exit 70;;
        403) echo "The authorization token is invalid. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        500) echo "Internal server error. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
        *) echo "Unexpected return code $__code. Result: $__result"; exit 1;;
    esac
}

validator-list() {
    __api_path=eth/v1/keystores
    if [[ "${WEB3SIGNER}" = "true" ]]; then
        __token=NIL
        __vc_api_container=${__api_container}
        __api_container=${__w3s_container}
        __vc_service=${__service}
        __service=web3signer
        __vc_api_port=${__api_port}
        __api_port=${__w3s_port}
        __vc_api_tls=${__api_tls}
        __api_tls=false
    else
        get-token
    fi
    __validator-list-call
    if [[ "$(echo "$__result" | jq '.data | length')" -eq 0 ]]; then
        echo "No keys loaded into ${__service}"
    else
        echo "Validator public keys loaded into ${__service}"
        echo "$__result" | jq -r '.data[].validating_pubkey'
    fi
    if [[ "${WEB3SIGNER}" = "true" ]]; then
        get-token
        __api_path=eth/v1/remotekeys
        __api_container=${__vc_api_container}
        __service=${__vc_service}
        __api_port=${__vc_api_port}
        __api_tls=${__vc_api_tls}
        __validator-list-call
        if [[ "$(echo "$__result" | jq '.data | length')" -eq 0 ]]; then
            echo "No remote keys registered with ${__service}"
        else
            echo "Remote keys registered with ${__service}"
            echo "$__result" | jq -rc '.data[] | [.pubkey, .url] | join(" ")'
        fi
    fi
}

validator-count() {
    __api_path=eth/v1/keystores
    if [[ "${WEB3SIGNER}" = "true" ]]; then
        __token=NIL
        __vc_api_container=${__api_container}
        __api_container=${__w3s_container}
        __vc_service=${__service}
        __service=web3signer
        __vc_api_port=${__api_port}
        __api_port=${__w3s_port}
        __vc_api_tls=${__api_tls}
        __api_tls=false
    else
        get-token
    fi
    __validator-list-call
    key_count=$(echo "$__result" | jq -r '.data | length')
    echo "Validator keys loaded into ${__service}: $key_count"

    __vals="$__result"

    if [[ "${WEB3SIGNER}" = "true" ]]; then
        get-token
        __api_path=eth/v1/remotekeys
        __api_container=${__vc_api_container}
        __service=${__vc_service}
        __api_port=${__vc_api_port}
        __api_tls=${__vc_api_tls}
        __validator-list-call
        remote_key_count=$(echo "$__result" | jq -r '.data | length')
        echo "Remote Validator keys registered with ${__service}: $remote_key_count"
        if [[ "${key_count}" -ne "${remote_key_count}" ]]; then
          echo "WARNING: The number of keys loaded into Web3signer and registered with the validator client differ."
          echo "Please run \"./ethd keys register\""
        fi
    fi

    echo "Querying validator state, this may take a minute"
    __vals_active=0
    __vals_exiting=0
    __vals_exited=0
    __vals_slashed=0
    __vals_pending=0
    __vals_unknown=0
    for __pubkey in $(echo "$__vals" | jq -r '.data[].validating_pubkey'); do
      __val_state=$(curl -k -m 60 -s --show-error "${CL_NODE}/eth/v1/beacon/states/head/validators/${__pubkey}" | jq -r .data.status)
      case "${__val_state}" in
        active_ongoing) ((__vals_active++));;
        active_exiting) ((__vals_exiting++));;
        *_slashed) ((__vals_slashed++));;
        exited_unslashed|withdrawal_*) ((__vals_exited++));;
        pending_*) ((__vals_pending++));;
        unknown|*) ((__vals_unknown++));;
      esac
    done

    if [[ "${__vals_active}" -gt 0 ]]; then
      echo "Active, unslashed validators: ${__vals_active}"
    fi
    if [[ "${__vals_exiting}" -gt 0 ]]; then
      echo "Active, exiting validators: ${__vals_exiting}"
    fi
    if [[ "${__vals_exited}" -gt 0 ]]; then
      echo "Exited and/or withdrawn validators: ${__vals_exited}"
    fi
    if [[ "${__vals_pending}" -gt 0 ]]; then
      echo "Pending validators: ${__vals_pending}"
    fi
    if [[ "${__vals_slashed}" -gt 0 ]]; then
      echo "Slashed validators: ${__vals_slashed}"
    fi
    if [[ "${__vals_unknown}" -gt 0 ]]; then
      echo "Unknown validators, no deposit: ${__vals_unknown}"
    fi
}

validator-delete() {
    if [[ -z "${__pubkey}" ]]; then
      echo "Please specify a validator public key to delete, or \"all\""
      exit 0
    fi
    if [[ ! "${__pubkey}" = "all" ]]; then
      __check_pubkey "${__pubkey}"
    fi
    __pubkeys=()
    __api_path=eth/v1/keystores
    if [[ "${__pubkey}" = "all" ]]; then
        if [[ "${WEB3SIGNER}" = "true" ]]; then
            echo "WARNING - this will delete all currently loaded keys from web3signer and the validator client."
        else
            echo "WARNING - this will delete all currently loaded keys from the validator client."
        fi
        echo
        read -rp "Do you wish to continue with key deletion? (No/yes) " yn
        case $yn in
            [Yy][Ee][Ss]) ;;
            * ) echo "Aborting key deletion"; exit 130;;
        esac
        if [[ "${WEB3SIGNER}" = "true" ]]; then
            __token=NIL
            __vc_api_container=${__api_container}
            __api_container=${__w3s_container}
            __vc_api_port=${__api_port}
            __api_port=${__w3s_port}
            __vc_api_tls=${__api_tls}
            __api_tls=false
        else
            get-token
        fi

        __validator-list-call
        if [[ "$(echo "$__result" | jq '.data | length')" -eq 0 ]]; then
            echo "No keys loaded, cannot delete anything"
            return
        else
            __keys_to_array=$(echo "$__result" | jq -r '.data[].validating_pubkey' | tr '\n' ' ')
# Word splitting is desired for the array
# shellcheck disable=SC2206
            __pubkeys+=( ${__keys_to_array} )
            if [[ "${WEB3SIGNER}" = "true" ]]; then
                __api_container=${__vc_api_container}
                __api_port=${__vc_api_port}
                __api_tls=${__vc_api_tls}
            fi
        fi
    else
        __pubkeys+=( "${__pubkey}" )
    fi

    for __pubkey in "${__pubkeys[@]}"; do
        # Remove remote registration, with a path not to
        if [[ "${WEB3SIGNER}" = "true" ]]; then
          if [[ -z "${W3S_NOREG+x}" ]]; then
            get-token
            __api_path=eth/v1/remotekeys
            __api_data="{\"pubkeys\":[\"$__pubkey\"]}"
            __http_method=DELETE
            call_api
            case $__code in
                200) ;;
                401) echo "No authorization token found. This is a bug. Error: $(echo "$__result" | jq -r '.message')"; exit 70;;
                403) echo "The authorization token is invalid. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
                500) echo "Internal server error. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
                *) echo "Unexpected return code $__code. Result: $__result"; exit 1;;
            esac

            __status=$(echo "$__result" | jq -r '.data[].status')
            case ${__status,,} in
                error)
                    echo "Remote registration for validator ${__pubkey} was found but an error was encountered trying \
to delete it:"
                    echo "$__result" | jq -r '.data[].message'
                    ;;
                not_active)
                    echo "Validator ${__pubkey} is not actively loaded."
                    ;;
                deleted)
                    echo "Remote registration for validator ${__pubkey} deleted."
                    ;;
                not_found)
                    echo "The validator ${__pubkey} was not found in the registration list."
                    ;;
                *)
                    echo "Unexpected status $__status. This may be a bug"
                    exit 70
                    ;;
            esac
          else
            echo "This client loads web3signer keys at startup, no registration to remove."
          fi
        fi

        if [[ "${WEB3SIGNER}" = "true" ]]; then
            __token=NIL
            __vc_api_container=${__api_container}
            __api_container=${__w3s_container}
            __vc_api_port=${__api_port}
            __api_port=${__w3s_port}
            __vc_api_tls=${__api_tls}
            __api_tls=false
        else
            get-token
        fi

        __api_path=eth/v1/keystores
        __api_data="{\"pubkeys\":[\"$__pubkey\"]}"
        __http_method=DELETE
        call_api
        case $__code in
            200) ;;
            400) echo "The pubkey was formatted wrong. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
            401) echo "No authorization token found. This is a bug. Error: $(echo "$__result" | jq -r '.message')"; exit 70;;
            403) echo "The authorization token is invalid. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
            500) echo "Internal server error. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
            *) echo "Unexpected return code $__code. Result: $__result"; exit 1;;
        esac

        __status=$(echo "$__result" | jq -r '.data[].status')
        case ${__status,,} in
            error)
                echo "Validator ${__pubkey} was found but an error was encountered trying to delete it:"
                echo "$__result" | jq -r '.data[].message'
                ;;
            not_active)
                __file=validator_keys/slashing_protection-${__pubkey::10}--${__pubkey:90}.json
                echo "Validator ${__pubkey} is not actively loaded."
                echo "$__result" | jq '.slashing_protection | fromjson' > /"$__file"
                chmod 644 /"$__file"
                echo "Slashing protection data written to .eth/$__file"
                ;;
            deleted)
                __file=validator_keys/slashing_protection-${__pubkey::10}--${__pubkey:90}.json
                echo "Validator ${__pubkey} deleted."
                echo "$__result" | jq '.slashing_protection | fromjson' > /"$__file"
                chmod 644 /"$__file"
                echo "Slashing protection data written to .eth/$__file"
                ;;
            not_found)
                echo "The validator ${__pubkey} was not found in the keystore, no slashing protection data returned."
                ;;
            * )
                echo "Unexpected status $__status. This may be a bug"
                exit 70
                ;;
        esac
        if [[ "${WEB3SIGNER}" = "true" ]]; then
            __api_container=${__vc_api_container}
            __api_port=${__vc_api_port}
            __api_tls=${__vc_api_tls}
        fi
        echo
    done
}

validator-import() {
    __eth2_val_tools=0
    __depth=1
    __key_root_dir=/validator_keys

    __num_dirs=$(find /validator_keys -maxdepth 1 -type d -name '0x*' | wc -l)
    if [[ "$__pass" -eq 1 && "$__num_dirs" -gt 0 ]]; then
        echo "Found $__num_dirs directories starting with 0x. If these are from eth2-val-tools, please copy the keys \
and secrets directories into .eth/validator_keys instead."
        echo
    fi

    if [[ "$__pass" -eq 1 && -d /validator_keys/keys ]]; then
        if [[ -d /validator_keys/secrets ]]; then
            echo "keys and secrets directories found, assuming keys generated by eth2-val-tools"
            echo "Keystore files directly under .eth/validator_keys will be imported in a second pass"
            echo
            __eth2_val_tools=1
            __depth=2
            __key_root_dir=/validator_keys/keys
        else
            echo "Found a keys directory but no secrets directory. This may be an incomplete eth2-val-tools output. Skipping."
            echo
        fi
    fi
    __num_files=$(find "$__key_root_dir" -maxdepth "$__depth" -type f -name '*keystore*.json' | wc -l)
    if [[ "$__num_files" -eq 0 ]]; then
        if [[ "$__pass" -eq 1 ]]; then
            echo "No *keystore*.json files found in .eth/validator_keys/"
            echo "Nothing to do"
        fi
        exit 0
    fi

    if [[ "$__pass" -eq 2 ]]; then
        echo
        echo "Now importing keystore files directly under .eth/validator_keys"
        echo
    fi

    __non_interactive=0
    if echo "$@" | grep -q '.*--non-interactive.*' 2>/dev/null ; then
      __non_interactive=1
    fi

    if [[ ${__non_interactive} = 1 ]]; then
        __password="${KEYSTORE_PASSWORD}"
        __justone=1
    else
        echo "WARNING - imported keys are immediately live. If these keys exist elsewhere,"
        echo "you WILL get slashed. If it has been less than 15 minutes since you deleted them elsewhere,"
        echo "you are at risk of getting slashed. Exercise caution"
        echo
        while true; do
            read -rp "I understand these dire warnings and wish to proceed with key import (No/yes) " yn
            case $yn in
                [Yy][Ee][Ss]) break;;
                [Nn]* ) echo "Aborting import"; exit 130;;
                * ) echo "Please answer yes or no.";;
            esac
        done
        if [[ "$__eth2_val_tools" -eq 0 && "$__num_files" -gt 1 ]]; then
            while true; do
                read -rp "Do all validator keys have the same password? (y/n) " yn
                case $yn in
                    [Yy]* ) __justone=1; break;;
                    [Nn]* ) __justone=0; break;;
                    * ) echo "Please answer yes or no.";;
                esac
            done
        else
            __justone=1
        fi
        if [[ "$__eth2_val_tools" -eq 0 && "$__justone" -eq 1 ]]; then
            while true; do
                read -srp "Please enter the password for your validator key(s): " __password
                echo
                read -srp "Please re-enter the password: " __password2
                echo
                if [[ "$__password" == "$__password2" ]]; then
                    break
                else
                    echo "The two entered passwords do not match, please try again."
                    echo
                fi
            done
            echo
        fi
    fi
    __imported=0
    __skipped=0
    __errored=0
    __registered=0
    __reg_skipped=0
    __reg_errored=0
# See https://www.shellcheck.net/wiki/SC2044 as for why
# Using file descriptor 3 so this doesn't conflict with the "different passwords" read
# Could also use dialog, but would need to make sure it exists
    while IFS= read -r -u 3 __keyfile; do
        [[ -f "$__keyfile" ]] || continue
        __keydir=$(dirname "$__keyfile")
        __pubkey=0x$(jq -r '.pubkey' "$__keyfile")
        if [[ "$__pubkey" = "0xnull" ]]; then
            echo "The file $__keyfile does not specify a pubkey. Maybe it is a Prysm wallet file?"
            echo "Even for Prysm, please use the individual keystore files as generated by staking-deposit-cli, or for eth2-val-tools copy the keys and secrets directories into .eth/validator_keys."
            echo "Skipping."
            echo
            (( __skipped+=1 ))
            continue
        fi
        if [[ "$__eth2_val_tools" -eq 1 ]]; then
            if [[ -f /validator_keys/secrets/"$(basename "$__keydir")" ]]; then
                __password=$(</validator_keys/secrets/"$(basename "$__keydir")")
            else
                echo "Password file /validator_keys/secrets/$(basename "$__keydir") not found. Skipping key import."
                (( __skipped+=1 ))
                continue
            fi
        fi
        if [[ "$__eth2_val_tools" -eq 0 && "$__justone" -eq 0 ]]; then
            while true; do
                __passfile=${__keyfile/.json/.txt}
                if [[ -f "$__passfile" ]]; then
                    echo "Password file is found: $__passfile"
                    __password=$(< "$__passfile")
                    break
                else
                    echo "Password file $__passfile not found."
                fi
                read -srp "Please enter the password for your validator key stored in $__keyfile with public key $__pubkey: " __password
                echo
                read -srp "Please re-enter the password: " __password2
                echo
                if [[ "$__password" == "$__password2" ]]; then
                    break
                else
                    echo "The two entered passwords do not match, please try again."
                    echo
                fi
                echo
            done
        fi
        __do_a_protec=0
        __found_one=0
        for __protectfile in "$__keydir"/slashing_protection*.json; do
            [[ -f "$__protectfile" ]] || continue
            if grep -q "$__pubkey" "$__protectfile"; then
                __found_one=1
                echo "Found slashing protection import file $__protectfile for $__pubkey"
                if [[ "$(jq ".data[] | select(.pubkey==\"$__pubkey\") | .signed_blocks | length" < "$__protectfile")" -gt 0 \
                    || "$(jq ".data[] | select(.pubkey==\"$__pubkey\") | .signed_attestations | length" < "$__protectfile")" -gt 0 ]]; then
                    __do_a_protec=1
                    echo "It will be imported"
                else
                    echo "WARNING: The file does not contain importable data and will be skipped."
                    echo "Your validator will be imported WITHOUT slashing protection data."
                fi
                break
            fi
        done
        if [[ "$__eth2_val_tools" -eq 0 && "${__found_one}" -eq 0 ]]; then
                echo "No viable slashing protection import file found for $__pubkey."
                echo "This is expected if this is a new key."
                echo "Proceeding without slashing protection import."
        fi
        __keystore_json=$(< "$__keyfile")
        if [[ "$__do_a_protec" -eq 1 ]]; then
            __protect_json=$(jq "select(.data[].pubkey==\"$__pubkey\") | tojson" < "$__protectfile")
        else
            __protect_json=""
        fi
        echo "$__protect_json" > /tmp/protect.json

        if [[ "${__debug}" -eq 1 ]]; then
          echo "The keystore reads as $__keystore_json"
          echo "And your password is $__password"
          set +e
          echo "Testing jq on these"
          jq --arg keystore_value "$__keystore_json" --arg password_value "$__password" '. | .keystores += [$keystore_value] | .passwords += [$password_value]' <<< '{}'
          set -e
        fi
        if [[ "$__do_a_protec" -eq 0 ]]; then
            jq --arg keystore_value "$__keystore_json" --arg password_value "$__password" '. | .keystores += [$keystore_value] | .passwords += [$password_value]' <<< '{}' >/tmp/apidata.txt
        else
            jq --arg keystore_value "$__keystore_json" --arg password_value "$__password" --slurpfile protect_value /tmp/protect.json '. | .keystores += [$keystore_value] | .passwords += [$password_value] | . += {slashing_protection: $protect_value[0]}' <<< '{}' >/tmp/apidata.txt
        fi

        if [[ "${WEB3SIGNER}" = "true" ]]; then
            __token=NIL
            __vc_api_container=${__api_container}
            __api_container=${__w3s_container}
            __vc_api_port=${__api_port}
            __api_port=${__w3s_port}
            __vc_api_tls=${__api_tls}
            __api_tls=false
        else
            get-token
        fi

        __api_data=@/tmp/apidata.txt
        __api_path=eth/v1/keystores
        __http_method=POST
        call_api
        case $__code in
            200) ;;
            400) echo "The pubkey was formatted wrong. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
            401) echo "No authorization token found. This is a bug. Error: $(echo "$__result" | jq -r '.message')"; exit 70;;
            403) echo "The authorization token is invalid. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
            500) echo "Internal server error. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
            *) echo "Unexpected return code $__code. Result: $__result"; exit 1;;
        esac
        if ! echo "$__result" | grep -q "data"; then
           echo "The key manager API query failed. Output:"
           echo "$__result"
           exit 1
        fi
        __status=$(echo "$__result" | jq -r '.data[].status')
        case ${__status,,} in
            error)
                echo "An error was encountered trying to import the key $__pubkey:"
                echo "$__result" | jq -r '.data[].message'
                echo
                (( __errored+=1 ))
                continue
                ;;
            imported)
                echo "Validator key was successfully imported: $__pubkey"
                (( __imported+=1 ))
                ;;
            duplicate)
                echo "Validator key is a duplicate and was skipped: $__pubkey"
                (( __skipped+=1 ))
                ;;
            *)
                echo "Unexpected status $__status. This may be a bug"
                exit 70
                ;;
        esac
        # Add remote registration, with a path not to
        if [[ "${WEB3SIGNER}" = "true" ]]; then
          if [[ -z "${W3S_NOREG+x}" ]]; then
            __api_container=${__vc_api_container}
            __api_port=${__vc_api_port}
            __api_tls=${__vc_api_tls}
# shellcheck disable=SC2153
            jq --arg pubkey_value "$__pubkey" --arg url_value "${W3S_NODE}" '. | .remote_keys += [{"pubkey": $pubkey_value, "url": $url_value}]' <<< '{}' >/tmp/apidata.txt

            get-token
            __api_data=@/tmp/apidata.txt
            __api_path=eth/v1/remotekeys
            __http_method=POST
            call_api
            case $__code in
                200) ;;
                401) echo "No authorization token found. This is a bug. Error: $(echo "$__result" | jq -r '.message')"; exit 70;;
                403) echo "The authorization token is invalid. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
                500) echo "Internal server error. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
                *) echo "Unexpected return code $__code. Result: $__result"; exit 1;;
            esac
            if ! echo "$__result" | grep -q "data"; then
               echo "The key manager API query failed. Output:"
               echo "$__result"
               exit 1
            fi
            __status=$(echo "$__result" | jq -r '.data[].status')
            case ${__status,,} in
                error)
                    echo "An error was encountered trying to register the key $__pubkey:"
                    echo "$__result" | jq -r '.data[].message'
                    (( __reg_errored+=1 ))
                    ;;
                imported)
                    echo "Validator key was successfully registered with validator client: $__pubkey"
                    (( __registered+=1 ))
                    ;;
                duplicate)
                    echo "Validator key is a duplicate and registration was skipped: $__pubkey"
                    (( __reg_skipped+=1 ))
                    ;;
                *)
                    echo "Unexpected status $__status. This may be a bug"
                    exit 70
                    ;;
            esac
          else
            echo "This client loads web3signer keys at startup, skipping registration via keymanager."
          fi
        fi
        echo
    done 3< <(find "$__key_root_dir" -maxdepth "$__depth" -name '*keystore*.json')

    echo "Imported $__imported keys"
    if [[ "$WEB3SIGNER" = "true" ]]; then
        echo "Registered $__registered keys with the validator client"
    fi
    echo "Skipped $__skipped keys"
    if [[ "$WEB3SIGNER" = "true" ]]; then
        echo "Skipped registration of $__reg_skipped keys"
    fi
    if [[ "$__errored" -gt 0 ]]; then
        echo "$__errored keys caused an error during import"
    fi
    if [[ "$__reg_errored" -gt 0 ]]; then
        echo "$__reg_errored keys caused an error during registration"
    fi
    echo
    echo "IMPORTANT: Only import keys in ONE LOCATION."
    echo "Failure to do so will get your validators slashed: Greater 1 ETH penalty and forced exit."
}

validator-register() {
    if [[ ! "${WEB3SIGNER}" = "true" ]]; then
        echo "WEB3SIGNER is not \"true\" in .env, cannot register web3signer keys with the validator client."
        echo "Aborting."
        exit 1
    fi

    if [[ "${W3S_NOREG:-false}" = "true" ]]; then
        echo "This client loads web3signer keys at startup, skipping registration via keymanager."
        exit 0
    fi

    __api_path=eth/v1/keystores
    __token=NIL
    __vc_api_container=${__api_container}
    __api_container=${__w3s_container}
    __vc_api_port=${__api_port}
    __api_port=${__w3s_port}
    __vc_api_tls=${__api_tls}
    __api_tls=false
    __validator-list-call
    if [[ "$(echo "$__result" | jq '.data | length')" -eq 0 ]]; then
        echo "No keys loaded in web3signer, aborting."
        exit 1
    fi

    __api_container=${__vc_api_container}
    __api_port=${__vc_api_port}
    __api_tls=${__vc_api_tls}
    get-token
    __registered=0
    __reg_skipped=0
    __reg_errored=0

    __w3s_pubkeys="$(echo "$__result" | jq -r '.data[].validating_pubkey')"
    while IFS= read -r __pubkey; do
         jq --arg pubkey_value "$__pubkey" --arg url_value "${W3S_NODE}" '. | .remote_keys += [{"pubkey": $pubkey_value, "url": $url_value}]' <<< '{}' >/tmp/apidata.txt

        __api_data=@/tmp/apidata.txt
        __api_path=eth/v1/remotekeys
        __http_method=POST
        call_api
        case $__code in
            200) ;;
            401) echo "No authorization token found. This is a bug. Error: $(echo "$__result" | jq -r '.message')"; exit 70;;
            403) echo "The authorization token is invalid. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
            500) echo "Internal server error. Error: $(echo "$__result" | jq -r '.message')"; exit 1;;
            *) echo "Unexpected return code $__code. Result: $__result"; exit 1;;
        esac
        if ! echo "$__result" | grep -q "data"; then
           echo "The key manager API query failed. Output:"
           echo "$__result"
           exit 1
        fi
        __status=$(echo "$__result" | jq -r '.data[].status')
        case ${__status,,} in
            error)
                echo "An error was encountered trying to register the key $__pubkey:"
                echo "$__result" | jq -r '.data[].message'
                echo
                (( __reg_errored+=1 ))
                ;;
            imported)
                echo "Validator key was successfully registered with validator client: $__pubkey"
                echo
                (( __registered+=1 ))
                ;;
            duplicate)
                echo "Validator key is a duplicate and registration was skipped: $__pubkey"
                echo
                (( __reg_skipped+=1 ))
                ;;
            *)
                echo "Unexpected status $__status. This may be a bug"
                exit 70
                ;;
        esac
    done <<< "${__w3s_pubkeys}"

    echo "Registered $__registered keys with the validator client"
    echo "Skipped registration of $__reg_skipped keys"
    if [[ "$__reg_errored" -gt 0 ]]; then
        echo "$__reg_errored keys caused an error during registration"
    fi
    echo
}

# Verify keys only exist in one location
__web3signer_check() {
    if [[ -z "${PRYSM:+x}" && ! "${WEB3SIGNER}" = "true" ]]; then
        get-token
        __api_path=eth/v1/remotekeys
        __validator-list-call
        if [[ ! "$(echo "$__result" | jq '.data | length')" -eq 0 ]]; then
            echo "WEB3SIGNER is not \"true\" in .env, but there are web3signer keys registered."
            echo "This is not safe. Set WEB3SIGNER=true and remove web3signer keys first. Aborting."
            exit 1
        fi
    fi
}

__clean_exit() {
  echo "Terminated by user."
  exit 0
}

usage() {
    echo "Call keymanager with an ACTION, one of:"
    echo "  list"
    echo "     Lists the public keys of all validators currently loaded into your validator client"
    echo "  count"
    echo "     Counts the number of keys currently loaded into your validator client"
    echo "  import"
    echo "      Import all keystore*.json in .eth/validator_keys while loading slashing protection data"
    echo "      in slashing_protection*.json files that match the public key(s) of the imported validator(s)"
    echo "  delete 0xPUBKEY | all"
    echo "      Deletes the validator with public key 0xPUBKEY from the validator client, and exports its"
    echo "      slashing protection database."
    echo "      \"all\" deletes all detected validators."
    echo "  register"
    echo "      For use with web3signer only: Re-register all keys in web3signer with the validator client"
    echo
    echo "  get-recipient 0xPUBKEY"
    echo "      List fee recipient set for the validator with public key 0xPUBKEY"
    echo "      Validators will use FEE_RECIPIENT in .env by default, if not set individually"
    echo "  set-recipient 0xPUBKEY 0xADDRESS"
    echo "      Set individual fee recipient for the validator with public key 0xPUBKEY"
    echo "  delete-recipient 0xPUBKEY"
    echo "      Delete individual fee recipient for the validator with public key 0xPUBKEY"
    echo
    echo "  get-gas 0xPUBKEY"
    echo "      List execution gas limit set for the validator with public key 0xPUBKEY"
    echo "      Validators will use the client's default, if not set individually"
    echo "  set-gas 0xPUBKEY amount"
    echo "      Set individual execution gas limit for the validator with public key 0xPUBKEY"
    echo "  delete-gas 0xPUBKEY"
    echo "      Delete individual execution gas limit for the validator with public key 0xPUBKEY"
    echo
    echo "  get-graffiti 0xPUBKEY"
    echo "      List graffiti set for the validator with public key 0xPUBKEY"
    echo "      Validators will use GRAFFITI in .env by default, if not set individually"
    echo "  set-graffiti 0xPUBKEY string"
    echo "      Set individual graffiti for the validator with public key 0xPUBKEY"
    echo "  delete-graffiti 0xPUBKEY"
    echo "      Delete individual graffiti for the validator with public key 0xPUBKEY"
    echo
    echo "  get-api-token"
    echo "      Print the token for the keymanager API running on port ${__api_port}."
    echo "      This is also the token for the Prysm Web UI"
    echo
    echo "  create-prysm-wallet"
    echo "      Create a new Prysm wallet to store keys in"
    echo "  get-prysm-wallet"
    echo "      Print Prysm's wallet password"
    echo
    echo "  get-grandine-wallet"
    echo "      Print Grandine's wallet password"
    echo
    echo "  prepare-address-change"
    echo "      Create an offline-preparation.json with ethdo"
    echo "  send-address-change"
    echo "      Send a change-operations.json with ethdo, setting the withdrawal address"
    echo
    echo "  sign-exit 0xPUBKEY | all"
    echo "      Create pre-signed exit message for the validator with public key 0xPUBKEY"
    echo "      \"all\" signs an exit message for all detected validators"
    echo "  sign-exit from-keystore [--offline]"
    echo "      Create pre-signed exit messages with ethdo, from keystore files in ./.eth/validator_keys"
    echo "  send-exit"
    echo "      Send pre-signed exit messages in ./.eth/exit_messages to the Ethereum chain"
    echo
    echo " Commands can be appended with \"--debug\" to see debug output"
}

set -e

trap __clean_exit SIGINT SIGTERM

if echo "$@" | grep -q '.*--debug.*' 2>/dev/null ; then
  __debug=1
elif echo "$@" | grep -q '.*--trace.*' 2>/dev/null ; then
  __debug=1
  set -x
else
  __debug=0
fi

if [[ "$(id -u)" -eq 0 ]]; then
    __token_file=$1
    __api_container=$2
    case "$__api_container" in  # It's either consensus or some alias for the validator service
        consensus) __service=consensus;;
        *) __service=validator;;
    esac
    __api_port=${KEY_API_PORT:-7500}
    if [[ -z "${TLS:+x}" ]]; then
        __api_tls=false
    else
        __api_tls=true
    fi
    case "$3" in
        get-api-token)
            print-api-token
            exit 0
            ;;
        create-prysm-wallet)
            echo "There's a bug in ethd; this command should have been handled one level higher. Please report this."
            exit 70
            ;;
        get-prysm-wallet)
            get-prysm-wallet
            exit 0
            ;;
        get-grandine-wallet)
            get-grandine-wallet
            exit 0
            ;;
    esac
    if [[ -z "$3" ]]; then
        usage
        exit 0
    fi
    if [[ -f "$__token_file" ]]; then
        chmod 1777 /tmp  # A user had 755 and root:984. Root cause unknown; work around it
        cp "$__token_file" /tmp/api-token.txt
        chown "${OWNER_UID:-1000}":"${OWNER_UID:-1000}" /tmp/api-token.txt
        exec gosu "${OWNER_UID:-1000}":"${OWNER_UID:-1000}" "${BASH_SOURCE[0]}" "$@"
    else
        echo "File $__token_file not found."
        echo "The $__service service may not be fully started yet."
        exit 1
    fi
fi
__token_file_client="$1"
__token_file=/tmp/api-token.txt
__api_container=$2
__api_port=${KEY_API_PORT:-7500}
__w3s_container=$(echo "${W3S_NODE}" | awk -F[/:] '{print $4}')
__w3s_port=$(echo "${W3S_NODE}" | awk -F[/:] '{print $5}')
if [[ -z "${TLS:+x}" ]]; then
    __api_tls=false
else
    __api_tls=true
fi

if [[ "${WEB3SIGNER}" = "true" && ( -z "$__w3s_container" || -z "$__w3s_port" ) ]]; then
  echo "Web3signer is in use, but W3S_NODE \"${W3S_NODE}\" can't be parsed. This is a bug."
  exit 1
fi

case "$__api_container" in  # It's either consensus or some alias for the validator service
    consensus) __service=consensus;;
    *) __service=validator;;
esac

case "$3" in
    list)
        validator-list
        ;;
    delete)
        __pubkey=$4
        validator-delete
        ;;
    import)
        __web3signer_check
        shift 3
        __pass=1
        validator-import "$@"
        if [[ "$__eth2_val_tools" -eq 1 ]]; then
            __pass=2
            validator-import "$@"
        fi
        ;;
    register)
        validator-register
        ;;
    count)
        validator-count
        ;;
    get-recipient)
        __pubkey=$4
        recipient-get
        ;;
    set-recipient)
        __pubkey=$4
        __address=$5
        recipient-set
        ;;
    delete-recipient)
        __pubkey=$4
        recipient-delete
        ;;
    get-gas)
        __pubkey=$4
        gas-get
        ;;
    set-gas)
        __pubkey=$4
        __limit=$5
        gas-set
        ;;
    delete-gas)
        __pubkey=$4
        gas-delete
        ;;
    get-graffiti)
        __pubkey=$4
        graffiti-get
        ;;
    set-graffiti)
        __pubkey=$4
        __graffiti=$5
        graffiti-set
        ;;
    delete-graffiti)
        __pubkey=$4
        graffiti-delete
        ;;
    sign-exit)
        __pubkey=$4
        exit-sign
        ;;
    send-exit)
        exit-send
        ;;
    prepare-address-change)
        echo "This should have been handled one layer up in ethd. This is a bug, please report."
        exit 70
        ;;
    send-address-change)
        echo "This should have been handled one layer up in ethd. This is a bug, please report."
        exit 70
        ;;
    *)
        usage
        ;;
esac
