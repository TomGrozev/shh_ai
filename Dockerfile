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
#
# Pinned by digest (ticket #67): `latest` is a moving target, so an unpinned
# base makes every rebuild start from different layers. This is the multi-arch
# index digest for linux/amd64 + linux/arm64, resolved 2026-10-14 from
# cgr.dev/chainguard/wolfi-base:latest. To bump, re-resolve the digest with:
#
#   curl -sI -H 'Accept: application/vnd.oci.image.index.v1+json' \
#     https://cgr.dev/v2/chainguard/wolfi-base/manifests/latest | grep -i docker-content-digest
ARG WOLFI_BASE=cgr.dev/chainguard/wolfi-base@sha256:256c88bb066424045021090932d50be93c8e3f2ce3586707702a401b146f3e43

# ============================== build ======================================
FROM ${WOLFI_BASE} AS build

ARG SHHAI_SLIM=false
ARG MIX_ENV=prod

ENV MIX_ENV=${MIX_ENV} \
    SHHAI_SLIM=${SHHAI_SLIM} \
    LANG=C.UTF-8

# Elixir/OTP toolchain plus the native build deps for the NIFs (EXLA, crypto).
#
# Every package is version-pinned (ticket #67) so the layer is reproducible.
# `erl28-elixir-1.19` is the Elixir 1.19.5 build linked against OTP 28 (ADR
# 0017: Elixir >= 1.19.4, no upper bound); the plain `elixir`/`erlang` virtuals
# would float onto whatever the rolling Wolfi repo currently provides (today
# OTP 29). Wolfi is rolling and eventually drops old versions — when a pin
# disappears from the repo, the build fails with "unable to select packages";
# re-resolve the version at https://packages.wolfi.dev/os/x86_64/APKINDEX.tar.gz.
RUN apk add --no-cache \
      build-base=1-r10 \
      git=2.56.0-r0 \
      ca-certificates=20260909-r2 \
      erl28-elixir-1.19=1.19.5-r1 \
      erlang-28=28.5.0.7-r2 \
      openssl-dev=3.6.5-r2 \
      ncurses-dev=6.6.20261010-r0 \
      zlib-dev=1.3.2-r7

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
      mix run --no-start -e 'ShhAi.Config.load(); case ShhAi.PII.NER.detect("John Smith lives in Paris") do {:ok, _} -> IO.puts("NER stack validated on Wolfi"); other -> raise "NER detect failed: #{inspect(other)}" end'; \
    fi \
 && mix release

# ============================= runtime =====================================
FROM ${WOLFI_BASE} AS runtime

# BEAM runtime libs, OpenSSL for the crypto NIF, libstdc++/libgcc for EXLA,
# and tini as a minimal PID 1 (reaps zombies, forwards signals). Version-pinned
# for reproducibility (ticket #67); see the build stage note on re-resolving
# pins when Wolfi drops a version.
RUN apk add --no-cache \
      libstdc++=16.2.0-r1 \
      libgcc=16.2.0-r1 \
      openssl=3.6.5-r2 \
      ncurses=6.6.20261010-r0 \
      zlib=1.3.2-r7 \
      ca-certificates=20260909-r2 \
      tini=0.19.0-r26

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
