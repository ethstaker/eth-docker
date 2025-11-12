#!/bin/sh

if [ -z "${CHARON_LOKI_ADDRESSES}" ]; then
  echo "Error: \$CHARON_LOKI_ADDRESSES variable is empty" >&2
  exit 1
fi

if [ -z "${CLUSTER_NAME}" ]; then
  echo "Error: \$CLUSTER_NAME variable is empty" >&2
  exit 1
fi

if [ -z "${CLUSTER_PEER}" ]; then
  echo "Error: \$CLUSTER_PEER variable is empty" >&2
  exit 1
fi

# Process the template file once
sed -e "s|\$CHARON_LOKI_ADDRESSES|${CHARON_LOKI_ADDRESSES}|g" \
    -e "s|\$CLUSTER_NAME|${CLUSTER_NAME}|g" \
    -e "s|\$CLUSTER_PEER|${CLUSTER_PEER}|g" \
    /etc/promtail/config.yml.example > /etc/promtail/config.yml

exec "$@" --config.file=/etc/promtail/config.yml
