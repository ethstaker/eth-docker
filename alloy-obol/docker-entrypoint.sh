#!/bin/sh

if [ -z "${CHARON_LOKI_ADDRESSES:-}" ]; then
  echo "\$CHARON_LOKI_ADDRESSES variable is empty - using local Loki"
  CHARON_LOKI_ADDRESSES=http://loki:3100/loki/api/v1/push
fi

if [ -z "${CLUSTER_NAME:-}" ]; then
  echo "Error: \$CLUSTER_NAME variable is empty" >&2
  CLUSTER_NAME=dummy-cluster
fi

if [ -z "${CLUSTER_PEER:-}" ]; then
  echo "Error: \$CLUSTER_PEER variable is empty" >&2
  CLUSTER_PEER=dummy-peer
fi

if [ -z "${OBOL_PROM_REMOTE_WRITE_TOKEN:-}" ]; then
  echo "Error: \$OBOL_PROM_REMOTE_WRITE_TOKEN variable is empty" >&2
  OBOL_PROM_REMOTE_WRITE_TOKEN=dummy-token
fi


SRC="/etc/alloy/config.alloy.sample"
DST="/etc/alloy/config.alloy"

echo "Rendering template: $SRC -> $DST"

sed -e "s|\$CHARON_LOKI_ADDRESSES|${CHARON_LOKI_ADDRESSES}|g" \
    -e "s|\$CLUSTER_NAME|${CLUSTER_NAME}|g" \
    -e "s|\$CLUSTER_PEER|${CLUSTER_PEER}|g" \
    -e "s|\$OBOL_PROM_REMOTE_WRITE_TOKEN|${OBOL_PROM_REMOTE_WRITE_TOKEN}|g" \
    "$SRC" > "$DST"

echo "Config rendered to $DST"

# Execute the command passed as arguments if any
if [ $# -gt 0 ]; then
  echo "Executing:" "$@"
  exec "$@"
fi
