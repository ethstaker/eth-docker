#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R teku:teku /var/lib/teku
  exec gosu teku docker-entrypoint.sh "$@"
fi


# Because we're oh-so-clever with + substitution and maxpeers, we may have empty args. Remove them
__strip_empty_args() {
  local arg
  __args=()
  for arg in "$@"; do
    if [[ -n "${arg}" ]]; then
      __args+=("${arg}")
    fi
  done
}


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


if [[ -f /var/lib/teku/teku-keyapi.keystore ]]; then
    if [[ "$(date +%s -r /var/lib/teku/teku-keyapi.keystore)" -lt "$(date +%s --date="300 days ago")" ]]; then
       rm /var/lib/teku/teku-keyapi.keystore
    elif ! openssl x509 -noout -ext subjectAltName -in /var/lib/teku/teku-keyapi.crt | grep -q 'DNS:consensus'; then
       rm /var/lib/teku/teku-keyapi.keystore
    fi
fi

if [[ ! -f /var/lib/teku/teku-keyapi.keystore ]]; then
  password=$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum| head -c 32)
  echo "${password}" > /var/lib/teku/teku-keyapi.password
  openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes -keyout /var/lib/teku/teku-keyapi.key -out /var/lib/teku/teku-keyapi.crt -subj '/CN=teku-keyapi-cert' -extensions san -config <( \
    echo '[req]'; \
    echo 'distinguished_name=req'; \
    echo '[san]'; \
    echo 'subjectAltName=DNS:localhost,DNS:consensus,DNS:validator,DNS:vc,IP:127.0.0.1')
  openssl pkcs12 -export -in /var/lib/teku/teku-keyapi.crt -inkey /var/lib/teku/teku-keyapi.key -out /var/lib/teku/teku-keyapi.keystore -name teku-keyapi -passout pass:"${password}"
fi

if [[ -n "${JWT_SECRET}" ]]; then
  echo -n "${JWT_SECRET}" > /var/lib/teku/ee-secret/jwtsecret
  echo "JWT secret was supplied in .env"
fi

if [[ -O /var/lib/teku/ee-secret ]]; then
  # In case someone specifies JWT_SECRET but it's not a distributed setup
  chmod 777 /var/lib/teku/ee-secret
fi
if [[ -O /var/lib/teku/ee-secret/jwtsecret ]]; then
  chmod 666 /var/lib/teku/ee-secret/jwtsecret
fi

# Check whether we should rapid sync
if [[ -n "${CHECKPOINT_SYNC_URL:+x}" ]]; then
  if [[ "${NODE_TYPE}" = "archive" ]]; then
    echo "Teku archive node cannot use checkpoint sync: Syncing from genesis."
      __checkpoint_sync="--ignore-weak-subjectivity-period-enabled=true"
    if [[ "${NETWORK}" = "hoodi" ]]; then
      __checkpoint_sync+=" --initial-state=https://checkpoint-sync.hoodi.ethpandaops.io/eth/v2/debug/beacon/states/genesis"
    fi
  else
    __checkpoint_sync="--checkpoint-sync-url=${CHECKPOINT_SYNC_URL}"
    echo "Checkpoint sync enabled"
  fi
else
  __checkpoint_sync="--ignore-weak-subjectivity-period-enabled=true"
  if [[ "${NETWORK}" = "hoodi" ]]; then
    __checkpoint_sync+=" --initial-state=https://checkpoint-sync.hoodi.ethpandaops.io/eth/v2/debug/beacon/states/genesis"
  fi
fi

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
  config_dir_path="/var/lib/teku/testnet/${config_dir}"
  if [[ -f "${config_dir_path}/bootstrap_nodes.txt" ]]; then
    bootnodes="$(paste -sd, "${config_dir_path}/bootstrap_nodes.txt")"
  else
    bootnodes="$(awk -F'- ' '!/^#/ && NF>1 { split($2, a, /[ \t#]/); if (a[1] != "") printf (first++ ? "," : "") a[1] } END { print "" }' "${config_dir_path}/bootstrap_nodes.yaml")"
  fi
  __checkpoint_sync="--initial-state=${config_dir_path}/genesis.ssz --ignore-weak-subjectivity-period-enabled=true"
  __network="--network=${config_dir_path}/config.yaml --p2p-discovery-bootnodes=${bootnodes}"
else
  __network="--network=${NETWORK}"
fi

# Check whether we should use MEV Boost
# Adjust RIGHT after each network's Glamsterdam hardfork
if [[ "${MEV_BOOST}" = "true" && "${NETWORK}" =~ ^(sepolia|hoodi|mainnet)$ ]]; then
  __mev_boost="--builder-endpoint=${MEV_NODE:-http://mev-boost:18550}"
  echo "MEV Boost enabled"
  if [[ "${EMBEDDED_VC}" = "true" ]]; then
    __mev_boost+=" --validators-builder-registration-default-enabled"
  fi
  # Teku has the build factor on the CL, which is unusual
  build_factor="$(__normalize_int "${EPBS_BUILD_FACTOR}")"
  if [[ "${build_factor}" = "maxprofit" ]]; then
    build_factor=100  # 100 means profit maximization, as in the keymanager API
  fi
  case "${build_factor}" in
    0|local)
      __mev_boost=""
      __mev_factor=""
      echo "Disabled MEV Boost because EPBS_BUILD_FACTOR is ${build_factor}."
      echo "WARNING: This conflicts with MEV_BOOST true. Set a factor above 0, or maxprofit or always"
      ;;
    always)
      __mev_factor="--builder-bid-compare-factor=BUILDER_ALWAYS"
      echo "Always prefer MEV builder blocks, EPBS_BUILD_FACTOR always"
      ;;
    "")
      __mev_factor=""
      echo "Use default --builder-bid-compare-factor"
      ;;
    *)
      if [[ "${build_factor}" =~ ^[1-9][0-9]{0,19}$ ]]; then
        # Compare as text, bash arithmetic cannot hold uint64. Equal length makes this a numeric comparison
        # shellcheck disable=SC2071
        if [[ ${#build_factor} -eq 20 && "${build_factor}" > "18446744073709551615" ]]; then
          echo "EPBS_BUILD_FACTOR ${build_factor} exceeds the 64-bit maximum, capping it to 18446744073709551615"
          build_factor=18446744073709551615
        fi
        __mev_factor="--builder-bid-compare-factor=${build_factor}"
        echo "Enabled MEV Build Factor of ${build_factor}"
      else
        __mev_factor=""
        echo "WARNING: EPBS_BUILD_FACTOR has an invalid value of \"${build_factor}\""
      fi
      ;;
  esac
else
  if [[ "${MEV_BOOST}" = "true" ]]; then
    echo "MEV_BOOST is true, but MEV Boost is not used on ${NETWORK}. Ignoring it."
  fi
  __mev_boost=""
  __mev_factor=""
fi

if [[ "${EMBEDDED_VC}" = "true" ]]; then
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
else
  __epbs=""
fi

# Check whether we should send stats to beaconcha.in
if [[ -n "${BEACON_STATS_API}" ]]; then
  __beacon_stats="--metrics-publish-endpoint=https://beaconcha.in/api/v1/client/metrics?apikey=${BEACON_STATS_API}&machine=${BEACON_STATS_MACHINE}"
  echo "Beacon stats API enabled"
else
  __beacon_stats=""
fi

# Check whether we should enable doppelganger protection
if [[ "${EMBEDDED_VC}" = "true" && "${DOPPELGANGER}" = "true" ]]; then
  __doppel="--doppelganger-detection-enabled=true"
  echo "Doppelganger protection enabled, VC will pause for 2 epochs"
else
  __doppel=""
fi

case "${NODE_TYPE}" in
  archive)
    echo "Teku archive node without history pruning"
    __prune="--data-storage-mode=ARCHIVE"
    ;;
  full)
    __prune=""
    ;;
  pruned)
    echo "Teku pruned node"
    __prune="--data-storage-mode=MINIMAL"
    ;;
  *)
    echo "ERROR: The node type ${NODE_TYPE} is not known to Eth Docker's Teku implementation."
    sleep 30
    exit 1
    ;;
esac

# Web3signer URL
if [[ "${EMBEDDED_VC}" = "true" && "${WEB3SIGNER}" = "true" ]]; then
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

if [[ "${IPV6}" = "true" ]]; then
  echo "Configuring Teku to listen on IPv6 ports"
  __ipv6="--p2p-interface 0.0.0.0,:: --p2p-udp-port-ipv6 ${CL_IPV6_DISC_PORT:-9010} --p2p-quic-port-ipv6 ${CL_IPV6_QUIC_PORT:-9011}"
else
  __ipv6=""
fi

if [[ "${EMBEDDED_VC}" = "true" && "${DEFAULT_GRAFFITI}" != "true" ]]; then
  __graffiti_args=(--validators-graffiti="${GRAFFITI}")
else
  __graffiti_args=()
fi

__strip_empty_args "$@"
set -- "${__args[@]}"

i=0
while true; do
  if [ -f /var/lib/teku/ee-secret/jwtsecret ]; then
    break
  else
    if [[ "$i" -eq 5 ]]; then
      echo "Did not see the JWT secret file six times in a row. This is either a bug or a very slow execution layer client startup."
      echo "Starting consensus layer client anyway: It may fail."
      break
    else
      echo "Waiting for JWT secret file to be created by execution layer client"
      sleep 5
      ((++i))
    fi
  fi
done

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${__network} ${__w3s_url} "${__graffiti_args[@]}" ${__mev_boost} ${__mev_factor} ${__epbs} ${__checkpoint_sync} ${__prune} ${__beacon_stats} ${__doppel} ${__ipv6} ${CL_EXTRAS} ${VC_EXTRAS}
