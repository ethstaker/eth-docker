FROM ghcr.io/astral-sh/uv:0.12.21 AS uv

FROM python:3.15-alpine

WORKDIR /app

ARG USER=dns
ARG UID=11000

# Always included in alpine:3
# See https://stackoverflow.com/a/55757473/12429735RUN
RUN adduser \
    --disabled-password \
    --gecos "" \
    --shell "/sbin/nologin" \
    --uid "${UID}" \
    --home "/home/dns" \
    --no-create-home \
    "${USER}"

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_NO_CACHE=1 \
    UV_PYTHON_DOWNLOADS=never \
    UV_PROJECT_ENVIRONMENT=/app/.venv \
    PATH="/app/.venv/bin:$PATH"

COPY app/pyproject.toml app/uv.lock ./
RUN --mount=from=uv,source=/uv,target=/bin/uv \
    uv sync --locked --no-dev --no-install-project

COPY --chown=${USER}:${USER} app/updater.py .
COPY --chown=${USER}:${USER} app/base.py .
COPY --chown=${USER}:${USER} app/route53_provider.py .
COPY --chown=${USER}:${USER} app/cf_provider.py .
COPY --chown=${USER}:${USER} app/provider_registry.py .
COPY --chown=${USER}:${USER} app/privilege.py .
RUN chmod 555 ./updater.py

RUN mkdir -p /home/dns && chown ${USER}:${USER} /home/dns

CMD ["python", "updater.py"]
