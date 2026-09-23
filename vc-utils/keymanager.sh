#!/usr/bin/env bash

# Global vars
__code=0
__result=""
__debug=0
__api_data=""
__api_tls=""
__api_port=7500
__api_path=""
__api_container=""
__http_method=""
__token=""
__token_file_client=""
__token_file=""
__service=""
__w3s_container=""
__w3s_port=9000
__pubkey=""
__limit=0
__graffiti=""
__address=""
__builder_urls=""
__min_bid=""
__min_bid_gwei=""
__boost_factor=""
__boost_factor_value=""
__pubkey_selector=""
__pubkeys=()
__json_body=""
__json_out=0
# "always use the builder" in the keymanager API. Note this is NOT the same scale as
# EPBS_BUILD_FACTOR in .env, where 100 means "always"; here 100 means profit maximization.
__max_boost_factor=18446744073709551615
__pass=0
__eth2_val_tools=0
__non_interactive=0


# Not all clients return .message like they should.
# This is called as __print_jq_message "<message>" "<jq_query>"
__print_jq_message() {
  local message=$1
  local jq_query=$2

  if ! echo "${message}" | jq -er "${jq_query} // empty" 2>/dev/null; then
    echo "${message}"
  fi
}


__call_api() {
  local exitstatus

  set +e
  if [[ -z "${__api_data}" ]]; then
    if [[ "${__api_tls}" = "true" ]]; then
      __code=$(curl -k -m 60 -s --show-error -o /tmp/result.txt -w "%{http_code}" -X "${__http_method}" -H "Accept: application/json" -H "Authorization: Bearer ${__token}" \
          https://"${__api_container}":"${__api_port}"/"${__api_path}")
    else
      __code=$(curl -m 60 -s --show-error -o /tmp/result.txt -w "%{http_code}" -X "${__http_method}" -H "Accept: application/json" -H "Authorization: Bearer ${__token}" \
          http://"${__api_container}":"${__api_port}"/"${__api_path}")
    fi
else
    if [[ "${__api_tls}" = "true" ]]; then
      __code=$(curl -k -m 60 -s --show-error -o /tmp/result.txt -w "%{http_code}" -X "${__http_method}" -H "Accept: application/json" -H "Content-Type: application/json" -H "Authorization: Bearer ${__token}" \
          --data "${__api_data}" https://"${__api_container}":"${__api_port:-7500}"/"${__api_path}")
    else
      __code=$(curl -m 60 -s --show-error -o /tmp/result.txt -w "%{http_code}" -X "${__http_method}" -H "Accept: application/json" -H "Content-Type: application/json" -H "Authorization: Bearer ${__token}" \
          --data "${__api_data}" http://"${__api_container}":"${__api_port:-7500}"/"${__api_path}")
    fi
  fi
  exitstatus=$?
  if [[ "${__debug}" -eq 1 ]]; then
    echo "Called ${__api_container}:${__api_port}/${__api_path} with method ${__http_method} and the following data"
    if [[ -n "${__api_data}" ]]; then
      if [[ "${__api_data}" =~ ^@.+ ]]; then
        cat "${__api_data#@}"
      else
        echo "${__api_data}"
      fi
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

  if [[ "${exitstatus}" -ne 0 ]]; then
    echo "Error encountered while trying to call the keymanager API via curl."
    echo "Please make sure the ${__service} service is up and its logs show the key manager API, port ${__api_port}, enabled."
    echo "Error code ${exitstatus}"
    exit ${exitstatus}
  fi
  if [[ -f /tmp/result.txt ]]; then
    __result=$(cat /tmp/result.txt)
  else
    echo "Error encountered while trying to call the keymanager API via curl."
    echo "HTTP code: ${__code}"
    exit 1
  fi
}


__call_cl_api() {
  local exitstatus
  local nodes
  local node
  local node_reachable=0

  nodes=$(echo "${CL_NODE}" | tr ',' ' ')
  for node in ${nodes}; do
    if curl -s -m 5 -o /dev/null -w "%{http_code}" "${node}/eth/v1/node/health" | grep -q "^[23]"; then
      node_reachable=1
      break
    fi
  done

  if [[ "${node_reachable}" -eq 0 ]]; then
    echo "No consensus client node is reachable via any URL in ${CL_NODE}"
    exit 1
  fi

  set +e
  if [[ -z "${__api_data}" ]]; then
    __code=$(curl -m 60 -s --show-error -o /tmp/result.txt -w "%{http_code}" -X "${__http_method}" -H "Accept: application/json" \
        "${node}"/"${__api_path}")
  else
    __code=$(curl -m 60 -s --show-error -o /tmp/result.txt -w "%{http_code}" -X "${__http_method}" -H "Accept: application/json" -H "Content-Type: application/json" \
        --data "${__api_data}" "${node}"/"${__api_path}")
  fi
  exitstatus=$?
  if [[ "${exitstatus}" -ne 0 ]]; then
    echo "Error encountered while trying to call the consensus client REST API via curl."
    echo "Please make sure the ${node} URL is reachable."
    echo "Error code ${exitstatus}"
    exit ${exitstatus}
  fi
  if [[ -f /tmp/result.txt ]]; then
    __result=$(cat /tmp/result.txt)
  else
    echo "Error encountered while trying to call the consensus client REST API via curl."
    echo "HTTP code: ${__code}"
    exit 1
  fi
}


__get_token() {
set +e
  local exitstatus

  __token=$(tail -n 1 "${__token_file}")
  exitstatus=$?
  if [[ "${exitstatus}" -ne 0 ]]; then
    echo "Error encountered while trying to get the keymanager API token."
    echo "Please make sure the ${__service} service is up and its logs show the key manager API, port ${__api_port}, enabled."
    exit ${exitstatus}
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


get-api-token() {
  __get_token
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
  __get_token
  __api_path="eth/v1/validator/${__pubkey}/feerecipient"
  __api_data=""
  __http_method=GET
  __call_api
  case "${__code}" in
    200) echo "The fee recipient for the validator with public key ${__pubkey} is:"; echo "${__result}" | jq -r '.data.ethaddress'; exit 0;;
    401) echo "No authorization token found. This is a bug. Error: $(__print_jq_message "${__result}" '.message')"; exit 70;;
    403) echo "The authorization token is invalid. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    404) echo "Path not found error. Was that the right pubkey? Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    500) echo "Internal server error. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    *) echo "Unexpected return code ${__code}. Result: ${__result}"; exit 1;;
  esac
}


recipient-set() {
  __check_pubkey "${__pubkey}"
  __check_address "${__address}"
  __get_token
  __api_path="eth/v1/validator/${__pubkey}/feerecipient"
  __api_data="{\"ethaddress\": \"${__address}\" }"
  __http_method=POST
  __call_api
  case "${__code}" in
    202) echo "The fee recipient for the validator with public key ${__pubkey} was updated."; exit 0;;
    400) echo "The pubkey or address was formatted wrong. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    401) echo "No authorization token found. This is a bug. Error: $(__print_jq_message "${__result}" '.message')"; exit 70;;
    403) echo "The authorization token is invalid. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    404) echo "Path not found error. Was that the right pubkey? Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    500) echo "Internal server error. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    *) echo "Unexpected return code ${__code}. Result: ${__result}"; exit 1;;
  esac
}


recipient-delete() {
  __check_pubkey "${__pubkey}"
  __get_token
  __api_path="eth/v1/validator/${__pubkey}/feerecipient"
  __api_data=""
  __http_method=DELETE
  __call_api
  case "${__code}" in
    204) echo "The fee recipient for the validator with public key ${__pubkey} was set back to default."; exit 0;;
    401) echo "No authorization token found. This is a bug. Error: $(__print_jq_message "${__result}" '.message')"; exit 70;;
    403) echo "A fee recipient was found, but cannot be deleted. It may be in a configuration file. Message: $(__print_jq_message "${__result}" '.message')"; exit 0;;
    404) echo "The key was not found on the server, nothing to delete. Message: $(__print_jq_message "${__result}" '.message')"; exit 0;;
    500) echo "Internal server error. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    *) echo "Unexpected return code ${__code}. Result: ${__result}"; exit 1;;
  esac
}


gas-get() {
  __check_pubkey "${__pubkey}"
  __get_token
  __api_path="eth/v1/validator/${__pubkey}/gas_limit"
  __api_data=""
  __http_method=GET
  __call_api
  case "${__code}" in
    200) echo "The execution gas limit for the validator with public key ${__pubkey} is:"; echo "${__result}" | jq -r '.data.gas_limit'; exit 0;;
    400) echo "The pubkey was formatted wrong. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    401) echo "No authorization token found. This is a bug. Error: $(__print_jq_message "${__result}" '.message')"; exit 70;;
    403) echo "The authorization token is invalid. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    404) echo "Path not found error. Was that the right pubkey? Error: $(__print_jq_message "${__result}" '.message')"; exit 0;;
    500) echo "Internal server error. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    *) echo "Unexpected return code ${__code}. Result: ${__result}"; exit 1;;
  esac
}


gas-set() {
  __check_pubkey "${__pubkey}"
  if [[ -z "${__limit}" ]]; then
    echo "Please specify a gas limit"
    exit 0
  fi
  if [[ ! "${__limit}" =~ ^[0-9]+$ ]]; then
    echo "The gas limit needs to be a decimal number"
    exit 0
  fi
  __get_token
  __api_path="eth/v1/validator/${__pubkey}/gas_limit"
  __api_data="{\"gas_limit\": \"${__limit}\" }"
  __http_method=POST
  __call_api
  case "${__code}" in
    202) echo "The gas limit for the validator with public key ${__pubkey} was updated."; exit 0;;
    400) echo "The pubkey or limit was formatted wrong. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    401) echo "No authorization token found. This is a bug. Error: $(__print_jq_message "${__result}" '.message')"; exit 70;;
    403) echo "The authorization token is invalid. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    404) echo "Path not found error. Was that the right pubkey? Error: $(__print_jq_message "${__result}" '.message')"; exit 0;;
    500) echo "Internal server error. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    *) echo "Unexpected return code ${__code}. Result: ${__result}"; exit 1;;
  esac
}


gas-delete() {
  __check_pubkey "${__pubkey}"
  __get_token
  __api_path="eth/v1/validator/${__pubkey}/gas_limit"
  __api_data=""
  __http_method=DELETE
  __call_api
  case "${__code}" in
    204) echo "The gas limit for the validator with public key ${__pubkey} was set back to default."; exit 0;;
    400) echo "The pubkey was formatted wrong. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    401) echo "No authorization token found. This is a bug. Error: $(__print_jq_message "${__result}" '.message')"; exit 70;;
    403) echo "A gas limit was found, but cannot be deleted. It may be in a configuration file. Message: $(__print_jq_message "${__result}" '.message')"; exit 0;;
    404) echo "The key was not found on the server, nothing to delete. Message: $(__print_jq_message "${__result}" '.message')"; exit 0;;
    500) echo "Internal server error. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    *) echo "Unexpected return code ${__code}. Result: ${__result}"; exit 1;;
  esac
}


# Some clients, Lighthouse among them, return the graffiti as the raw 32-byte block field in hex.
# Plain-text graffiti is at most 32 bytes, so "0x" and 64 hex digits can only be that encoding.
__graffiti_text() {
  local graffiti=$1
  local hex
  local bytes=""
  local i

  if [[ ! "${graffiti}" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    printf '%s\n' "${graffiti}"
    return
  fi
  hex=${graffiti#0x}
# Zero bytes are the padding, and would print as invisible NULs anywhere else
  for (( i=0; i<${#hex}; i+=2 )); do
    [[ "${hex:i:2}" = "00" ]] && continue
    bytes+="\\x${hex:i:2}"
  done
  printf '%b\n' "${bytes}"
}


graffiti-get() {
  __check_pubkey "${__pubkey}"
  __get_token
  __api_path="eth/v1/validator/${__pubkey}/graffiti"
  __api_data=""
  __http_method=GET
  __call_api
  case "${__code}" in
    200) echo "The graffiti for the validator with public key ${__pubkey} is:"; __graffiti_text "$(echo "${__result}" | jq -r '.data.graffiti')"; exit 0;;
    400) echo "The pubkey was formatted wrong. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    401) echo "No authorization token found. This is a bug. Error: $(__print_jq_message "${__result}" '.message')"; exit 70;;
    403) echo "The authorization token is invalid. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    404) echo "Path not found error. Was that the right pubkey? Error: $(__print_jq_message "${__result}" '.message')"; exit 0;;
    500) echo "Internal server error. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    *) echo "Unexpected return code ${__code}. Result: ${__result}"; exit 1;;
  esac
}


graffiti-set() {
  __check_pubkey "${__pubkey}"
  if [[ -z "${__graffiti}" ]]; then
    echo "Please specify a graffiti string"
    exit 0
  fi
  if [[ $(echo -n "${__graffiti}" | wc -c) -gt 32 ]]; then
    echo "The graffiti string cannot be longer than 32 characters. Emojis count as 4, each."
    exit 0
  fi
  __get_token
  __api_path="eth/v1/validator/${__pubkey}/graffiti"
  __api_data="{\"graffiti\": \"${__graffiti}\" }"
  __http_method=POST
  __call_api
  case "${__code}" in
# The spec asks for 202. Prysm answers 200 and Teku 204; drop those once they are fixed.
    200|202|204) echo "The graffiti for the validator with public key ${__pubkey} was updated."; exit 0;;
    400) echo "The pubkey or limit was formatted wrong. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    401) echo "No authorization token found. This is a bug. Error: $(__print_jq_message "${__result}" '.message')"; exit 70;;
    403) echo "The authorization token is invalid. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    404) echo "Path not found error. Was that the right pubkey? Error: $(__print_jq_message "${__result}" '.message')"; exit 0;;
    500) echo "Internal server error. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    *) echo "Unexpected return code ${__code}. Result: ${__result}"; exit 1;;
  esac
}


graffiti-delete() {
  __check_pubkey "${__pubkey}"
  __get_token
  __api_path="eth/v1/validator/${__pubkey}/graffiti"
  __api_data=""
  __http_method=DELETE
  __call_api
  case "${__code}" in
# Prysm answers 200 instead of the 204 the spec asks for. Drop the 200 once Prysm is fixed.
    200|204) echo "The graffiti for the validator with public key ${__pubkey} was set back to default."; exit 0;;
    400) echo "The pubkey was formatted wrong. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    401) echo "No authorization token found. This is a bug. Error: $(__print_jq_message "${__result}" '.message')"; exit 70;;
    403) echo "A graffiti was found, but cannot be deleted. It may be in a configuration file. Message: $(__print_jq_message "${__result}" '.message')"; exit 0;;
    404) echo "The key was not found on the server, nothing to delete. Message: $(__print_jq_message "${__result}" '.message')"; exit 0;;
    500) echo "Internal server error. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    *) echo "Unexpected return code ${__code}. Result: ${__result}"; exit 1;;
  esac
}


# Turn "all", a single pubkey, or a comma-separated list into the pubkeys array
# This is called as __pubkeys_to_array "<selector>" "<what we are doing>"
__pubkeys_to_array() {
  local selector=$1
  local purpose=$2
  local key
  local keys_to_array
  local vc_api_container
  local vc_service
  local vc_api_port
  local vc_api_tls

  __pubkeys=()
  if [[ -z "${selector}" ]]; then
    echo "Please specify a validator public key to ${purpose} for, \"all\", or a comma-separated list"
    exit 0
  fi
  if [[ "${selector}" = "all" ]]; then
    __api_path=eth/v1/keystores
    if [[ "${WEB3SIGNER}" = "true" ]]; then
      __token=NIL
      vc_api_container=${__api_container}
      __api_container=${__w3s_container}
      vc_service=${__service}
      __service=web3signer
      vc_api_port=${__api_port}
      __api_port=${__w3s_port}
      vc_api_tls=${__api_tls}
      __api_tls=false
    else
      __get_token
    fi
    __validator_list_call
    if [[ "${WEB3SIGNER}" = "true" ]]; then
      __api_container=${vc_api_container}
      __api_port=${vc_api_port}
      __api_tls=${vc_api_tls}
      __service=${vc_service}
    fi
    if [[ "$(echo "${__result}" | jq '.data | length')" -eq 0 ]]; then
      echo "No keys loaded, nothing to ${purpose}"
      exit 0
    fi
    keys_to_array=$(echo "${__result}" | jq -r '.data[].validating_pubkey' | tr '\n' ' ')
# Word splitting is desired for the array
# shellcheck disable=SC2206
    __pubkeys+=( ${keys_to_array} )
  else
# Strip blanks but not the newlines the comma split just created
    while IFS= read -r key || [[ -n "${key}" ]]; do
      [[ -z "${key}" ]] && continue
      __check_pubkey "${key}"
      __pubkeys+=( "${key}" )
    done < <(echo "${selector}" | tr ',' '\n' | tr -d '[:blank:]')
    if [[ "${#__pubkeys[@]}" -eq 0 ]]; then
      echo "Please specify a validator public key to ${purpose} for, \"all\", or a comma-separated list"
      exit 0
    fi
  fi
}


# Validate a Gwei value as the keymanager API spec defines it
# This is called as __check_gwei "<value>" "<field name>"
__check_gwei() {
  if [[ ! "$1" =~ ^(0|[1-9][0-9]{0,19})$ ]]; then
    echo "The ${2} needs to be a whole number of Gwei, and \"${1}\" is not"
    exit 0
  fi
}


# Convert the ETH value of --min-bid to the Gwei the API expects
__builder_min_bid_to_gwei() {
  local min_bid

  min_bid=${__min_bid}
  if [[ ! "${min_bid}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "The minimum bid needs to be a number in ETH, for example 0.01, and \"${min_bid}\" is not"
    exit 0
  fi
  __min_bid_gwei=$(awk -v v="${min_bid}" 'BEGIN{printf "%.0f", v * 1000000000}')
  __check_gwei "${__min_bid_gwei}" "minimum bid"
}


# Translate the words we accept for --boost-factor into what the API expects
__builder_boost_factor_value() {
  case "${__boost_factor}" in
    local) __boost_factor_value=0;;
    maxprofit) __boost_factor_value=100;;
    always) __boost_factor_value=${__max_boost_factor};;
    *)
      if [[ ! "${__boost_factor}" =~ ^(0|[1-9][0-9]{0,19})$ ]]; then
        echo "The boost factor needs to be \"local\", \"maxprofit\", \"always\", or a whole number."
        echo "It is a percentage multiplier: below 100 disfavors builders, above 100 favors them."
        echo "Note this is not the same scale as EPBS_BUILD_FACTOR in .env, where 100 means \"always\"."
        exit 0
      fi
      __boost_factor_value=${__boost_factor}
      ;;
  esac
}


# Build the patch document from the command line arguments
__builder_patch() {
  local urls

  urls=${__builder_urls}
  if [[ -n "${__min_bid}" ]]; then
    __builder_min_bid_to_gwei
  fi
  if [[ -n "${__boost_factor}" ]]; then
    __builder_boost_factor_value
  fi

  jq -cn --arg urls "${urls}" --arg min_bid "${__min_bid_gwei}" --arg boost "${__boost_factor_value}" '
    {}
    | if $urls == "none" then .builders = []
      elif $urls != "" then .builders = ($urls | split(",")
                                          | map(sub("^\\s+";"") | sub("\\s+$";""))
                                          | map(select(length > 0))
                                          | map({url: .}))
      else . end
    | if $min_bid != "" then .min_bid = $min_bid else . end
    | if $boost != "" then .builder_boost_factor = $boost else . end' >/tmp/builder-patch.json
}


# Catch what the API would reject with a bare 400, so the user gets a useful message
# This is called as __builder_check_document "<file>"
__builder_check_document() {
  local file=$1
  local count
  local dupes
  local long_urls
  local no_url

  if ! jq -e . "${file}" >/dev/null 2>&1; then
    echo "The builder configuration is not valid JSON."
    exit 1
  fi
  if [[ "$(jq -r 'type' "${file}")" != "object" ]]; then
    echo "The builder configuration needs to be a JSON object, see \"ethd keys get-builder 0xPUBKEY --json\"."
    exit 1
  fi
  if [[ "$(jq -r 'has("builders")' "${file}")" != "true" ]]; then
    return
  fi
  if [[ "$(jq -r '.builders | type' "${file}")" != "array" ]]; then
    echo "The \"builders\" field needs to be a JSON array."
    exit 1
  fi
  count=$(jq -r '.builders | length' "${file}")
  if [[ "${count}" -gt 64 ]]; then
    echo "The keymanager API allows at most 64 builders, and this configuration has ${count}."
    exit 1
  fi
  no_url=$(jq -r '[.builders[] | select(has("url") | not)] | length' "${file}")
  if [[ "${no_url}" -gt 0 ]]; then
    echo "Every entry in \"builders\" needs a \"url\", and at least one entry does not have one."
    exit 1
  fi
  long_urls=$(jq -r '[.builders[] | select(.url | length > 2048)] | length' "${file}")
  if [[ "${long_urls}" -gt 0 ]]; then
    echo "A builder url can be at most 2048 characters long."
    exit 1
  fi
# No two entries may share both url and auth_data. An omitted auth_data is derived from the url,
# so two entries with the same url and no auth_data will be rejected by the validator client.
  dupes=$(jq -r '[.builders[] | [.url, (.auth_data // "")] | @tsv] | group_by(.) | map(select(length > 1)) | length' "${file}")
  if [[ "${dupes}" -gt 0 ]]; then
    echo "This configuration has duplicate builders. No two entries can share both their url and"
    echo "their auth_data, and an entry without auth_data gets one derived from its url."
    jq -r '.builders[] | [.url, (.auth_data // "")] | @tsv' "${file}" | sort | uniq -d | cut -f1 | sed 's/^/  /'
    exit 1
  fi
}


# Tell the user which values are now pinned rather than following the validator client
# This is called as __builder_report_pinned "<merged file>"
__builder_report_pinned() {
  local file=$1
  local candidates=()
  local pinned=()
  local field

# A field the user did not give on the command line, but that is in the document we just stored,
# is now fixed for this validator. We cannot tell whether it was already fixed before, because
# the API only ever hands back the resolved configuration.
  [[ -z "${__builder_urls}" ]] && candidates+=( "builders" )
  [[ -z "${__min_bid}" ]] && candidates+=( "min_bid" )
  [[ -z "${__boost_factor}" ]] && candidates+=( "builder_boost_factor" )

  for field in ${candidates[@]+"${candidates[@]}"}; do
    if [[ "$(jq -r --arg f "${field}" 'has($f)' "${file}")" = "true" ]]; then
      pinned+=( "${field}" )
    fi
  done
  if [[ "${#pinned[@]}" -eq 0 ]]; then
    return
  fi

  echo "These values are now stored for this validator and will no longer follow the"
  echo "validator client's configuration:"
  for field in "${pinned[@]}"; do
    if [[ "${field}" = "builders" ]]; then
      printf '  %-22s%s\n' "builders" "$(jq -r '[.builders[].url] | join(", ") | if . == "" then "none, p2p bids only" else . end' "${file}")"
    else
      printf '  %-22s%s\n' "${field}" "$(jq -r --arg f "${field}" '.[$f]' "${file}")"
    fi
  done
  echo "Run \"ethd keys delete-builder ${__pubkey}\" to follow EPBS_* in .env again."
}


# Parse the arguments for the builder configuration commands. keymanager.sh is otherwise
# positional, but a nested document needs real options.
# This is called as __parse_builder_args "<action>" "$@", with "$@" starting at the selector
__parse_builder_args() {
  local action=$1
  shift

  __pubkey_selector=$1
  __pubkey=$1
  if [[ -n "$1" ]]; then
    shift
  fi
  if [[ "${action}" = "set-builder" && -n "$1" && "$1" != -* ]]; then
    __builder_urls=$1
    shift
  fi
  while [[ -n "${1+x}" ]]; do
    case "$1" in
      --json)
        __json_out=1
        shift
        ;;
      --json-body)
        if [[ -z "${2+x}" ]]; then
          echo "--from-json needs a file name"
          exit 1
        fi
        __json_body=$2
        shift 2
        ;;
      --from-json)
        echo "--from-json should have been turned into the file contents by ethd. This is a bug, please report."
        exit 70
        ;;
      --min-bid)
        if [[ -z "${2+x}" ]]; then
          echo "--min-bid needs a value in ETH, for example 0.01"
          exit 1
        fi
        __min_bid=$2
        shift 2
        ;;
      --boost-factor)
        if [[ -z "${2+x}" ]]; then
          echo "--boost-factor needs a value: \"local\", \"maxprofit\", \"always\", or a number"
          exit 1
        fi
        __boost_factor=$2
        shift 2
        ;;
      --debug|--trace)
        shift
        ;;
      *)
        echo "Error: Unknown option for ${action}: $1" >&2
        exit 1
        ;;
    esac
  done
}


# Prysm answers any path it does not serve with 200 and an empty body, instead of 404. For the
# builder configuration API an empty 200 therefore means "not served", as a 404 would.
# Drop this once Prysm is fixed.
__builder_empty_as_unserved() {
  if [[ "${__code}" = "200" && -z "${__result//[[:space:]]/}" ]]; then
    __code=501
  fi
}


builder-get() {
  __check_pubkey "${__pubkey}"
  __get_token
  __api_path="eth/v1/validator/${__pubkey}/builder_config"
  __api_data=""
  __http_method=GET
  __call_api
  __builder_empty_as_unserved
  case "${__code}" in
    200)
      if [[ "${__json_out}" -eq 1 ]]; then
        echo "${__result}" | jq '.data'
      else
        echo "The builder configuration in effect for the validator with public key ${__pubkey} is:"
        echo "${__result}" | jq -r '.data |
          "  minimum bid          \(.min_bid // "not set") Gwei",
          "  boost factor         \(.builder_boost_factor // "not set")",
          (if (.builders | length) == 0 then "  builders             none, this validator uses p2p bids only"
           else "  builders:", (.builders[] |
             "    \(.url)"
             + (if .min_bid then "\n      minimum bid           \(.min_bid) Gwei" else "" end)
             + (if .max_execution_payment then "\n      max execution payment \(.max_execution_payment) Gwei" else "" end)
             + (if .builder_boost_factor then "\n      boost factor          \(.builder_boost_factor)" else "" end)
             + (if (.builder_pubkeys // [] | length) > 0 then "\n      builder pubkeys       \(.builder_pubkeys | join(", "))" else "" end))
           end)'
        echo
        echo "This is the resolved configuration: values this validator does not set of its own are"
        echo "shown as the validator client will use them. Storing it back with set-builder --from-json"
        echo "fixes those values, instead of leaving them to follow EPBS_* in .env."
      fi
      exit 0;;
    400) echo "The pubkey was formatted wrong. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    401) echo "No authorization token found. This is a bug. Error: $(__print_jq_message "${__result}" '.message')"; exit 70;;
    403) echo "The authorization token is invalid. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    404|405|501)
      echo "The ${__service} client did not serve the builder configuration API."
      echo "Either it does not support it yet, or the validator with public key ${__pubkey} is not known to it."
      echo "Message: $(__print_jq_message "${__result}" '.message')"
      exit 0;;
    500) echo "Internal server error. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    *) echo "Unexpected return code ${__code}. Result: ${__result}"; exit 1;;
  esac
}


builder-set() {
  local updated=0

  if [[ -n "${__json_body}" ]]; then
    if [[ -n "${__builder_urls}" || -n "${__min_bid}" || -n "${__boost_factor}" ]]; then
      echo "--from-json replaces the whole builder configuration, so it cannot be combined with"
      echo "a builder url list, --min-bid, or --boost-factor. Please edit the JSON instead."
      exit 0
    fi
    echo "${__json_body}" >/tmp/builder-patch.json
    __builder_check_document /tmp/builder-patch.json
  else
    if [[ -z "${__builder_urls}" && -z "${__min_bid}" && -z "${__boost_factor}" ]]; then
      echo "Please specify what to set: a builder url list, \"none\", --min-bid, --boost-factor,"
      echo "or a whole configuration with --from-json."
      exit 0
    fi
    __builder_patch
  fi

  __pubkeys_to_array "${__pubkey_selector}" "set the builder configuration"
  __get_token
  for __pubkey in "${__pubkeys[@]}"; do
    if [[ -n "${__json_body}" ]]; then
      cp /tmp/builder-patch.json /tmp/apidata.txt
    else
# The API replaces the configuration in full, so merge the patch onto what is there now.
# jq's * merges objects and replaces arrays, which is what we want for the builders list.
      __api_path="eth/v1/validator/${__pubkey}/builder_config"
      __api_data=""
      __http_method=GET
      __call_api
      __builder_empty_as_unserved
      case "${__code}" in
        200) echo "${__result}" | jq '.data' >/tmp/builder-current.json;;
        404) echo '{}' >/tmp/builder-current.json;;
        405|501)
          echo "The ${__service} client did not serve the builder configuration API."
          echo "Either it does not support it yet, or the validator with public key ${__pubkey} is not known to it."
          exit 0;;
        401) echo "No authorization token found. This is a bug. Error: $(__print_jq_message "${__result}" '.message')"; exit 70;;
        403) echo "The authorization token is invalid. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
        *) echo "Unexpected return code ${__code} while reading the builder configuration for ${__pubkey}. Result: ${__result}"; exit 1;;
      esac
      jq -n --slurpfile cur /tmp/builder-current.json --slurpfile patch /tmp/builder-patch.json \
        '($cur[0] // {}) * $patch[0]' >/tmp/apidata.txt
      __builder_check_document /tmp/apidata.txt
    fi

    __api_path="eth/v1/validator/${__pubkey}/builder_config"
    __api_data=@/tmp/apidata.txt
    __http_method=POST
    __call_api
    __builder_empty_as_unserved
    case "${__code}" in
      202)
        echo "The builder configuration for the validator with public key ${__pubkey} was updated."
        if [[ -z "${__json_body}" ]]; then
          __builder_report_pinned /tmp/apidata.txt
        fi
        (( updated++ ))
        ;;
      400) echo "The configuration was rejected for ${__pubkey}. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
      401) echo "No authorization token found. This is a bug. Error: $(__print_jq_message "${__result}" '.message')"; exit 70;;
      403) echo "The authorization token is invalid. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
      404|405|501)
        echo "The ${__service} client did not serve the builder configuration API."
        echo "Either it does not support it yet, or the validator with public key ${__pubkey} is not known to it."
        echo "Message: $(__print_jq_message "${__result}" '.message')"
        exit 0;;
      500) echo "Internal server error. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
      *) echo "Unexpected return code ${__code}. Result: ${__result}"; exit 1;;
    esac
  done
  if [[ "${#__pubkeys[@]}" -gt 1 ]]; then
    echo "Updated the builder configuration for ${updated} of ${#__pubkeys[@]} validators."
  fi
  exit 0
}


builder-delete() {
  local deleted=0

  __pubkeys_to_array "${__pubkey_selector}" "delete the builder configuration"
  __get_token
  for __pubkey in "${__pubkeys[@]}"; do
    __api_path="eth/v1/validator/${__pubkey}/builder_config"
    __api_data=""
    __http_method=DELETE
    __call_api
    __builder_empty_as_unserved
    case "${__code}" in
      204) echo "The builder configuration for the validator with public key ${__pubkey} was removed, and it follows EPBS_* in .env again."; (( deleted++ ));;
      400) echo "The pubkey was formatted wrong. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
      401) echo "No authorization token found. This is a bug. Error: $(__print_jq_message "${__result}" '.message')"; exit 70;;
      403) echo "A builder configuration was found, but cannot be deleted. It may be in a configuration file. Message: $(__print_jq_message "${__result}" '.message')";;
      404|405|501)
        echo "The ${__service} client did not serve the builder configuration API."
        echo "Either it does not support it yet, or the validator with public key ${__pubkey} is not known to it."
        echo "Message: $(__print_jq_message "${__result}" '.message')"
        exit 0;;
      500) echo "Internal server error. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
      *) echo "Unexpected return code ${__code}. Result: ${__result}"; exit 1;;
    esac
  done
  if [[ "${#__pubkeys[@]}" -gt 1 ]]; then
    echo "Removed the builder configuration for ${deleted} of ${#__pubkeys[@]} validators."
  fi
  exit 0
}


exit-sign() {
  local pubkeys=()
  local keys_to_array
  local skipped=0
  local signed=0
  local vc_api_container
  local vc_service
  local vc_api_port
  local vc_api_tls
  local exitstatus
  local val_status

  if [[ -z "${__pubkey}" ]]; then
    echo "Please specify a validator public key to sign an exit message for, or \"all\""
    exit 0
  fi
  if [[ ! "${__pubkey}" = "all" ]]; then
    __check_pubkey "${__pubkey}"
  fi
  __api_path=eth/v1/keystores
  if [[ "${__pubkey}" = "all" ]]; then
    if [[ "${WEB3SIGNER}" = "true" ]]; then
      __token=NIL
      vc_api_container=${__api_container}
      __api_container=${__w3s_container}
      vc_service=${__service}
      __service=web3signer
      vc_api_port=${__api_port}
      __api_port=${__w3s_port}
      vc_api_tls=${__api_tls}
      __api_tls=false
    else
      __get_token
    fi
    __validator_list_call
    if [[ "$(echo "${__result}" | jq '.data | length')" -eq 0 ]]; then
      echo "No keys loaded, cannot sign anything"
      return
    else
      keys_to_array=$(echo "${__result}" | jq -r '.data[].validating_pubkey' | tr '\n' ' ')
# Word splitting is desired for the array
# shellcheck disable=SC2206
      pubkeys+=( ${keys_to_array} )
      if [[ "${WEB3SIGNER}" = "true" ]]; then
        __api_container=${vc_api_container}
        __api_port=${vc_api_port}
        __api_tls=${vc_api_tls}
        __service=${vc_service}
      fi
    fi
  else
    pubkeys+=( "${__pubkey}" )
  fi

  __get_token
  for __pubkey in "${pubkeys[@]}"; do
# Ask the beacon node first. Validator clients differ in how they report a key that is not in
# state - Lodestar answers 500 - so this keeps the skip path the same on every client.
    __api_path="eth/v1/beacon/states/head/validators/${__pubkey}"
    __api_data=""
    __http_method=GET
    __call_cl_api
    case "${__code}" in
      200)
        val_status=$(echo "${__result}" | jq -r '.data.status')
        case "${val_status}" in
          active_exiting|active_slashed|exited_*|withdrawal_*)
            echo "The key ${__pubkey} is already exiting or has exited, status ${val_status}. No exit message needed."
            (( skipped+=1 ))
            continue
            ;;
        esac
        ;;
      404)
        echo "The key ${__pubkey} is not on the beacon chain. It has to be active with an index on the beacon chain to be able to sign an exit message."
        (( skipped+=1 ))
        continue
        ;;
      *) echo "Unexpected return code ${__code} from the consensus client while looking up ${__pubkey}. Result: ${__result}"; exit 1;;
    esac

    __api_data=""
    __http_method=POST
    __api_path="eth/v1/validator/${__pubkey}/voluntary_exit"
    __call_api
    case "${__code}" in
      200) echo "Signed voluntary exit for validator with public key ${__pubkey}"; (( signed+=1 ));;
      400) echo "The pubkey or limit was formatted wrong. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
      401) echo "No authorization token found. This is a bug. Error: $(__print_jq_message "${__result}" '.message')"; exit 70;;
      403) echo "The authorization token is invalid. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
      404)
        echo "Path not found error. The key ${__pubkey} has to be active with an index on the beacon chain to be able to sign an exit message."
        echo "Error: $(__print_jq_message "${__result}" '.message')"
        (( skipped+=1 ))
        continue
        ;;
      500) echo "Internal server error. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
      *) echo "Unexpected return code ${__code}. Result: ${__result}"; exit 1;;
    esac
    # This is only reached for 200
    __result=$(echo "${__result}" | jq -c '.data')

    echo "${__result}" > "/exit_messages/${__pubkey::10}--${__pubkey:90}-exit.json"
# shellcheck disable=SC2320
    exitstatus=$?
    if [[ "${exitstatus}" -eq 0 ]]; then
      echo "Writing the exit message into file ./.eth/exit_messages/${__pubkey::10}--${__pubkey:90}-exit.json succeeded"
    else
      echo "Error writing exit json to file ./.eth/exit_messages/${__pubkey::10}--${__pubkey:90}-exit.json"
    fi
    echo
  done

  echo "Signed exit messages for ${signed} keys"
  echo "Skipped ${skipped} keys because they weren't found, were not active, or were already exiting on the beacon chain"
}


exit-send() {
  local json_files
  local file
  local validator_index

  shopt -s nullglob
  json_files=(/exit_messages/*.json)

  if [[ ${#json_files[@]} -eq 0 ]]; then
    echo "No exit message files found in \"./.eth/exit_messages\"."
    echo "Aborting."
    exit 1
  fi

  for file in "${json_files[@]}"; do
    validator_index=$(jq '.message.validator_index' "${file}" 2>/dev/null || true)

    if [[ "${validator_index}" != "null" && -n "${validator_index}" ]]; then
      __api_path=eth/v1/beacon/pool/voluntary_exits
      __api_data="$(cat "${file}")"
      __http_method=POST
      __call_cl_api
      case "${__code}" in
        200) echo "Loaded voluntary exit message for validator index ${validator_index}";;
        400) echo "Unable to load the voluntary exit message. Error: $(__print_jq_message "${__result}" '.message')";;
        500) echo "Internal server error. Error: $(__print_jq_message "${__result}" '.message')";;
        *) echo "Unexpected return code ${__code}. Result: ${__result}";;
      esac
      echo
    else
      echo "./.eth/exit_messages/$(basename "${file}") is not a pre-signed exit message."
      echo "Skipping."
    fi
  done
}


__validator_list_call() {
  __api_data=""
  __http_method=GET
  __call_api
  case "${__code}" in
    200) ;;
    401) echo "No authorization token found. This is a bug. Error: $(__print_jq_message "${__result}" '.message')"; exit 70;;
    403) echo "The authorization token is invalid. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    500) echo "Internal server error. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
    *) echo "Unexpected return code ${__code}. Result: ${__result}"; exit 1;;
  esac
}


validator-list() {
  local vc_api_container
  local vc_service
  local vc_api_port
  local vc_api_tls

  __api_path=eth/v1/keystores
  if [[ "${WEB3SIGNER}" = "true" ]]; then
    __token=NIL
    vc_api_container=${__api_container}
    __api_container=${__w3s_container}
    vc_service=${__service}
    __service=web3signer
    vc_api_port=${__api_port}
    __api_port=${__w3s_port}
    vc_api_tls=${__api_tls}
    __api_tls=false
  else
    __get_token
  fi
  __validator_list_call
  if [[ "$(echo "${__result}" | jq '.data | length')" -eq 0 ]]; then
    echo "No keys loaded into ${__service}"
  else
    echo "Validator public keys loaded into ${__service}"
    echo "${__result}" | jq -r '.data[].validating_pubkey'
  fi
  if [[ "${WEB3SIGNER}" = "true" ]]; then
    __get_token
    __api_path=eth/v1/remotekeys
    __api_container=${vc_api_container}
    __service=${vc_service}
    __api_port=${vc_api_port}
    __api_tls=${vc_api_tls}
    __validator_list_call
    if [[ "$(echo "${__result}" | jq '.data | length')" -eq 0 ]]; then
      echo "No remote keys registered with ${__service}"
    else
      echo "Remote keys registered with ${__service}"
      echo "${__result}" | jq -rc '.data[] | [.pubkey, .url] | join(" ")'
    fi
  fi
}


validator-count() {
  local nodes
  local node
  local node_reachable=0
  local vc_api_container
  local vc_service
  local vc_api_port
  local vc_api_tls
  local key_count
  local vals
  local val_state
  local vals_active=0
  local vals_exiting=0
  local vals_exited=0
  local vals_slashed=0
  local vals_pending=0
  local vals_unknown=0

  __api_path=eth/v1/keystores
  if [[ "${WEB3SIGNER}" = "true" ]]; then
    __token=NIL
    vc_api_container=${__api_container}
    __api_container=${__w3s_container}
    vc_service=${__service}
    __service=web3signer
    vc_api_port=${__api_port}
    __api_port=${__w3s_port}
    vc_api_tls=${__api_tls}
    __api_tls=false
  else
    __get_token
  fi
  __validator_list_call
  key_count=$(echo "${__result}" | jq -r '.data | length')
  echo "Validator keys loaded into ${__service}: ${key_count}"

  vals="${__result}"

  if [[ "${WEB3SIGNER}" = "true" ]]; then
    __get_token
    __api_path=eth/v1/remotekeys
    __api_container=${vc_api_container}
    __service=${vc_service}
    __api_port=${vc_api_port}
    __api_tls=${vc_api_tls}
    __validator_list_call
    remote_key_count=$(echo "${__result}" | jq -r '.data | length')
    echo "Remote Validator keys registered with ${__service}: $remote_key_count"
    if [[ "${key_count}" -ne "${remote_key_count}" ]]; then
      echo "WARNING: The number of keys loaded into Web3signer and registered with the validator client differ."
      echo "Please run \"./ethd keys register\""
    fi
  fi

  nodes=$(echo "${CL_NODE}" | tr ',' ' ')
  for node in ${nodes}; do
    if curl -s -m 5 -o /dev/null -w "%{http_code}" "${node}/eth/v1/node/health" | grep -q "^[23]"; then
      node_reachable=1
      break
    fi
  done

  if [[ "${node_reachable}" -eq 0 ]]; then
    echo "No consensus client node is reachable via any URL in ${CL_NODE}"
    exit 1
  fi

  echo "Querying validator state, this may take a minute"
  for __pubkey in $(echo "${vals}" | jq -r '.data[].validating_pubkey'); do
    val_state=$(curl -k -m 60 -s --show-error "${node}/eth/v1/beacon/states/head/validators/${__pubkey}" | jq -r .data.status)
    case "${val_state}" in
      active_ongoing) ((vals_active++));;
      active_exiting) ((vals_exiting++));;
      *_slashed) ((vals_slashed++));;
      exited_unslashed|withdrawal_*) ((vals_exited++));;
      pending_*) ((vals_pending++));;
      unknown|*) ((vals_unknown++));;
    esac
  done

  if [[ "${vals_active}" -gt 0 ]]; then
    echo "Active, unslashed validators: ${vals_active}"
  fi
  if [[ "${vals_exiting}" -gt 0 ]]; then
    echo "Active, exiting validators: ${vals_exiting}"
  fi
  if [[ "${vals_exited}" -gt 0 ]]; then
    echo "Exited and/or withdrawn validators: ${vals_exited}"
  fi
  if [[ "${vals_pending}" -gt 0 ]]; then
    echo "Pending validators: ${vals_pending}"
  fi
  if [[ "${vals_slashed}" -gt 0 ]]; then
    echo "Slashed validators: ${vals_slashed}"
  fi
  if [[ "${vals_unknown}" -gt 0 ]]; then
    echo "Unknown validators, no deposit: ${vals_unknown}"
  fi
}


validator-delete() {
  local vc_api_container
  local vc_api_port
  local vc_api_tls
  local pubkeys=()
  local keys_to_array
  local num_keys
  local yn
  local status
  local file
  local i

  if [[ -z "${__pubkey}" ]]; then
    echo "Please specify a validator public key to delete, or \"all\""
    exit 0
  fi
  if [[ ! "${__pubkey}" = "all" ]]; then
    __check_pubkey "${__pubkey}"
  fi
  __api_path=eth/v1/keystores
  if [[ "${__pubkey}" = "all" ]]; then
    if [[ "${WEB3SIGNER}" = "true" ]]; then
      echo "WARNING - this will delete all currently loaded keys from web3signer and the validator client."
    else
      echo "WARNING - this will delete all currently loaded keys from the validator client."
    fi
    echo
    read -rp "Do you wish to continue with key deletion? (No/yes) " yn
    case "${yn}" in
      [Yy][Ee][Ss]) ;;
      * ) echo "Aborting key deletion"; exit 130;;
    esac
    if [[ "${WEB3SIGNER}" = "true" ]]; then
      __token=NIL
      vc_api_container=${__api_container}
      __api_container=${__w3s_container}
      vc_api_port=${__api_port}
      __api_port=${__w3s_port}
      vc_api_tls=${__api_tls}
      __api_tls=false
    else
      __get_token
    fi

    __validator_list_call
    if [[ "$(echo "${__result}" | jq '.data | length')" -eq 0 ]]; then
      echo "No keys loaded, cannot delete anything"
      return
    else
      keys_to_array=$(echo "${__result}" | jq -r '.data[].validating_pubkey' | tr '\n' ' ')
# Word splitting is desired for the array
# shellcheck disable=SC2206
      pubkeys+=( ${keys_to_array} )
      if [[ "${WEB3SIGNER}" = "true" ]]; then
        __api_container=${vc_api_container}
        __api_port=${vc_api_port}
        __api_tls=${vc_api_tls}
      fi
    fi
  else
    pubkeys+=( "${__pubkey}" )
  fi
  num_keys=${#pubkeys[@]}
  i=0
  for __pubkey in "${pubkeys[@]}"; do
    (( i+=1 ))
    echo "Deleting key ${i} of ${num_keys}"
    # Remove remote registration, with a path not to
    if [[ "${WEB3SIGNER}" = "true" ]]; then
      if [[ -z "${W3S_NOREG+x}" ]]; then
        __get_token
        __api_path=eth/v1/remotekeys
        __api_data="{\"pubkeys\":[\"${__pubkey}\"]}"
        __http_method=DELETE
        __call_api
        case "${__code}" in
          200) ;;
          401) echo "No authorization token found. This is a bug. Error: $(__print_jq_message "${__result}" '.message')"; exit 70;;
          403) echo "The authorization token is invalid. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
          500) echo "Internal server error. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
          *) echo "Unexpected return code ${__code}. Result: ${__result}"; exit 1;;
        esac

        status=$(echo "${__result}" | jq -r '.data[].status')
        case "${status,,}" in
          error)
            echo "Remote registration for validator ${__pubkey} was found but an error was encountered trying \
to delete it:"
            echo "${__result}" | jq -r '.data[].message'
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
            echo "Unexpected status ${status}. This may be a bug"
            exit 70
            ;;
        esac
      else
        echo "This client loads web3signer keys at startup, no registration to remove."
      fi
    fi

    if [[ "${WEB3SIGNER}" = "true" ]]; then
      __token=NIL
      vc_api_container=${__api_container}
      __api_container=${__w3s_container}
      vc_api_port=${__api_port}
      __api_port=${__w3s_port}
      vc_api_tls=${__api_tls}
      __api_tls=false
    else
      __get_token
    fi

    __api_path=eth/v1/keystores
    __api_data="{\"pubkeys\":[\"${__pubkey}\"]}"
    __http_method=DELETE
    __call_api
    case "${__code}" in
      200) ;;
      400) echo "The pubkey was formatted wrong. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
      401) echo "No authorization token found. This is a bug. Error: $(__print_jq_message "${__result}" '.message')"; exit 70;;
      403) echo "The authorization token is invalid. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
      500) echo "Internal server error. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
      *) echo "Unexpected return code ${__code}. Result: ${__result}"; exit 1;;
    esac

    status=$(echo "${__result}" | jq -r '.data[].status')
    case "${status,,}" in
      error)
        echo "Validator ${__pubkey} was found but an error was encountered trying to delete it:"
        echo "${__result}" | jq -r '.data[].message'
        ;;
      not_active)
        file=validator_keys/slashing_protection-${__pubkey::10}--${__pubkey:90}.json
        echo "Validator ${__pubkey} is not actively loaded."
        echo "${__result}" | jq '.slashing_protection | fromjson' > /"${file}"
        chmod 644 /"${file}"
        echo "Slashing protection data written to .eth/${file}"
        ;;
      deleted)
        file=validator_keys/slashing_protection-${__pubkey::10}--${__pubkey:90}.json
        echo "Validator ${__pubkey} deleted."
        echo "${__result}" | jq '.slashing_protection | fromjson' > /"${file}"
        chmod 644 /"${file}"
        echo "Slashing protection data written to .eth/${file}"
        ;;
      not_found)
        echo "The validator ${__pubkey} was not found in the keystore, no slashing protection data returned."
        ;;
      * )
        echo "Unexpected status ${status}. This may be a bug"
        exit 70
        ;;
    esac
    if [[ "${WEB3SIGNER}" = "true" ]]; then
      __api_container=${vc_api_container}
      __api_port=${vc_api_port}
      __api_tls=${vc_api_tls}
    fi
    echo
  done
}


validator-import() {
  local vc_api_container
  local vc_api_port
  local vc_api_tls
  local depth=1
  local key_root_dir="/validator_keys"
  local num_dirs
  local num_files
  local imported=0
  local skipped=0
  local errored=0
  local registered=0
  local reg_skipped=0
  local reg_errored=0
  local justone
  local found_one
  local do_a_protec
  local status
  local password
  local password2
  local protect_json
  local protect_file
  local keystore_json
  local keydir
  local keyfile
  local passfile
  local yn
  local i

  __eth2_val_tools=0

  num_dirs=$(find /validator_keys -maxdepth 1 -type d -name '0x*' | wc -l)
  if [[ "${__pass}" -eq 1 && "${num_dirs}" -gt 0 ]]; then
    echo "Found ${num_dirs} directories starting with 0x. If these are from eth2-val-tools, please copy the keys \
and secrets directories into .eth/validator_keys instead."
    echo
  fi

  if [[ "${__pass}" -eq 1 && -d /validator_keys/keys ]]; then
    if [[ -d /validator_keys/secrets ]]; then
      echo "keys and secrets directories found, assuming keys generated by eth2-val-tools"
      echo "Keystore files directly under .eth/validator_keys will be imported in a second pass"
      echo
      __eth2_val_tools=1
      depth=2
      key_root_dir=/validator_keys/keys
    else
      echo "Found a keys directory but no secrets directory. This may be an incomplete eth2-val-tools output. Skipping."
      echo
    fi
  fi
  num_files=$(find "${key_root_dir}" -maxdepth "${depth}" -type f -name '*keystore*.json' | wc -l)
  if [[ "${num_files}" -eq 0 ]]; then
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
    password="${KEYSTORE_PASSWORD}"
    justone=1
  else
    echo "You are about to import ${num_files} keys."
    echo
    echo "WARNING - imported keys are immediately live. If these keys exist elsewhere,"
    echo "you WILL get slashed. If it has been less than 15 minutes since you deleted them elsewhere,"
    echo "you are at risk of getting slashed. Exercise caution"
    echo
    while true; do
      read -rp "I understand these dire warnings and wish to proceed with key import (No/yes) " yn
      case "${yn}" in
        [Yy][Ee][Ss]) break;;
        [Nn]* ) echo "Aborting import"; exit 130;;
        * ) echo "Please answer yes or no.";;
      esac
    done
    if [[ "$__eth2_val_tools" -eq 0 && "${num_files}" -gt 1 ]]; then
      while true; do
        read -rp "Do all validator keys have the same password? (y/n) " yn
        case "${yn}" in
          [Yy]* ) justone=1; break;;
          [Nn]* ) justone=0; break;;
          * ) echo "Please answer yes or no.";;
        esac
      done
    else
      justone=1
    fi
    if [[ "$__eth2_val_tools" -eq 0 && "${justone}" -eq 1 ]]; then
      while true; do
        read -srp "Please enter the password for your validator key(s): " password
        echo
        read -srp "Please re-enter the password: " password2
        echo
        if [[ "${password}" == "${password2}" ]]; then
          break
        else
          echo "The two entered passwords do not match, please try again."
          echo
        fi
      done
      echo
    fi
  fi
  reg_errored=0
  i=0
# See https://www.shellcheck.net/wiki/SC2044 as for why
# Using file descriptor 3 so this doesn't conflict with the "different passwords" read
# Could also use dialog, but would need to make sure it exists
  while IFS= read -r -u 3 keyfile; do
    (( i+=1 ))  # Deliberately up here: Users can see skipped files in the sequence, and it always ends at N/N
    [[ -f "${keyfile}" ]] || { (( skipped+=1 )); continue; }
    keydir=$(dirname "${keyfile}")
    __pubkey=0x$(jq -r '.pubkey' "${keyfile}")
    if [[ "${__pubkey}" = "0xnull" ]]; then
      echo "The file ${keyfile} does not specify a pubkey. Maybe it is a Prysm wallet file?"
      echo "Even for Prysm, please use the individual keystore files as generated by staking-deposit-cli, or for eth2-val-tools copy the keys and secrets directories into .eth/validator_keys."
      echo "Skipping."
      echo
      (( skipped+=1 ))
      continue
    fi
    if [[ "$__eth2_val_tools" -eq 1 ]]; then
      if [[ -f /validator_keys/secrets/"$(basename "${keydir}")" ]]; then
        password=$(</validator_keys/secrets/"$(basename "${keydir}")")
      else
        echo "Password file /validator_keys/secrets/$(basename "${keydir}") not found. Skipping key import."
        (( skipped+=1 ))
        continue
      fi
    fi
    if [[ "$__eth2_val_tools" -eq 0 && "${justone}" -eq 0 ]]; then
      while true; do
        passfile=${keyfile/.json/.txt}
        if [[ -f "${passfile}" ]]; then
          echo "Password file is found: ${passfile}"
          password=$(< "${passfile}")
          break
        else
          echo "Password file ${passfile} not found."
        fi
        read -srp "Please enter the password for your validator key stored in ${keyfile} with public key ${__pubkey}: " password
        echo
        read -srp "Please re-enter the password: " password2
        echo
        if [[ "${password}" == "${password2}" ]]; then
          break
        else
          echo "The two entered passwords do not match, please try again."
          echo
        fi
        echo
      done
    fi
    found_one=0
    do_a_protec=0
    for protect_file in "${keydir}"/slashing_protection*.json; do
      [[ -f "${protect_file}" ]] || continue
      if grep -q "${__pubkey}" "${protect_file}"; then
        found_one=1
        echo "Found slashing protection import file ${protect_file} for ${__pubkey}"
        if [[ "$(jq ".data[] | select(.pubkey==\"${__pubkey}\") | .signed_blocks | length" < "${protect_file}")" -gt 0 \
          || "$(jq ".data[] | select(.pubkey==\"${__pubkey}\") | .signed_attestations | length" < "${protect_file}")" -gt 0 ]]; then
          do_a_protec=1
          echo "It will be imported"
        else
          echo "WARNING: The file does not contain importable data and will be skipped."
          echo "Your validator will be imported WITHOUT slashing protection data."
        fi
        break
      fi
    done
    if [[ "$__eth2_val_tools" -eq 0 && "${found_one}" -eq 0 ]]; then
      echo "No viable slashing protection import file found for ${__pubkey}."
      echo "This is expected if this is a new key."
      echo "Proceeding without slashing protection import."
    fi
    keystore_json=$(< "${keyfile}")
    if [[ "${do_a_protec}" -eq 1 ]]; then
      protect_json=$(jq "select(.data[].pubkey==\"${__pubkey}\") | tojson" < "${protect_file}")
    else
      protect_json=""
    fi
    echo "${protect_json}" > /tmp/protect.json

    if [[ "${__debug}" -eq 1 ]]; then
      echo "The keystore reads as ${keystore_json}"
      echo "And your password is ${password}"
      set +e
      echo "Testing jq on these"
      jq --arg keystore_value "${keystore_json}" --arg password_value "${password}" '. | .keystores += [$keystore_value] | .passwords += [$password_value]' <<< '{}'
      set -e
    fi
    if [[ "${do_a_protec}" -eq 0 ]]; then
      jq --arg keystore_value "${keystore_json}" --arg password_value "${password}" '. | .keystores += [$keystore_value] | .passwords += [$password_value]' <<< '{}' >/tmp/apidata.txt
    else
      jq --arg keystore_value "${keystore_json}" --arg password_value "${password}" --slurpfile protect_value /tmp/protect.json '. | .keystores += [$keystore_value] | .passwords += [$password_value] | . += {slashing_protection: $protect_value[0]}' <<< '{}' >/tmp/apidata.txt
    fi

    echo "Processing file ${i} of ${num_files} for key import. ${skipped} skipped files so far."
    if [[ "${WEB3SIGNER}" = "true" ]]; then
      __token=NIL
      vc_api_container=${__api_container}
      __api_container=${__w3s_container}
      vc_api_port=${__api_port}
      __api_port=${__w3s_port}
      vc_api_tls=${__api_tls}
      __api_tls=false
    else
      __get_token
    fi

    __api_data=@/tmp/apidata.txt
    __api_path=eth/v1/keystores
    __http_method=POST
    __call_api
    case "${__code}" in
      200) ;;
      400) echo "The pubkey was formatted wrong. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
      401) echo "No authorization token found. This is a bug. Error: $(__print_jq_message "${__result}" '.message')"; exit 70;;
      403) echo "The authorization token is invalid. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
      500) echo "Internal server error. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
      *) echo "Unexpected return code ${__code}. Result: ${__result}"; exit 1;;
    esac
    if ! echo "${__result}" | grep -q "data"; then
     echo "The key manager API query failed. Output:"
     echo "${__result}"
     exit 1
    fi
    status=$(echo "${__result}" | jq -r '.data[].status')
    case "${status,,}" in
      error)
        echo "An error was encountered trying to import the key ${__pubkey}:"
        echo "${__result}" | jq -r '.data[].message'
        echo
        (( errored+=1 ))
        continue
        ;;
      imported)
        echo "Validator key was successfully imported: ${__pubkey}"
        (( imported+=1 ))
        ;;
      duplicate)
        echo "Validator key is a duplicate and was skipped: ${__pubkey}"
        (( skipped+=1 ))
        ;;
      *)
        echo "Unexpected status ${status}. This may be a bug"
        exit 70
        ;;
    esac
    # Add remote registration, with a path not to
    if [[ "${WEB3SIGNER}" = "true" ]]; then
      if [[ -z "${W3S_NOREG+x}" ]]; then
        __api_container=${vc_api_container}
        __api_port=${vc_api_port}
        __api_tls=${vc_api_tls}
# shellcheck disable=SC2153
        jq --arg pubkey_value "${__pubkey}" --arg url_value "${W3S_NODE}" '. | .remote_keys += [{"pubkey": $pubkey_value, "url": $url_value}]' <<< '{}' >/tmp/apidata.txt

        __get_token
        __api_data=@/tmp/apidata.txt
        __api_path=eth/v1/remotekeys
        __http_method=POST
        __call_api
        case "${__code}" in
          200) ;;
          401) echo "No authorization token found. This is a bug. Error: $(__print_jq_message "${__result}" '.message')"; exit 70;;
          403) echo "The authorization token is invalid. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
          500) echo "Internal server error. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
          *) echo "Unexpected return code ${__code}. Result: ${__result}"; exit 1;;
        esac
        if ! echo "${__result}" | grep -q "data"; then
         echo "The key manager API query failed. Output:"
         echo "${__result}"
         exit 1
        fi
        status=$(echo "${__result}" | jq -r '.data[].status')
        case "${status,,}" in
          error)
            echo "An error was encountered trying to register the key ${__pubkey}:"
            echo "${__result}" | jq -r '.data[].message'
            (( reg_errored+=1 ))
            ;;
          imported)
            echo "Validator key was successfully registered with validator client: ${__pubkey}"
            (( registered+=1 ))
            ;;
          duplicate)
            echo "Validator key is a duplicate and registration was skipped: ${__pubkey}"
            (( reg_skipped+=1 ))
            ;;
          *)
            echo "Unexpected status ${status}. This may be a bug"
            exit 70
            ;;
        esac
      else
        echo "This client loads web3signer keys at startup, skipping registration via keymanager."
      fi
    fi
    echo
  done 3< <(find "${key_root_dir}" -maxdepth "${depth}" -name '*keystore*.json')

  echo "Imported ${imported} keys"
  if [[ "${WEB3SIGNER}" = "true" ]]; then
    echo "Registered ${registered} keys with the validator client"
  fi
  echo "Skipped ${skipped} keys"
  if [[ "${WEB3SIGNER}" = "true" ]]; then
    echo "Skipped registration of ${reg_skipped} keys"
  fi
  if [[ "${errored}" -gt 0 ]]; then
    echo "${errored} keys caused an error during import"
  fi
  if [[ "${reg_errored}" -gt 0 ]]; then
    echo "${reg_errored} keys caused an error during registration"
  fi
  echo
  echo "IMPORTANT: Only import keys in ONE LOCATION."
  echo "Failure to do so will get your validators slashed: 0.0078 ETH penalty per 32 staked ETH slashed, and forced exit."
}


validator-register() {
  local vc_api_container
  local vc_api_port
  local vc_api_tls
  local status
  local registered=0
  local reg_skipped=0
  local reg_errored=0
  local w3s_pubkeys

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
  vc_api_container=${__api_container}
  __api_container=${__w3s_container}
  vc_api_port=${__api_port}
  __api_port=${__w3s_port}
  vc_api_tls=${__api_tls}
  __api_tls=false
  __validator_list_call
  if [[ "$(echo "${__result}" | jq '.data | length')" -eq 0 ]]; then
    echo "No keys loaded in web3signer, aborting."
    exit 1
  fi

  __api_container=${vc_api_container}
  __api_port=${vc_api_port}
  __api_tls=${vc_api_tls}
  __get_token

  w3s_pubkeys="$(echo "${__result}" | jq -r '.data[].validating_pubkey')"
  while IFS= read -r __pubkey; do
     jq --arg pubkey_value "${__pubkey}" --arg url_value "${W3S_NODE}" '. | .remote_keys += [{"pubkey": $pubkey_value, "url": $url_value}]' <<< '{}' >/tmp/apidata.txt

    __api_data=@/tmp/apidata.txt
    __api_path=eth/v1/remotekeys
    __http_method=POST
    __call_api
    case "${__code}" in
      200) ;;
      401) echo "No authorization token found. This is a bug. Error: $(__print_jq_message "${__result}" '.message')"; exit 70;;
      403) echo "The authorization token is invalid. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
      500) echo "Internal server error. Error: $(__print_jq_message "${__result}" '.message')"; exit 1;;
      *) echo "Unexpected return code ${__code}. Result: ${__result}"; exit 1;;
    esac
    if ! echo "${__result}" | grep -q "data"; then
     echo "The key manager API query failed. Output:"
     echo "${__result}"
     exit 1
    fi
    status=$(echo "${__result}" | jq -r '.data[].status')
    case "${status,,}" in
      error)
        echo "An error was encountered trying to register the key ${__pubkey}:"
        echo "${__result}" | jq -r '.data[].message'
        echo
        (( reg_errored+=1 ))
        ;;
      imported)
        echo "Validator key was successfully registered with validator client: ${__pubkey}"
        echo
        (( registered+=1 ))
        ;;
      duplicate)
        echo "Validator key is a duplicate and registration was skipped: ${__pubkey}"
        echo
        (( reg_skipped+=1 ))
        ;;
      *)
        echo "Unexpected status ${status}. This may be a bug"
        exit 70
        ;;
    esac
  done <<< "${w3s_pubkeys}"

  echo "Registered ${registered} keys with the validator client"
  echo "Skipped registration of ${reg_skipped} keys"
  if [[ "${reg_errored}" -gt 0 ]]; then
      echo "${reg_errored} keys caused an error during registration"
  fi
  echo
}


# Verify keys only exist in one location
__web3signer_check() {
  if [[ -z "${PRYSM:+x}" && ! "${WEB3SIGNER}" = "true" ]]; then
    __get_token
    __api_path=eth/v1/remotekeys
    __validator_list_call
    if [[ ! "$(echo "${__result}" | jq '.data | length')" -eq 0 ]]; then
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
  echo "  get-builder 0xPUBKEY [--json]"
  echo "      Show the builder configuration in effect for the validator with public key 0xPUBKEY"
  echo "      Validators will use EPBS_BUILDER_URLS, EPBS_MIN_BID and EPBS_BUILD_FACTOR in .env"
  echo "      by default, if not set individually"
  echo "      This is the resolved configuration: values this validator does not set of its own"
  echo "      are shown as the validator client will use them"
  echo "      \"--json\" prints it as the JSON that set-builder --from-json expects. Storing it"
  echo "      back fixes those values, instead of leaving them to follow .env"
  echo "  set-builder 0xPUBKEY | all | 0xPUBKEY,0xPUBKEY URL[,URL...] | none [OPTIONS]"
  echo "      Set the builders for the validator with public key 0xPUBKEY, from a comma-separated"
  echo "      list of URLs, in the same format as EPBS_BUILDER_URLS in .env"
  echo "      \"all\" sets all detected validators, and a comma-separated list of public keys"
  echo "      sets just those"
  echo "      \"none\" stores a configuration that uses no builders, so the validator uses p2p"
  echo "      bids only. This is not the same as delete-builder, which follows .env again"
  echo "      Options, which can also be given on their own to change only that value:"
  echo "        --min-bid ETH"
  echo "            Minimum bid to accept, in ETH, for example 0.01. The JSON uses Gwei"
  echo "        --boost-factor local | maxprofit | always | NUMBER"
  echo "            How to weigh builder bids against a locally built block."
  echo "            \"local\" prefers the local block, \"maxprofit\" takes whichever pays more,"
  echo "            \"always\" prefers the builder. A number is a percentage multiplier, where"
  echo "            below 100 disfavors builders and above 100 favors them."
  echo "            Note this is not the same scale as EPBS_BUILD_FACTOR in .env, where 100"
  echo "            means \"always\" and here it means \"maxprofit\""
  echo "        --from-json FILE | -"
  echo "            Set the whole configuration from a JSON file, or \"-\" for standard input."
  echo "            Use this for builder pubkeys, authentication data, per-builder payment caps"
  echo "            and per-builder boost factors, which the options above do not cover."
  echo "            This replaces the configuration in full and cannot be combined with the"
  echo "            options above. Start from \"get-builder 0xPUBKEY --json\""
  echo "  delete-builder 0xPUBKEY | all | 0xPUBKEY,0xPUBKEY"
  echo "      Delete the individual builder configuration, so the validator follows EPBS_BUILDER_URLS,"
  echo "      EPBS_MIN_BID and EPBS_BUILD_FACTOR in .env again"
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
      get-api-token
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
  if [[ -f "${__token_file}" ]]; then
    chmod 1777 /tmp  # A user had 755 and root:984. Root cause unknown; work around it
    cp "${__token_file}" /tmp/api-token.txt
    chown "${OWNER_UID:-1000}":"${OWNER_UID:-1000}" /tmp/api-token.txt
    exec gosu "${OWNER_UID:-1000}":"${OWNER_UID:-1000}" "${BASH_SOURCE[0]}" "$@"
  else
    echo "File ${__token_file} not found."
    echo "The ${__service} service may not be fully started yet."
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
    if [[ "${__eth2_val_tools}" -eq 1 ]]; then
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
  get-builder)
    shift 3
    __parse_builder_args get-builder "$@"
    builder-get
    ;;
  set-builder)
    shift 3
    __parse_builder_args set-builder "$@"
    builder-set
    ;;
  delete-builder)
    shift 3
    __parse_builder_args delete-builder "$@"
    builder-delete
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
