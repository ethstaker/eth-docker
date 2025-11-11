#!/bin/bash
set -Eeuo pipefail

# Copy keys, then restart script without root
if [[ "$(id -u)" -eq 0 ]]; then
  mkdir /keys
  cp -r /validator_keys/* /keys/
  chown lhvalidator:lhvalidator /keys/*
  exec gosu lhvalidator "${BASH_SOURCE[0]}" "$@"
fi

exec "$@"
