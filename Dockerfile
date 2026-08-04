ARG NODE_IMAGE="node:24.18.0-trixie-slim@sha256:ae91dcc111a68c9d2d81ff2a17bda61be126426176fde6fe7d08ab13b7f50573"
ARG BUILDER_IMAGE="hexpm/elixir:1.20.2-erlang-29.0.4-debian-trixie-20260713-slim@sha256:9804c9fd6cefea19e2b1095763057d08d634cac29a0994503a468427a64e5e12"
ARG RUNTIME_IMAGE="debian:trixie-20260713-slim@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd"
ARG BUILD_PLATFORM="linux/amd64"

FROM --platform=${BUILD_PLATFORM} ${NODE_IMAGE} AS node
FROM --platform=${BUILD_PLATFORM} ${BUILDER_IMAGE} AS builder

ARG DEBIAN_FRONTEND="noninteractive"

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential ca-certificates git \
  && rm -rf /var/lib/apt/lists/*

COPY --from=node /usr/local/ /usr/local/

ENV MIX_ENV="prod"
WORKDIR /app

RUN mix local.hex --force \
  && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

RUN mkdir config
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY package.json package-lock.json ./
RUN npm ci --ignore-scripts

COPY priv priv
COPY lib lib
RUN mix compile

COPY assets assets
RUN mix assets.deploy

COPY config/runtime.exs config/
COPY rel rel

ARG GIT_SHA="unknown"
ENV WORLDLOOM_GIT_SHA="${GIT_SHA}"

RUN mix release

FROM --platform=${BUILD_PLATFORM} ${RUNTIME_IMAGE} AS runtime

ARG DEBIAN_FRONTEND="noninteractive"

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates libncurses6 libsctp1 libstdc++6 locales openssl \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen \
  && rm -rf /var/lib/apt/lists/*

ENV LANG="en_US.UTF-8" \
    LC_ALL="en_US.UTF-8" \
    HOME="/app"

ENV PHX_SERVER="true"

WORKDIR /app

RUN groupadd --system worldloom \
  && useradd --system --gid worldloom --home-dir /app --shell /usr/sbin/nologin worldloom

COPY --from=builder --chown=worldloom:worldloom /app/_build/prod/rel/worldloom ./

USER worldloom

CMD ["bin/worldloom", "start"]
