# Find eligible builder and runner images on Docker Hub. We use Ubuntu/Debian
# instead of Alpine to avoid DNS resolution issues in production.
#
# https://hub.docker.com/r/hexpm/elixir/tags?page=1&name=ubuntu
# https://hub.docker.com/_/ubuntu?tab=tags
#
# This file is based on these images:
#
#   - https://hub.docker.com/r/hexpm/elixir/tags - for the build image
#   - https://hub.docker.com/_/debian?tab=tags&page=1&name=bullseye-20250428-slim - for the release image
#   - https://pkgs.org/ - resource for finding needed packages
#   - Ex: hexpm/elixir:1.18.3-erlang-27.3.4-debian-bullseye-20250428-slim
#
ARG ELIXIR_VERSION=1.18.3
ARG OTP_VERSION=27.3.4
ARG DEBIAN_VERSION=bullseye-20250428-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} as builder

# Retry helper function for flaky network operations
SHELL ["/bin/bash", "-c"]

# install build dependencies with retry
RUN for i in 1 2 3 4 5; do \
      apt-get update -y && \
      apt-get install -y build-essential git libvips-dev && \
      apt-get clean && rm -f /var/lib/apt/lists/*_* && break || \
      echo "Retry $i failed, waiting..." && sleep 5; \
    done

# prepare build dir
WORKDIR /app

# install hex + rebar with retry
RUN for i in 1 2 3 4 5; do \
      mix local.hex --force && \
      mix local.rebar --force && break || \
      echo "Retry $i failed, waiting..." && sleep 5; \
    done

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
COPY apps/elektrine/mix.exs apps/elektrine/mix.exs
COPY apps/elektrine_web/mix.exs apps/elektrine_web/mix.exs
COPY apps/elektrine_email/mix.exs apps/elektrine_email/mix.exs
COPY apps/elektrine_social/mix.exs apps/elektrine_social/mix.exs
COPY apps/elektrine_password_manager/mix.exs apps/elektrine_password_manager/mix.exs
COPY apps/elektrine_vpn/mix.exs apps/elektrine_vpn/mix.exs
RUN for i in 1 2 3 4 5; do \
      mix deps.get --only $MIX_ENV && break || \
      echo "Retry $i failed, waiting..." && sleep 5; \
    done
RUN mkdir -p config apps

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY apps apps

# Install Node.js 20.x (required for Tailwind v4)
RUN for i in 1 2 3 4 5; do \
      apt-get update -y && \
      apt-get install -y ca-certificates curl gnupg && \
      mkdir -p /etc/apt/keyrings && \
      curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
      echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list && \
      apt-get update -y && \
      apt-get install -y nodejs && \
      apt-get clean && rm -f /var/lib/apt/lists/*_* && break || \
      echo "Retry $i failed, waiting..." && sleep 5; \
    done

# Install npm dependencies for assets with retry (includes tailwindcss)
RUN for i in 1 2 3 4 5; do \
      cd apps/elektrine/assets && npm install && cd /app && break || \
      echo "Retry $i failed, waiting..." && sleep 5; \
    done

# Install esbuild with retry (tailwind is now installed via npm)
RUN for i in 1 2 3 4 5; do \
      mix esbuild.install && break || \
      echo "Retry $i failed, waiting..." && sleep 5; \
    done

# compile assets
RUN mix assets.deploy

# Compile the release
RUN mix compile

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

RUN mix release

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE}

SHELL ["/bin/bash", "-c"]

RUN for i in 1 2 3 4 5; do \
      apt-get update -y && \
      apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates libvips42 tor tini && \
      apt-get clean && rm -f /var/lib/apt/lists/*_* && break || \
      echo "Retry $i failed, waiting..." && sleep 5; \
    done

# Setup data directories (will be mounted as volume in production)
RUN mkdir -p /data/tor/elektrine /data/tor/data /data/certs && \
    chown -R nobody:nogroup /data

# Copy Tor config with proper permissions
COPY --chmod=644 torrc /etc/tor/torrc

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

# Copy startup scripts
COPY --chmod=755 start.sh /app/start.sh
COPY --chmod=755 docker-entrypoint.sh /app/docker-entrypoint.sh

# set runner ENV
ENV MIX_ENV="prod"
ENV PATH="/usr/bin:$PATH"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/elektrine ./

# Expose ports for HTTP and HTTPS (non-privileged ports, fly.toml maps external 80/443)
EXPOSE 8080 8443

# Use tini for proper zombie process reaping (needed for Tor sidecar)
# Entrypoint runs as root to fix volume permissions, then drops to nobody
ENTRYPOINT ["/usr/bin/tini", "--"]

CMD ["/app/docker-entrypoint.sh"]
