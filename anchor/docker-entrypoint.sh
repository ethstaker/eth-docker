#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$(id -u)" -eq 0 ]]; then
  chown -R anchor:anchor /var/lib/anchor
  exec gosu anchor docker-entrypoint.sh "$@"
fi

__normalize_int() {
  local v=$1
  if [[ "${v}" =~ ^[0-9]+$ ]]; then
    v=$((10#${v}))
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
build_factor="$(__normalize_int "${MEV_BUILD_FACTOR}")"
case "${build_factor}" in
  0)
    __mev_factor="--builder-boost-factor ${build_factor}"
    echo "MEV_BUILD_FACTOR is 0, which essentially disables remote block building / MEV."
    ;;
  [1-9]|[1-9][0-9])
    __mev_factor="--builder-boost-factor ${build_factor}"
    echo "Enabled MEV Build Factor of ${build_factor}"
    ;;
  100)
    __mev_factor="--prefer-builder-proposals"
    echo "Always prefer MEV builder blocks, MEV_BUILD_FACTOR 100"
    ;;
  "")
    __mev_factor=""
    echo "Use default --builder-boost-factor"
    ;;
  *)
    __mev_factor=""
    echo "WARNING: MEV_BUILD_FACTOR has an invalid value of \"${build_factor}\""
    ;;
esac

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${__ipv6} ${__mev_factor} ${DVT_EXTRAS}
