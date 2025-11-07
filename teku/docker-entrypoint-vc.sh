#!/usr/bin/env bash

if [ "$(id -u)" = '0' ]; then
  chown -R teku:teku /var/lib/teku
  exec gosu teku docker-entrypoint-vc.sh "$@"
fi

__normalize_int() {
    local v=$1
    if [[ $v =~ ^[0-9]+$ ]]; then
        v=$((10#$v))
    fi
    printf '%s' "$v"
}

if [[ "${NETWORK}" =~ ^https?:// ]]; then
  echo "Custom testnet at ${NETWORK}"
  repo=$(awk -F'/tree/' '{print $1}' <<< "${NETWORK}")
  branch=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f1)
  config_dir=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f2-)
  echo "This appears to be the ${repo} repo, branch ${branch} and config directory ${config_dir}."
  # For want of something more amazing, let's just fail if git fails to pull this
  set -e
  if [ ! -d "/var/lib/teku/testnet/${config_dir}" ]; then
    mkdir -p /var/lib/teku/testnet
    cd /var/lib/teku/testnet
    git init --initial-branch="${branch}"
    git remote add origin "${repo}"
    git config core.sparseCheckout true
    echo "${config_dir}" > .git/info/sparse-checkout
    git pull origin "${branch}"
  fi
  set +e
  __network="--network=/var/lib/teku/testnet/${config_dir}/config.yaml"
else
  __network="--network=${NETWORK}"
fi

if [ -f /var/lib/teku/teku-keyapi.keystore ]; then
    if [ "$(date +%s -r /var/lib/teku/teku-keyapi.keystore)" -lt "$(date +%s --date="300 days ago")" ]; then
       rm /var/lib/teku/teku-keyapi.keystore
    elif ! openssl x509 -noout -ext subjectAltName -in /var/lib/teku/teku-keyapi.crt | grep -q "DNS:${VC_ALIAS}"; then
       rm /var/lib/teku/teku-keyapi.keystore
    fi
fi

if [ ! -f /var/lib/teku/teku-keyapi.keystore ]; then
    __password=$(head -c 8 /dev/urandom | od -A n -t u8 | tr -d '[:space:]' | sha256sum | head -c 32)
    echo "$__password" > /var/lib/teku/teku-keyapi.password
    openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes -keyout /var/lib/teku/teku-keyapi.key -out /var/lib/teku/teku-keyapi.crt -subj '/CN=teku-keyapi-cert' -extensions san -config <( \
      echo '[req]'; \
      echo 'distinguished_name=req'; \
      echo '[san]'; \
      echo "subjectAltName=DNS:localhost,DNS:consensus,DNS:validator,DNS:${VC_ALIAS},IP:127.0.0.1")
    openssl pkcs12 -export -in /var/lib/teku/teku-keyapi.crt -inkey /var/lib/teku/teku-keyapi.key -out /var/lib/teku/teku-keyapi.keystore -name teku-keyapi -passout pass:"$__password"
fi

# Check whether we should enable doppelganger protection
if [ "${DOPPELGANGER}" = "true" ]; then
  __doppel="--doppelganger-detection-enabled=true"
  echo "Doppelganger protection enabled, VC will pause for 2 epochs"
else
  __doppel=""
fi

# Check whether we should use MEV Boost
if [ "${MEV_BOOST}" = "true" ]; then
  __mev_boost="--validators-builder-registration-default-enabled"
  echo "MEV Boost enabled"
  __build_factor="$(__normalize_int "${MEV_BUILD_FACTOR}")"
  case "${__build_factor}" in
    0)
      __mev_boost=""
      __mev_factor=""
      echo "Disabled MEV Boost because MEV_BUILD_FACTOR is 0."
      echo "WARNING: This conflicts with MEV_BOOST true. Set factor in a range of 1 to 100"
      ;;
    [1-9]|[1-9][0-9])
      __mev_factor=""
      echo "Teku VC does not support setting a builder boost factor"
      ;;
    100)
      __mev_factor=""
      echo "Teku VC does not support setting a builder boost factor"
      ;;
    "")
      __mev_factor=""
      ;;
    *)
      __mev_factor=""
      echo "WARNING: MEV_BUILD_FACTOR has an invalid value of \"${__build_factor}\""
      ;;
  esac
else
  __mev_boost=""
  __mev_factor=""
fi

# Web3signer URL
if [ "${WEB3SIGNER}" = "true" ]; then
  __w3s_url="--validators-external-signer-url ${W3S_NODE}"
#  while true; do
#    if curl -s -m 5 ${W3S_NODE} &> /dev/null; then
#        echo "web3signer is up, starting Teku"
#        break
#    else
#        echo "Waiting for web3signer to be reachable..."
#        sleep 5
#    fi
#  done
else
  __w3s_url=""
fi

# Distributed attestation aggregation
if [ "${ENABLE_DIST_ATTESTATION_AGGR}" =  "true" ]; then
  __att_aggr="--Xobol-dvt-integration-enabled=true"
else
  __att_aggr=""
fi

if [ "${DEFAULT_GRAFFITI}" = "true" ]; then
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" ${__network} ${__w3s_url} ${__mev_boost} ${__mev_factor} ${__doppel} ${__att_aggr} ${VC_EXTRAS}
else
# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
  exec "$@" ${__network} "--validators-graffiti=${GRAFFITI}" ${__w3s_url} ${__mev_boost} ${__mev_factor} ${__doppel} ${__att_aggr} ${VC_EXTRAS}
fi
