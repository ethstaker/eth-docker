#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R anchor:anchor /var/lib/anchor
  exec gosu anchor docker-entrypoint.sh "$@"
fi

__normalize_int() {
  local v=$1
  # Strip leading zeros as text. Arithmetic would overflow on the largest boost factors
  if [[ "${v}" =~ ^0*([0-9]+)$ ]]; then
    v="${BASH_REMATCH[1]}"
  fi
  printf '%s' "${v}"
}

if [[ "${IPV6}" = "true" ]]; then
  echo "Configuring Anchor to listen on IPv6 ports"
  __ipv6="--listen-addresses :: --port6 ${SSV_P2P_PORT:-13001} --discovery-port6 ${SSV_P2P_PORT_UDP:-12001} --quic-port6 ${SSV_QUIC_PORT:-13002}"
else
  __ipv6=""
fi

echo "MEV Boost enabled, mandatory Anchor default"
build_factor="$(__normalize_int "${EPBS_BUILD_FACTOR}")"
if [[ "${build_factor}" = "maxprofit" ]]; then
  build_factor=100  # 100 means profit maximization, as in the keymanager API
fi
case "${build_factor}" in
  0|local)
    __mev_factor="--builder-boost-factor 0"
    echo "EPBS_BUILD_FACTOR is ${build_factor}, which essentially disables remote block building / MEV."
    ;;
  always)
    __mev_factor="--prefer-builder-proposals"
    echo "Always prefer MEV builder blocks, EPBS_BUILD_FACTOR always"
    ;;
  "")
    __mev_factor=""
    echo "Use default --builder-boost-factor"
    ;;
  *)
    if [[ "${build_factor}" =~ ^[1-9][0-9]{0,19}$ ]]; then
      # Compare as text, bash arithmetic cannot hold uint64. Equal length makes this a numeric comparison
      # shellcheck disable=SC2071
      if [[ ${#build_factor} -eq 20 && "${build_factor}" > "18446744073709551615" ]]; then
        echo "EPBS_BUILD_FACTOR ${build_factor} exceeds the 64-bit maximum, capping it to 18446744073709551615"
        build_factor=18446744073709551615
      fi
      __mev_factor="--builder-boost-factor ${build_factor}"
      echo "Enabled MEV Build Factor of ${build_factor}"
    else
      __mev_factor=""
      echo "WARNING: EPBS_BUILD_FACTOR has an invalid value of \"${build_factor}\""
    fi
    ;;
esac

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${__ipv6} ${__mev_factor} ${DVT_EXTRAS}
