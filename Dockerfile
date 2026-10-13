# syntax=docker/dockerfile:1.7
#
# ShhAi container image (ticket #70, ADR-0015/0016).
#
# One Dockerfile, two tags, selected by the SHHAI_SLIM build flag:
#
#   full (default) : EXLA + Bumblebee + a baked, offline NER model.
#   slim           : regex-only; nx/exla/bumblebee are dropped and the
#                    image boots with NER off.
#
#   docker build -t shh-ai:0.1.0 .
#   docker build --build-arg SHHAI_SLIM=true -t shh-ai:0.1.0-slim .
#
# The runtime image is rootless and read-only-rootfs friendly: every writable
# path (HOME, TMPDIR, the release tmp dir) is redirected under /tmp, and the
# only durable write is the audit SQLite DB on a mounted volume.

# Wolfi's glibc base — matched to the EXLA/crypto NIF ABI.
ARG WOLFI_BASE=cgr.dev/chainguard/wolfi-base:latest

# ============================== build ======================================
FROM ${WOLFI_BASE} AS build

ARG SHHAI_SLIM=false
ARG MIX_ENV=prod

ENV MIX_ENV=${MIX_ENV} \
    SHHAI_SLIM=${SHHAI_SLIM} \
    LANG=C.UTF-8

# Elixir/OTP toolchain plus the native build deps for the NIFs (EXLA, crypto).
RUN apk add --no-cache \
      build-base git ca-certificates \
      elixir erlang \
      openssl-dev ncurses-dev zlib-dev

WORKDIR /app

# Deps first (layer cache). mix.lock pins them; SHHAI_SLIM decides whether the
# ML trio is fetched at all (mix.exs ml_deps/0).
COPY mix.exs mix.lock ./
RUN mix local.hex --force && mix local.rebar --force && mix deps.get

COPY config config
COPY lib lib
COPY priv priv
COPY rel rel
COPY assets assets

# Compile, build digested assets, then (full image only) validate the ML stack
# end-to-end on Wolfi — model download, EXLA compile, inference — so a broken
# EXLA-on-Wolfi fails the build loudly instead of at first request. The model
# is cached into /models, which is baked into the runtime image below.
ENV BUMBLEBEE_CACHE_DIR=/models \
    BUMBLEBEE_OFFLINE=false \
    SECRET_KEY_BASE=build-time-validation-not-a-runtime-secret

RUN mix deps.compile \
 && mix assets.setup \
 && mix assets.deploy \
 && mkdir -p /models \
 && if [ "${SHHAI_SLIM}" != "true" ]; then \
      mix run --no-start -e '
        ShhAi.Config.load()

        case ShhAi.PII.NER.detect("John Smith lives in Paris") do
          {:ok, _} -> IO.puts("NER stack validated on Wolfi")
          other -> raise "NER detect failed: #{inspect(other)}"
        end
      '; \
    fi \
 && mix release

# ============================= runtime =====================================
FROM ${WOLFI_BASE} AS runtime

# BEAM runtime libs, OpenSSL for the crypto NIF, libstdc++/libgcc for EXLA,
# and tini as a minimal PID 1 (reaps zombies, forwards signals).
RUN apk add --no-cache \
      libstdc++ libgcc openssl ncurses zlib ca-certificates tini

ENV MIX_ENV=prod \
    PHX_SERVER=true \
    PORT=4000 \
    LANG=C.UTF-8 \
    HOME=/tmp \
    TMPDIR=/tmp \
    RELEASE_TMP=/tmp \
    RELEASE_DISTRIBUTION=none \
    BUMBLEBEE_OFFLINE=true \
    BUMBLEBEE_CACHE_DIR=/models

WORKDIR /app

# The release (compiled at build), the baked model cache (empty in slim), and
# the container entrypoint. Runs as Wolfi's nonroot uid (65532); the root
# filesystem is expected to be read-only.
COPY --from=build --chown=nonroot:nonroot /app/_build/prod/rel/shh_ai ./
COPY --from=build --chown=nonroot:nonroot /models /models

# Audit Mode's SQLite DB lives here; a fresh named volume inherits this
# directory's ownership, so the nonroot user can write to the mounted volume.
RUN mkdir -p /data && chown 65532:65532 /data

USER nonroot

EXPOSE 4000

ENTRYPOINT ["tini", "--", "/app/bin/docker-entrypoint"]
