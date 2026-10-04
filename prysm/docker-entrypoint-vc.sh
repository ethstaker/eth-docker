#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R prysmvalidator:prysmvalidator /var/lib/prysm
  exec gosu prysmvalidator docker-entrypoint-vc.sh "$@"
fi

if [[ "${NETWORK}" = "ephemery" ]]; then
  config_dir_path="$(ephemery-config.sh /var/lib/prysm/testnet/ephemery)"
  __network="--chain-config-file=${config_dir_path}/config.yaml"
  # A new iteration has a new genesis, and slashing protection for the old one is for a dead chain
  __iteration="$(basename "$(dirname "${config_dir_path}")")"
  __slashing_db=/var/lib/prysm/prysm-wallet-v2/direct/validator.db
  if [[ -f /var/lib/prysm/ephemery-iteration ]]; then
    __old_iteration="$(cat /var/lib/prysm/ephemery-iteration)"
    if [[ ! "${__old_iteration}" = "${__iteration}" && -f "${__slashing_db}" ]]; then
      echo "Ephemery reset from ${__old_iteration} to ${__iteration}, removing the old slashing protection DB"
      rm -f "${__slashing_db}"
    fi
  fi
  echo "${__iteration}" > /var/lib/prysm/ephemery-iteration
elif [[ "${NETWORK}" =~ ^https?:// ]]; then
  echo "Custom testnet at ${NETWORK}"
  repo=$(awk -F'/tree/' '{print $1}' <<< "${NETWORK}")
  branch=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f1)
  config_dir=$(awk -F'/tree/' '{print $2}' <<< "${NETWORK}" | cut -d'/' -f2-)
  echo "This appears to be the ${repo} repo, branch ${branch} and config directory ${config_dir}."
  if [[ ! -d "/var/lib/prysm/testnet/${config_dir}" ]]; then
    mkdir -p /var/lib/prysm/testnet
    cd /var/lib/prysm/testnet
    git init --initial-branch="${branch}"
    git remote add origin "${repo}"
    git config core.sparseCheckout true
    echo "${config_dir}" > .git/info/sparse-checkout
    git pull origin "${branch}"
  fi
  __network="--chain-config-file=/var/lib/prysm/testnet/${config_dir}/config.yaml"
else
  __network="--${NETWORK}"
fi

# Check whether we should use MEV Boost
if [[ "${MEV_BOOST}" = "true" ]]; then
  __mev_boost="--enable-builder"
  echo "MEV Boost enabled"
else
  __mev_boost=""
fi

# Check whether we should enable doppelganger protection
if [[ "${DOPPELGANGER}" = "true" ]]; then
  __doppel="--enable-doppelganger"
  echo "Doppelganger protection enabled, VC will pause for 2 epochs"
else
  __doppel=""
fi

# Web3signer URL
if [[ "${WEB3SIGNER}" = "true" ]]; then
  __w3s_url="--validators-external-signer-url ${W3S_NODE} \
  --validators-external-signer-public-keys ${W3S_NODE}/api/v1/eth2/publicKeys \
  --validators-external-signer-key-file=/var/lib/prysm/w3s-keys.txt"

  if [[ ! -f /var/lib/prysm/w3s-keys.txt ]]; then
    touch /var/lib/prysm/w3s-keys.txt
  fi
else
  __w3s_url="--wallet-password-file /var/lib/prysm/password.txt"
fi

# Distributed attestation aggregation
if [[ "${ENABLE_DIST_ATTESTATION_AGGR}" =  "true" ]]; then
  __att_aggr="--distributed"
else
  __att_aggr=""
fi

if [[ "${DEFAULT_GRAFFITI}" = "true" ]]; then
  __graffiti_args=()
else
  __graffiti_args=(--graffiti "${GRAFFITI}")
fi

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${__network} ${__w3s_url} "${__graffiti_args[@]}" ${__mev_boost} ${__doppel} ${__att_aggr} ${VC_EXTRAS}
