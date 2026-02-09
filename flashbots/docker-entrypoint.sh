#!/bin/sh

set -eu

# MEV-boost entrypoint script
# Allows passing additional flags via MEV_EXTRAS environment variable
# Usage: docker-entrypoint.sh /app/mev-boost [base-flags...]
# The script will append MEV_EXTRAS to the command

# Word splitting is desired for MEV_EXTRAS
# shellcheck disable=SC2086
exec "$@" ${MEV_EXTRAS:-}
