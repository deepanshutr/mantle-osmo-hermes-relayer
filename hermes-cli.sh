#!/usr/bin/env bash
# Wrapper to invoke `hermes` against the in-volume config from outside the
# entrypoint context. Useful for ad-hoc diagnostics inside the container:
#   docker exec hermes-relayer-v018 hermes-cli health-check
#   docker exec hermes-relayer-v018 hermes-cli query channel ends ...
#   docker exec hermes-relayer-v018 hermes-cli keys list --chain mantle-1
#
# Why a wrapper: hermes' default config lookup is ~/.hermes/config.toml, but
# inside the container HOME may not be set when invoked by `docker exec` and
# the binary then aborts with `failed to read config file`. We export HOME
# explicitly and pass `--config` so `hermes-cli ...` Just Works.
exec env HOME=/home/hermes /usr/bin/hermes --config /home/hermes/.hermes/config.toml "$@"
