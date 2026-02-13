# hadolint global ignore=DL3007,DL3008,DL3059
FROM wealdtech/ethdo:latest

ARG USER=ethdo
ARG UID=1000

RUN apt-get update && DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC apt-get install -y --no-install-recommends \
  gosu \
  adduser \
  bash \
  jq \
  && gosu nobody true \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

# See https://stackoverflow.com/a/55757473/12429735RUN
RUN adduser \
    --disabled-password \
    --gecos "" \
    --home "/nonexistent" \
    --shell "/sbin/nologin" \
    --no-create-home \
    --uid "${UID}" \
    "${USER}"

RUN set -eux; \
  apt-get update; \
  DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC apt-get install -y --no-install-recommends gosu jq; \
  rm -rf /var/lib/apt/lists/*; \
# verify that the binary works
  gosu nobody true

RUN mkdir -p /app/wallet
RUN chown -R ${USER}:${USER} /app

COPY ./docker-entrypoint.sh /usr/local/bin/

ENTRYPOINT [ "/app/ethdo" ]
