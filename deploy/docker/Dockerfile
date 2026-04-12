# Find eligible builder and runner images on Docker Hub. We use Debian
# instead of Alpine to avoid DNS resolution issues in production.
#
# https://hub.docker.com/r/hexpm/elixir/tags?page=1&name=debian
# https://hub.docker.com/_/debian?tab=tags
#
# This file is based on these images:
#
#   - https://hub.docker.com/r/hexpm/elixir/tags - for the build image
#   - https://hub.docker.com/_/ubuntu - for the release image
#   - https://pkgs.org/ - resource for finding needed packages
#   - Ex: hexpm/elixir:1.19.5-erlang-28.0-ubuntu-noble-20260324
#
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.1.1
ARG UBUNTU_VERSION=noble-20260324
ARG RELEASE_NAME=elektrine
ARG ELEKTRINE_RELEASE_MODULES=all
ARG PRIMARY_DOMAIN=example.com
ARG EMAIL_DOMAIN=example.com
ARG SUPPORTED_DOMAINS=example.com
ARG PROFILE_BASE_DOMAINS=example.com

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-ubuntu-${UBUNTU_VERSION}"
ARG RUNNER_IMAGE="ubuntu:${UBUNTU_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

ARG RELEASE_NAME
ARG ELEKTRINE_RELEASE_MODULES
ARG PRIMARY_DOMAIN
ARG EMAIL_DOMAIN
ARG SUPPORTED_DOMAINS
ARG PROFILE_BASE_DOMAINS

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
ENV ELEKTRINE_RELEASE_MODULES="${ELEKTRINE_RELEASE_MODULES}"
ENV PRIMARY_DOMAIN="${PRIMARY_DOMAIN}"
ENV EMAIL_DOMAIN="${EMAIL_DOMAIN}"
ENV SUPPORTED_DOMAINS="${SUPPORTED_DOMAINS}"
ENV PROFILE_BASE_DOMAINS="${PROFILE_BASE_DOMAINS}"

# install mix dependencies
COPY mix.lock ./
COPY release_builder/mix.exs release_builder/mix.exs
COPY release_builder/module_selection.exs release_builder/module_selection.exs
COPY release_builder/config/config.exs release_builder/config/config.exs
COPY release_builder/config/runtime.exs release_builder/config/runtime.exs
COPY apps/elektrine/mix.exs apps/elektrine/mix.exs
COPY apps/elektrine_chat/mix.exs apps/elektrine_chat/mix.exs
COPY apps/elektrine_web/mix.exs apps/elektrine_web/mix.exs
COPY apps/elektrine_email/mix.exs apps/elektrine_email/mix.exs
COPY apps/elektrine_social/mix.exs apps/elektrine_social/mix.exs
COPY apps/elektrine_dns/mix.exs apps/elektrine_dns/mix.exs
COPY apps/elektrine_password_manager/mix.exs apps/elektrine_password_manager/mix.exs
COPY apps/elektrine_vpn/mix.exs apps/elektrine_vpn/mix.exs
COPY config/config.exs config/prod.exs config/
WORKDIR /app/release_builder
RUN for i in 1 2 3 4 5; do \
      mix deps.get --only $MIX_ENV && break || \
      echo "Retry $i failed, waiting..." && sleep 5; \
    done
RUN mix deps.compile
WORKDIR /app

COPY apps apps
COPY release_builder release_builder
COPY config/runtime.exs config/runtime.exs
COPY --chmod=755 scripts/release/deploy_release.sh scripts/release/deploy_release.sh
COPY scripts/lib scripts/lib

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
      cd release_builder && mix esbuild.install && cd /app && break || \
      echo "Retry $i failed, waiting..." && sleep 5; \
    done

# Build the selected hoster release through release_builder/
RUN ./scripts/release/deploy_release.sh --release-name ${RELEASE_NAME} --mix-env ${MIX_ENV}

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE}

ARG RELEASE_NAME
ARG ELEKTRINE_RELEASE_MODULES

SHELL ["/bin/bash", "-c"]

RUN for i in 1 2 3 4 5; do \
      apt-get update -y && \
      apt-get install -y libstdc++6 openssl libncurses5 ca-certificates libvips42 tor tini gnupg wireguard-tools iproute2 && \
      apt-get clean && rm -f /var/lib/apt/lists/*_* && break || \
      echo "Retry $i failed, waiting..." && sleep 5; \
    done

# Setup data directories (will be mounted as volume in production)
RUN mkdir -p /data/tor/elektrine /data/tor/data /data/certs && \
    chown -R nobody:nogroup /data

# Copy Tor config with proper permissions
COPY --chmod=644 deploy/onion/torrc /etc/tor/torrc

# Use a built-in UTF-8 locale available on Ubuntu images
ENV LANG=C.UTF-8
ENV LANGUAGE=C.UTF-8
ENV LC_ALL=C.UTF-8

WORKDIR "/app"
RUN chown nobody /app

# Copy startup scripts
COPY --chmod=755 deploy/docker/start.sh /app/start.sh
COPY --chmod=755 deploy/docker/docker-entrypoint.sh /app/docker-entrypoint.sh

# set runner ENV
ENV MIX_ENV="prod"
ENV PATH="/usr/bin:$PATH"
ENV RELEASE_NAME="${RELEASE_NAME}"
ENV ELEKTRINE_RELEASE_MODULES="${ELEKTRINE_RELEASE_MODULES}"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_deploy_release/${RELEASE_NAME} ./

# Expose ports for HTTP and HTTPS (non-privileged ports, fly.toml maps external 80/443)
EXPOSE 8080 8443

# Use tini for proper zombie process reaping (needed for Tor sidecar)
# Entrypoint runs as root to fix volume permissions, then drops to nobody
ENTRYPOINT ["/usr/bin/tini", "--"]

CMD ["/app/docker-entrypoint.sh"]
