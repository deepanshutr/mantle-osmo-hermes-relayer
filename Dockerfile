# Wrapper image for the mantle-1 <-> osmosis-1 IBC relayer Akash deployment.
#
# Layered on top of the upstream informalsystems/hermes image so we get
# the vetted Hermes binary verbatim. We add envsubst (gettext-base) for
# rendering the config template, our pre-shipped config.toml.template,
# and the entrypoint that performs first-boot init (mnemonic restore +
# config render + start).
#
# Build:
#   docker build -t ghcr.io/assetmantle/relayer-mantle-osmosis-hermes:v0.1.0 .
# Publish:
#   docker push ghcr.io/assetmantle/relayer-mantle-osmosis-hermes:v0.1.0
#
# Why 1.13.1 and not v1.13.3?
#   v1.13.3 was released 2025-09-03 on GitHub but no Docker image was
#   published for it (or for v1.13.2). Both Docker Hub and ghcr.io stop
#   at 1.13.1 (May 2025). 1.13.0 added pull-mode event_source, so 1.13.1
#   covers everything we need. Reproducible digest:
#     sha256:c2d8387fe885067baf1b083756439481bb28ae9a812efbd2c3e91d5cbe3088c8
#   (multi-arch index, identical on Docker Hub and ghcr.io).

# Build stage: compile mantle-rpc-proxy (small Go binary) so the
# wrapper image can run it as a sidecar before hermes. Why baked-in:
# publicnode AssetMantle RPC is the only public endpoint with tx_search
# back to the orphan-packet heights, but it serves a stub all-zero
# Secp256k1 validator pubkey on /status that hermes 1.13's serde
# rejects. The proxy rewrites just that one field.
FROM golang:1.22-alpine AS proxy-builder
WORKDIR /build
COPY scripts/mantle-rpc-proxy/go.mod scripts/mantle-rpc-proxy/main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags='-s -w' -o /mantle-rpc-proxy main.go

FROM informalsystems/hermes:1.13.1

# Override OCI source label so ghcr links the package to OUR public repo
# (not informalsystems/hermes). New ghcr packages inherit visibility from
# the linked repo, so this matters only for fresh-name pushes.
LABEL org.opencontainers.image.source=https://github.com/deepanshutr/mantle-osmo-hermes-relayer
LABEL org.opencontainers.image.description="Hermes 1.13.1 wrapper for mantle-1 <-> osmosis-1 Akash relayer"

# Upstream image: user `hermes` (uid 2000, gid 2000), HOME=/home/hermes,
# ENTRYPOINT=/usr/bin/hermes. Base is ubuntu:latest with libssl1.1 backported.
USER root

# envsubst (config render), tini (PID 1 / SIGTERM forwarding), shred (mnemonic).
RUN apt-get update && \
    apt-get install -y --no-install-recommends gettext-base tini coreutils && \
    rm -rf /var/lib/apt/lists/*

# Bake the config template OUTSIDE /home/hermes/.hermes so it survives the
# Akash persistent-volume mount. Entrypoint copies it into the volume on first
# boot. (Anything under the mount path is hidden at runtime.)
COPY config.toml.template /usr/local/share/hermes/config.toml.template
COPY entrypoint.sh        /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Sidecar proxy binary (see proxy-builder stage above).
COPY --from=proxy-builder /mantle-rpc-proxy /usr/local/bin/mantle-rpc-proxy

# Akash mounts the persistent volume at /home/hermes/.hermes (per SDL),
# which preserves keys and config across restarts. We stay root so the
# entrypoint can chown the freshly-mounted (root-owned) volume on first
# boot, then drop privileges to hermes via gosu before exec'ing hermes.
RUN apt-get update && apt-get install -y --no-install-recommends gosu && rm -rf /var/lib/apt/lists/*
WORKDIR /home/hermes

# tini reaps zombies + forwards SIGTERM cleanly to the hermes process.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
