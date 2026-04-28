# mantle-1 ↔ osmosis-1 IBC relayer on Akash (Hermes)

Production deployment package for a permanent IBC relayer on the
mantle-1 ↔ osmosis-1 path (channel-0 ↔ channel-232). Provider target is
`zencloud.eu` for continuity with the existing `rpc.assetmantle.one`
deployment (DSEQ 26513386).

## Why Hermes (changelog 2026-04-27)

This package previously used `cosmos/relayer` (rly) v2.6.0-rc.2. The
`cosmos/relayer` repo was archived 2025-04-16, foreclosing security patches.
We migrated to `informalsystems/hermes` v1.13.1 — slower-moving but **not
archived**, last release 2025-09-03, last commit 2025-09-23. The rly version
is preserved at `.rly-archived/` for reference; resurrect it by moving those
files back if Hermes turns out to be a worse fit. Switching now avoids
any DSEQ rewrite later: nothing is live yet, no operational habits formed.

## What this deploys

A single-replica `informalsystems/hermes:1.13.1` instance on Akash:

- 0.5 vCPU / 768 MiB RAM / 1 GiB persistent volume at `/home/hermes/.hermes`
- `hermes start` (no path arg — Hermes auto-discovers paths from any open
  channel where both chains are configured)
- Public TCP port 3001 for the Prometheus telemetry endpoint
- Wallet: dedicated, separate from the home server's relayer keys

The home server keeps a hot-standby Hermes container running against the
same `~/.relayer-akash/` mnemonic. Both relayers will compete to relay
packets and Cosmos IBC dedupes naturally — the loser's tx fails harmlessly
with "packet already relayed" / "outdated client" errors.

## Files

| File                              | Purpose |
|-----------------------------------|---------|
| `deploy.yaml`                     | Akash SDL v2.0 template (no secrets) |
| `Dockerfile`                      | Wrapper image: hermes:1.13.1 + envsubst + tini + entrypoint |
| `entrypoint.sh`                   | Container init (envsubst config + key restore + `hermes start`) |
| `config.toml.template`            | Hermes 1.13 config; RPC/gRPC/WS URLs are `${ENV}` placeholders |
| `deploy.sh`                       | One-shot driver: balance check, decrypt mnemonic, render, create lease, send manifest |
| `deployment-state.json`           | Written by `deploy.sh`; holds DSEQ + provider for idempotent updates |
| `deploy-rendered.yaml`            | Transient, auto-shredded (contains the mnemonic) |
| `.rly-archived/`                  | Frozen snapshot of the old rly version (chains/, paths/, deploy.*, etc.) |

## Pre-conditions

1. **AKT balance on `akash12yfk3mc2exa3zch7qh6w5ah9s3n0fadtpfurdj`**
   - Currently 7.228 AKT (~$36 at $5/AKT) — sufficient for ~13 months at the
     SDL's 100 uakt/block placement bid.
   - Top up to 10+ AKT to leave runway for mainnet escrow + lease churn.

2. **Akash CLI**: `provider-services` v0.10.0 already at
   `/home/deepanshutr/go/bin/provider-services`. The `autonomy` key is
   in `~/.akash/keyring-test/`.

3. **Relayer wallet**: a parallel agent has placed the dedicated wallet at
   `/home/deepanshutr/.relayer-akash/`:
   - `addresses.json`: `{ "mantle": "mantle1...", "osmo": "osmo1..." }`
   - `mnemonic.enc`: AES-GCM encrypted 24-word BIP39 mnemonic
   - `.encryption_key`: 32-byte AES-GCM key used to decrypt the mnemonic

   Both relayer wallets must be funded:
   - mantle1: 5+ MNTL for gas (`umntl`) — currently funded with 50 MNTL
   - osmo1: 1+ OSMO for gas (`uosmo`) — currently funded with 5 OSMO

4. **Recovery proposals**: clients `07-tendermint-0` (mantle) and
   `07-tendermint-1923` (osmosis) must be active. Status as of 2026-04-27:
   - osmosis prop #1010: PASSED 2026-04-26 ✓
   - mantle prop #82: 99.985% YES, ends 2026-04-28 04:18 UTC

   Both connections (`connection-0` ↔ `connection-1498`) and channels
   (`channel-0` ↔ `channel-232`) are reported `STATE_OPEN` by both LCDs.

5. **Image published**: `ghcr.io/assetmantle/relayer-mantle-osmosis-hermes:v0.1.0`
   must exist (see "Build & publish" below). The SDL pins this exact tag.

## Endpoints (verified 2026-04-27)

The SDL hardcodes these — change if any go down. Hermes 1.13 needs a working
`grpc_addr` per chain; without it, simulation/account queries fail.

| Chain   | Type | Endpoint                                            | Probe result |
|---------|------|------------------------------------------------------|--------------|
| mantle  | RPC  | `https://assetmantle-rpc.polkachu.com:443`          | sync at height 22099291 |
| mantle  | gRPC | `http://assetmantle-grpc.polkachu.com:14690` (h2c)  | HTTP/2 PROTOCOL_ERROR on `GET /` (gRPC alive) |
| mantle  | WS   | `wss://assetmantle-rpc.polkachu.com/websocket`      | (assumed; same hostname as RPC) |
| osmosis | RPC  | `https://rpc.osmosis.zone:443`                       | always healthy |
| osmosis | gRPC | `http://osmosis-grpc.polkachu.com:12590` (h2c)      | HTTP/2 415 (`application/grpc`, gRPC alive) |
| osmosis | WS   | `wss://rpc.osmosis.zone/websocket`                   | always healthy |

Backups (also verified gRPC-alive):
- `https://grpc-assetmantle.publicnode.com:443` (TLS h2)
- `https://grpc.osmosis.zone:443` (TLS h2 — note: not :9090, that port is closed)

## Build & publish (one-time, before first deploy)

```bash
cd /home/deepanshutr/akash-relayer
docker build -t ghcr.io/assetmantle/relayer-mantle-osmosis-hermes:v0.1.0 .

# Login with a PAT that has write:packages scope on the assetmantle org.
echo "$GHCR_PAT" | docker login ghcr.io -u <gh-user> --password-stdin
docker push ghcr.io/assetmantle/relayer-mantle-osmosis-hermes:v0.1.0
```

The image is **public**; pulling it on the Akash provider does not require
credentials. Verify it pulls anonymously before deploying:

```bash
docker pull ghcr.io/assetmantle/relayer-mantle-osmosis-hermes:v0.1.0
```

The wrapper layers ~25 MB on top of the upstream image (envsubst + tini +
config template + entrypoint). Total compressed size ~70 MB.

## Deploy

```bash
cd /home/deepanshutr/akash-relayer
bash deploy.sh
```

`deploy.sh` auto-detects the mnemonic encryption format. The relayer-wallet
agent uses AES-GCM with a 32-byte key at `~/.relayer-akash/.encryption_key`;
if you switch to `gpg --symmetric`, set `MNEMONIC_GPG_PASSPHRASE`.

The script:

1. Verifies Akash CLI + AKT balance + addresses.json + mnemonic file.
2. Decrypts the mnemonic into a memory-only env var.
3. Renders `deploy-rendered.yaml` injecting `RELAYER_MNEMONIC=…` into the
   service env block. File is mode 0600 and shredded on exit.
4. Submits `tx deployment create`, parses the DSEQ.
5. Polls `query market bid list` for up to 5 min.
6. Filters bids by provider host_uri matching `zencloud.eu`; falls back
   to lowest-price bid if zencloud doesn't bid.
7. `tx market lease create`.
8. `send-manifest`.
9. Writes `deployment-state.json`.

### Cold-deploy expected wall clock (after #82 enacts)

- Image build + push (one-time): ~5 min
- AKT funding top-up if needed: ~5 min (Cosmos→Akash via Skip)
- `bash deploy.sh` end-to-end: ~10 min
  - tx inclusion: ~10 s × 3
  - bid wait: 30–120 s typical on healthy providers
  - manifest send + first relay: ~60 s
- **Total: ~20 min from "ready to go" to first relayed packet**

The image is the long pole on first build (Hermes is Rust, but we don't
compile it — we layer on the upstream binary, so the build itself is ~30 s).

## Update

Re-run `deploy.sh`. If `deployment-state.json` exists, it switches to
`tx deployment update` mode and re-sends the manifest to the same provider.
This lets you rotate RPC endpoints (env var changes in `deploy.yaml`)
without losing the persistent volume / keys.

To change providers, delete `deployment-state.json` first, then re-run.

## Teardown

```bash
DSEQ=$(jq -r .dseq deployment-state.json)
provider-services tx deployment close --dseq "$DSEQ" \
  --from autonomy --keyring-backend test \
  --node https://rpc.akashnet.net:443 --chain-id akashnet-2 \
  --gas-prices 0.025uakt --gas auto --gas-adjustment 1.5 -y
rm deployment-state.json
```

## Operate

```bash
# Tail logs
DSEQ=$(jq -r .dseq deployment-state.json)
PROV=$(jq -r .provider deployment-state.json)
provider-services lease-logs \
  --dseq "$DSEQ" --provider "$PROV" --service relayer --follow \
  --from autonomy --keyring-backend test --home ~/.akash

# Inspect Prometheus telemetry. Hermes exports:
#   ibc_client_updates_submitted_total{...}
#   ibc_acknowledgment_packets_confirmed_total{...}
#   ibc_workers{type="packet|client|wallet|...", chain="mantle-1|osmosis-1"}
#   wallet_balance{chain, account, denom}    <- watch these for gas funds
EP=$(jq -r .endpoint deployment-state.json)
curl -sS "http://${EP}/metrics" | grep -E '^(ibc_|wallet_)'

# Health check via Hermes CLI (run inside container or against the same config):
#   hermes health-check
#   hermes query channel ends --chain mantle-1 --port transfer --channel channel-0
#   hermes query client status --chain mantle-1 --client 07-tendermint-0
```

## Hot-standby on home server

The home server's GLIBC 2.35 (Ubuntu 22.04 jammy) **cannot run the Hermes
binary natively** — the upstream image links against libssl1.1 which jammy
removed. Run Hermes in Docker against the same wallet store:

```bash
docker run --rm -d --name hermes-standby \
  --network host \
  -v /home/deepanshutr/.relayer-akash:/keys:ro \
  -v hermes-config:/home/hermes/.hermes \
  -e MANTLE_RPC_PRIMARY=https://assetmantle-rpc.polkachu.com:443 \
  -e MANTLE_GRPC=http://assetmantle-grpc.polkachu.com:14690 \
  -e MANTLE_WS=wss://assetmantle-rpc.polkachu.com/websocket \
  -e OSMO_RPC_PRIMARY=https://rpc.osmosis.zone:443 \
  -e OSMO_GRPC=http://osmosis-grpc.polkachu.com:12590 \
  -e OSMO_WS=wss://rpc.osmosis.zone/websocket \
  -e RELAYER_MNEMONIC="$(python3 -c "
import os
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
key = open('/home/deepanshutr/.relayer-akash/.encryption_key','rb').read()
blob = open('/home/deepanshutr/.relayer-akash/mnemonic.enc','rb').read()
print(AESGCM(key).decrypt(blob[:12], blob[12:], None).decode().strip())
")" \
  ghcr.io/assetmantle/relayer-mantle-osmosis-hermes:v0.1.0
```

To prevent the home Hermes from spamming during normal operation, you
can run with `--profile=clear-only` (custom CLI mode) or simply leave it
stopped and start it manually if Akash drops. Both relayers signing with
the same mnemonic do not corrupt anything — Cosmos accepts only the first
ack tx; the second's `account_sequence_mismatch` error is logged and
discarded.

## Fund AKT runway

Bid is `100 uakt/block` → ~17280 uakt/day → ~520k uakt/month → ~0.52 AKT/mo.
At AKT=$5 that's $2.60/mo. 7 AKT covers ~13 months.

Top-up routes:
- Send AKT directly from any Cosmos chain via Skip
  (`https://skip.money` → akashnet-2 → `akash12yfk3mc2exa3zch7qh6w5ah9s3n0fadtpfurdj`)
- Withdraw from a CEX that lists AKT (Kraken, MEXC, Gate)

## Rotate the relayer mnemonic

1. Generate new wallet (`mantle1...`, `osmo1...`); update
   `/home/deepanshutr/.relayer-akash/addresses.json` and `mnemonic.enc`.
2. Fund the new addresses.
3. Sweep dust from the old addresses to a treasury wallet.
4. Re-run `deploy.sh` — but first delete `deployment-state.json` to force
   a fresh deployment (so the persistent volume is wiped and the new
   mnemonic gets restored on first boot of the fresh container). Or
   `provider-services tx deployment close` the existing one.

Hermes' init marker (`.akash-init-done`) prevents accidental re-import on
reboot. To force re-restore on a live deployment without teardown, exec
into the pod and `rm /home/hermes/.hermes/.akash-init-done`, then bounce.

## Issues / TODO

1. **Hermes Docker tag lag**: GitHub release tags up to v1.13.3 (2025-09-03)
   exist but Docker images stop at 1.13.1 (2025-05-21). 1.13.0 added pull-mode
   `event_source` so 1.13.1 covers our needs. Watch
   `https://hub.docker.com/r/informalsystems/hermes/tags` and roll forward
   when 1.13.2/1.13.3 ship as images. Pinned digest in Dockerfile comment
   is for 1.13.1: `sha256:c2d8387f...3088c8`.

2. **trust_threshold and trusting_period**: Hermes uses these when SUBMITTING
   ClientUpdate messages. They MUST be ≤ what the on-chain client state
   advertises. mantle prop #82 substitutes the client with `trust_level=1/3,
   trusting_period=10days, unbonding=21days`; osmosis prop #1010 substitutes
   with `trust_level=2/3, trusting_period=14days, unbonding=21days`. We've
   set Hermes config to `1/3, 7days` and `2/3, 10days` respectively — both
   conservative. After the proposal enacts, double-check by reading the
   on-chain client state (`/ibc/core/client/v1/client_states/07-tendermint-0`)
   and tighten if it diverged.

3. **Backup RPC unused at runtime**: Hermes 1.13 doesn't natively rotate
   between primary and backup RPC endpoints (unlike rly's `backup-rpc-addrs`).
   The `MANTLE_RPC_BACKUP` / `OSMO_RPC_BACKUP` env vars in the SDL are
   informational. To actually use them, run `deploy.sh` again and swap the
   value of `MANTLE_RPC_PRIMARY` / `OSMO_RPC_PRIMARY` (both env-var changes
   trigger a `deployment update`, no DSEQ change). For automatic failover,
   front the RPCs with an HAProxy / Cloudflare load balancer. Out of scope.

4. **Mnemonic-in-env risk**: identical to the rly version — the rendered
   SDL is uploaded to the Akash provider, where the mnemonic ends up
   readable to that provider's operator. zencloud is the same provider
   already trusted with `rpc.assetmantle.one` TLS termination; risk profile
   is unchanged. For higher assurance, swap to a Vault/SOPS init-container.

5. **Telemetry exposure**: port 3001 is `global: true` in the SDL so the
   Prometheus endpoint is reachable from anywhere. Hermes 1.13 metrics are
   non-sensitive (counters, no auth tokens) but they DO leak per-channel /
   per-account state (gas balance, height of last update, etc.). If that's
   a concern, drop `global: true` and reach the metrics via `kubectl
   port-forward` (Akash supports it).

6. **Path auto-discovery quirk**: `hermes start` scans every open channel
   on every configured chain. mantle-1 and osmosis-1 each have a single
   channel pair (`channel-0` ↔ `channel-232`), but if mantle later adds
   more open channels, Hermes will start relaying those too unless you add
   a `[chains.packet_filter]` block with `policy = 'allow'` and only the
   channels you want. Add it preemptively if you want strict scope.

7. **`deploy-rendered.yaml` shred path**: `shred -u` on tmpfs/btrfs/zfs
   is best-effort. The rendered file lives in `/home/deepanshutr/akash-relayer/`
   on the LVM volume — `shred` overwrites the file blocks 3 times. Good
   enough for this threat model.

## Monitoring

Two cron-based scripts feed alerts into the orchctl Telegram bot
(`@x_anyhow_x_bot`):

- **`health-check.sh`** — every 5 minutes. Probes home-container PID +
  metrics endpoint, then probes the Akash provider's metrics endpoint.
  Alerts only on state transitions (newly-down or newly-recovered) so
  Telegram doesn't get spammed every 5 min while a fault persists. Pages
  the operator if BOTH home and Akash are simultaneously down — that's
  the actual outage; single-side loss is degraded but still relaying.

- **`weekly-monitor.sh`** — Mondays 09:00 IST. Comprehensive report:
  AKT lease runway, mantle/osmo wallet balances, IBC client status
  (Active/Expired/Frozen), pending packet trend (delta vs prior week),
  Hermes telemetry liveness. Full report sent to Telegram with action-
  item flags if any threshold is breached.

Cron entries:

```cron
*/5 * * * * /home/deepanshutr/akash-relayer/health-check.sh
0 9 * * 1   /home/deepanshutr/akash-relayer/weekly-monitor.sh
```

Per-run log files:

- `health-check.log` — append-only, recommend `logrotate` for long-term.
- `weekly-monitor.log` — append-only.
- `health-check.state.json` — last-tick status (used for transition detection).
- `weekly-monitor.history.json` — last week's pending-packet counts (used for delta).

Telegram routing uses `notification.telegram.send_alert` from
`~/autonomy/internal/notification/`. Both scripts run in the user's PATH
with `linuxbrew` and `autonomy/.venv` available.
