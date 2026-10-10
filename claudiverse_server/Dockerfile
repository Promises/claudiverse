# syntax=docker/dockerfile:1
# Production image for the Claudiverse Phoenix server: multi-stage mix release.
# Build:  docker build -t claudiverse-server ./claudiverse_server
# Run:    handled by compose.prod.yml (sets PHX_SERVER, DATABASE_PATH, etc.)

# ---------- build stage ----------
FROM elixir:1.19-otp-28-slim AS build

# build-essential + git: exqlite (SQLite NIF) is compiled from source here.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

# Deps first for layer caching.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

# App sources. config/ must come before compile so runtime.exs ships in the release.
COPY config config
COPY lib lib
COPY priv priv

RUN mix compile
RUN mix release

# ---------- runtime stage ----------
# Must match the build image's Debian release (elixir:1.19-otp-28-slim = trixie)
# so the ERTS binaries find the same glibc. Bookworm's older glibc fails at boot.
FROM debian:trixie-slim AS runtime

# sqlite3 and procps are for INCIDENTS, not the app. During the 2026-09-26
# wedge, `docker exec … ps` produced a 0-byte file and nobody could tell a
# blocked exec from a missing binary, and the live DB could not be queried
# read-only from inside the container. `sqlite3 -readonly $DATABASE_PATH` and
# `ps` settle both in one command next time.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 locales ca-certificates curl \
      sqlite3 procps \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

WORKDIR /app

# Default DB location lives on a mounted volume (see compose.prod.yml).
RUN mkdir -p /data
ENV DATABASE_PATH=/data/claudiverse.db

# Start the HTTP endpoint when the release boots (required for `mix release`).
# RELEASE_NAME is set automatically by the boot scripts, which also makes the
# app run pending Ecto migrations at startup.
ENV PHX_SERVER=true \
    PORT=4000

COPY --from=build /app/_build/prod/rel/claudiverse_server ./

EXPOSE 4000

CMD ["bin/claudiverse_server", "start"]
