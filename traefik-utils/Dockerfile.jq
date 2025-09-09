# hadolint global ignore=DL3007,DL3008,DL3059
FROM debian:trixie-slim

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl jq gosu \
  && rm -rf /var/lib/apt/lists/*
