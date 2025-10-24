#!/usr/bin/env bash
set -Eeuo pipefail

if [ "$(id -u)" = '0' ]; then
  chown -R anchor:anchor /var/lib/anchor
  exec gosu anchor docker-entrypoint.sh "$@"
fi

if [ "${IPV6}" = "true" ]; then
  echo "Configuring Anchor to listen on IPv6 ports"
  __ipv6="--listen-addresses :: --port6 ${SSV_P2P_PORT:-13001} --discovery-port6 ${SSV_P2P_PORT_UDP:-12001} --quic-port6 ${SSV_QUIC_PORT:-13002}"
else
  __ipv6=""
fi

if [ "${MEV_BOOST}" = "true" ]; then
  __mev="--builder-proposals"
else
  __mev=""
fi

# Word splitting is desired for the command line parameters
# shellcheck disable=SC2086
exec "$@" ${__ipv6} ${__mev} ${DVT_EXTRAS}
