#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R teku:teku /var/lib/teku
  exec gosu teku docker-entrypoint-vc.sh "$@"
fi


__normalize_int() {
  local v=$1
  # Strip leading zeros as text. Arithmetic would overflow on the largest boost factors
  if [[ "${v}" =~ ^0*([0-9]+)$ ]]; then
    v="${BASH_REMATCH[1]}"
  fi
  printf '%s' "${v}"
}

__normalize_float() {
  local v=$1
  local int_part
  local frac_part

  if [[ "${v}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    int_part="${v%%.*}"
    frac_part=""
    if [[ "${v}" == *.* ]]; then
      frac_part="${v#*.}"
    fi
    # Strip leading zeros as text, as in __normalize_int
    [[ "${int_part}" =~ ^0*([0-9]+)$ ]] && int_part="${BASH_REMATCH[1]}"
    if [[ -n "${frac_part}" ]]; then
      v="${int_part}.${frac_part}"
    else
      v="${int_part}"
    fi
  fi
  printf '%s' "${v}"
}


if [[ "${NETWORK}" =~ ^https?:// ]]; then
  echo "Custom testnet at ${NETWORK}"
  repo=$(awk -F'/tree/' '{print $1}' <<< "${NETWORK}")
  branch=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f1)
  config_dir=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f2-)
  echo "This appears to be the ${repo} repo, branch ${branch} and config directory ${config_dir}."
  if [[ ! -d "/var/lib/teku/testnet/${config_dir}" ]]; then
    mkdir -p /var/lib/teku/testnet
    cd /var/lib/teku/testnet
    git init --initial-branch="${branch}"
    git remote add origin "${repo}"
    git config core.sparseCheckout true
    echo "${config_dir}" > .git/info/sparse-checkout
    git pull origin "${branch}"
  fi
  __network="--network=/var/lib/teku/testnet/${config_dir}/config.yaml"
else
  __network="--network=${NETWORK}"
fi

if [[ -f /var/lib/teku/teku-keyapi.keystore ]]; then
    if [[ "$(date +%s -r /var/lib/teku/teku-keyapi.keystore)" -lt "$(date +%s --date="300 days ago")" ]]; then
       rm /var/lib/teku/teku-keyapi.keystore
    elif ! openssl x509 -noout -ext subjectAltName -in /var/lib/teku/teku-keyapi.crt | grep -q "DNS:${VC_ALIAS}"; then
       rm /var/lib/teku/teku-keyapi.keystore
    fi
fi

if [[ ! -f /var/lib/teku/teku-keyapi.keystore ]]; then
  password=$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)
  echo "${password}" > /var/lib/teku/teku-keyapi.password
  openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes -keyout /var/lib/teku/teku-keyapi.key -out /var/lib/teku/teku-keyapi.crt -subj '/CN=teku-keyapi-cert' -extensions san -config <( \
    echo '[req]'; \
    echo 'distinguished_name=req'; \
    echo '[san]'; \
    echo "subjectAltName=DNS:localhost,DNS:consensus,DNS:validator,DNS:${VC_ALIAS},IP:127.0.0.1")
  openssl pkcs12 -export -in /var/lib/teku/teku-keyapi.crt -inkey /var/lib/teku/teku-keyapi.key -out /var/lib/teku/teku-keyapi.keystore -name teku-keyapi -passout pass:"${password}"
fi

# Check whether we should enable doppelganger protection
if [[ "${DOPPELGANGER}" = "true" ]]; then
  __doppel="--doppelganger-detection-enabled=true"
  echo "Doppelganger protection enabled, VC will pause for 2 epochs"
else
  __doppel=""
fi

# Check whether we should register with MEV Boost
if [[ "${MEV_BOOST}" = "true" ]]; then
  if [[ "$(__normalize_int "${EPBS_BUILD_FACTOR}")" =~ ^(0|local)$ ]]; then
    __mev_boost=""
    echo "Disabled MEV Boost registration because EPBS_BUILD_FACTOR is ${EPBS_BUILD_FACTOR}."
    echo "WARNING: This conflicts with MEV_BOOST true. Set a factor above 0, or maxprofit or always"
  else
    __mev_boost="--validators-builder-registration-default-enabled"
  fi
else
  __mev_boost=""
fi

# Adjust RIGHT after each network's Glamsterdam hardfork
# MEV Boost implies ePBS builders only on networks that haven't forked yet
if [[ "${MEV_BOOST}" = "true" && "${NETWORK}" =~ ^(sepolia|hoodi|mainnet)$ ]]; then
  __mev_active=1
else
  __mev_active=0
fi

# Check whether we should use ePBS
if [[ "${__mev_active}" -eq 1 || "${EPBS_BUILDERS}" = "true" ]]; then
  if [[ "${__mev_active}" -eq 1 ]]; then
    echo "MEV Boost enabled"
    if [[ "${EPBS_BUILDERS}" = "false" ]]; then
      echo "ePBS builders are meant to be disabled, but MEV Boost is true, which will enable them anyway."
      echo "Update Eth Docker again after ${NETWORK}'s Glamsterdam hard fork to fix this."
    else
      echo "Update Eth Docker again after mainnet Glamsterdam hard fork, expected December 2026, to remove MEV Boost."
    fi
  fi
  if [[ "${EPBS_BUILDERS}" = "true" ]]; then
    echo "ePBS builders enabled"
  fi

  build_factor="$(__normalize_int "${EPBS_BUILD_FACTOR}")"
  if [[ "${build_factor}" = "maxprofit" ]]; then
    build_factor=100  # 100 means profit maximization, as in the keymanager API
  fi
  case "${build_factor}" in
    0|local)
      __epbs="--Xbuilder-boost-factor=0"
      echo "Build blocks locally, use ePBS builders as fallback. EPBS_BUILD_FACTOR is ${build_factor}."
      ;;
    always)
      __epbs="--Xbuilder-boost-factor=18446744073709551615"
      echo "Always prefer ePBS builder blocks, EPBS_BUILD_FACTOR always"
      ;;
    "")
      __epbs=""
      echo "Use default --Xbuilder-boost-factor"
      ;;
    *)
      if [[ "${build_factor}" =~ ^[1-9][0-9]{0,19}$ ]]; then
        # Compare as text, bash arithmetic cannot hold uint64. Equal length makes this a numeric comparison
        # shellcheck disable=SC2071
        if [[ ${#build_factor} -eq 20 && "${build_factor}" > "18446744073709551615" ]]; then
          echo "EPBS_BUILD_FACTOR ${build_factor} exceeds the 64-bit maximum, capping it to 18446744073709551615"
          build_factor=18446744073709551615
        fi
        __epbs="--Xbuilder-boost-factor=${build_factor}"
        echo "Enabled ePBS Build Factor of ${build_factor}"
      else
        __epbs=""
        echo "WARNING: EPBS_BUILD_FACTOR has an invalid value of \"${build_factor}\""
      fi
      ;;
  esac
  if [[ -n "${EPBS_MIN_BID}" ]]; then
    min_bid="$(__normalize_float "${EPBS_MIN_BID}")"
    if [[ "${min_bid}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      min_bid_gwei=$(awk -v v="${min_bid}" 'BEGIN{printf "%.0f", v * 1000000000}')
      __epbs+=" --Xbuilder-min-bid=${min_bid_gwei}"
    else
      echo "WARNING: EPBS_MIN_BID has an invalid value of \"${EPBS_MIN_BID}\", ignoring"
    fi
  fi
# Compose keeps the newlines of a multi-line EPBS_BUILDER_URLS, which would create an empty entry from "url,<newline>"
  builder_urls="${EPBS_BUILDER_URLS//[[:space:]]/}"
  if [[ -n "${builder_urls}" ]]; then
    __epbs+=" --Xbuilder-urls=${builder_urls}"
  fi
else
  __epbs="--Xbuilder-boost-factor=0"
  echo "Build blocks locally, use ePBS builders as fallback"
fi

# Web3signer URL
if [[ "${WEB3SIGNER}" = "true" ]]; then
  __w3s_url="--validators-external-signer-url ${W3S_NODE}"
#  while true; do
#    if curl -s -m 5 ${W3S_NODE} &> /dev/null; then
#      echo "web3signer is up, starting Teku"
#      break
#    else
#      echo "Waiting for web3signer to be reachable..."
#      sleep 5
#    fi
#  done
else
  __w3s_url=""
fi

# Distributed attestation aggregation
if [[ "${ENABLE_DIST_ATTESTATION_AGGR}" =  "true" ]]; then
  __att_aggr="--Xobol-dvt-integration-enabled=true"
else
  __att_aggr=""
fi

if [[ "${DEFAULT_GRAFFITI}" = "true" ]]; then
  __graffiti_args=()
else
  __graffiti_args=(--validators-graffiti="${GRAFFITI}")
fi

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${__network} "${__graffiti_args[@]}" ${__w3s_url} ${__mev_boost} ${__epbs} ${__doppel} ${__att_aggr} ${VC_EXTRAS}
