# Mantle archive node — orphan packet recovery plan

The relayer is healthy but **562 historical packets** (mantle 408 +
osmosis 154) are stuck because no public RPC indexes the `send_packet`
events for the heights when those packets were emitted. This file
documents how to recover them.

## What we tried (2026-04-28)

| Approach | Result |
|----------|--------|
| Genesis sync with v1.0.1 binary | **panic on InitChain** — origin genesis needs the v0.3.0 binary |
| State-sync to height ~17M | **not served** — peers only snapshot at recent heights (~last 5K blocks) |
| Polkachu archive snapshot (free) | **only ~last 100K blocks of tx-index** |
| publicnode mantle | **earliest block 21M**, can't serve h~20M; also stub validator pubkey rejects hermes |
| Polkachu archive snapshot (paid) | **not yet contacted** — `hello@polkachu.com` |
| Numia / Imperator commercial archive | **not yet contacted** |

## Why hermes can't relay these

Hermes uses `tx_search` against the source chain to find the original
`send_packet` event for each pending sequence. It needs:

1. The packet data (port, channel, sequence, timeout, payload) — found
   in the tx itself by hash.
2. The current packet commitment proof from IBC store at LATEST height
   (does not need historical block data).

If `tx_search` returns 0 results, hermes can't construct MsgRecvPacket
or MsgTimeout and gives up. The error is exactly:

```
no packet data was pulled at height <=1-X for sequences A..=B,
this might be due to the data not being available on the configured endpoint.
```

## Plan: cosmovisor genesis sync (proper way)

This is the only path that gives **full** tx-index from sequence 0.

### 1. Build the upgrade binary chain

AssetMantle's mainnet has gone through these binary upgrades. Each
release tag in `github.com/AssetMantle/node` corresponds to a
governance-enacted upgrade. Determine the upgrade height for each from
the chain's gov proposals (or by querying live RPC for `software_upgrade`
events).

| Release | Date | Upgrade name (cosmovisor dir) | Upgrade height |
|---------|------|-------------------------------|----------------|
| `v0.3.0` | 2022-04-18 | `genesis` (this is the launch binary) | 1 |
| `v1.0.0-RC1` / `v1.0.0` | 2023-08-18 | (TBD: query gov proposal #?) | TBD |
| `v1.0.1` | 2024-02-06 | (TBD: query gov proposal #?) | TBD |

Query upgrade heights:

```bash
# All historical software_upgrade gov props
curl -sS https://rpc.assetmantle.one/tx_search?query='"upgrade.module=upgrade"' | jq '.result.txs[].height'
# Or directly via REST:
curl -sS https://rest.assetmantle.one/cosmos/upgrade/v1beta1/applied_plan/<name>
```

### 2. Lay out cosmovisor

```
~/.mantleNode/
├── config/         (genesis.json + config.toml + node_key.json)
├── data/           (empty — sync will fill this)
└── cosmovisor/
    ├── genesis/bin/mantleNode    -> v0.3.0
    └── upgrades/
        ├── <upgrade1-name>/bin/mantleNode  -> v1.0.0
        └── <upgrade2-name>/bin/mantleNode  -> v1.0.1
```

cosmovisor automatically swaps binaries when it sees an upgrade plan
fire at the upgrade height.

### 3. Run with full archive flags

```bash
DAEMON_NAME=mantleNode \
DAEMON_HOME=~/.mantleNode \
DAEMON_RESTART_AFTER_UPGRADE=true \
cosmovisor run start \
  --pruning nothing \
  --rpc.laddr tcp://127.0.0.1:26657 \
  --p2p.laddr tcp://0.0.0.0:26656 \
  --log_level info
```

`pruning = "nothing"` is already in our `app.toml`. `indexer = "kv"` in
`config.toml` is also already set. So tx-index + state will be retained
from genesis once the sync replays through.

### 4. Estimated time + disk

- **Sync time**: ~2-3 days on this hardware (Ryzen 9 3900X, 128GB RAM,
  NVMe). Replay rate ~50-150 blocks/sec depending on tx density.
- **Disk**: ~80-100 GB final archive size.
- **Network**: ~50-100 GB pulled from peers during sync.

### 5. Switch hermes to use it

Once synced, point `MANTLE_RPC_PRIMARY` at our new local node:

```bash
MANTLE_RPC_PRIMARY=http://127.0.0.1:26657
MANTLE_GRPC=http://127.0.0.1:9090
```

Then trigger `hermes clear packets --chain mantle-1 --port transfer
--channel channel-0` — it should now find the tx_search results for
all 408 mantle orphans and submit MsgRecvPacket / MsgTimeout for each.

For osmosis-side orphans (154), we'd need a similar archive on the
osmosis side OR a paid archive RPC. Osmosis archive is much larger
(~5TB).

## Plan: paid archive RPC (faster, $$)

Numia (`https://numia.xyz`) and Imperator (`https://imperator.co`) sell
archive RPC access starting around $50-200/month per chain. Their
archives retain tx-index from genesis indefinitely.

For our use case (relay 562 stuck packets, then revert to public RPCs)
this could be a one-month spend (~$100) instead of a multi-day sync.

Contact:
- Polkachu paid archive: `hello@polkachu.com` (check pricing)
- Numia: `https://numia.xyz/contact`
- Imperator: `https://imperator.co/contact`

## Why we deferred this

The 562 orphans pre-date the channel recovery (governance proposals #82
and #1010). The original senders/receivers have likely written them off
months ago. **Recovering them is a courtesy, not a critical fix.**
The relayer is healthy and will relay all NEW packets normally.

If/when we sync the archive node, hermes will pick up the orphans
automatically without any config change.

---

## ✅ UPDATE 2026-04-28 — orphan recovery actually working via thin proxy

Deep research session uncovered a fourth path that doesn't require any
of the above. **publicnode mantle has tx-index back to at least h=16893918
(2025-03-31, ~13 months old)** — covering every send_packet event for our
408 mantle orphans. The block storage is pruned (lowest=21115497) but
hermes only needs tx data, not historical block proofs, to reconstruct
MsgRecvPacket / MsgTimeout. The sole blocker was publicnode's stub
all-zero Secp256k1 validator pubkey on `/status`, which hermes' serde
parser rejects.

Solution: `scripts/mantle-rpc-proxy/main.go` — a 100-line Go reverse
proxy that forwards everything to publicnode and rewrites just the
`validator_info.pub_key` field on `/status` (both REST `GET /status` and
JSON-RPC `POST /` with `{"method":"status",...}`). The replacement is
a real Ed25519 pubkey from the actual validator set; hermes uses it
only to satisfy parsing — light-client trust still flows through
`/validators` + commit signatures.

Test run 2026-04-28T10:39Z (orphan-test container):
- Hermes pointed at proxy on `127.0.0.1:18903`
- `clear packets --chain mantle-1 --port transfer --channel channel-0`
  found 228 unreceived m→o packets and 100 unacked ones.
- Pulled all 228 packet data from publicnode's tx-index successfully.
- Submitted MsgRecvPacket / MsgTimeout batches: ~213 packets cleared in
  ~10 min (mantle commitment count 408 → 195) before the manual `clear`
  loop hit gas-underestimate + sequence-collision retries against the
  parallel-running home + Akash relayers.

Production wiring (done 2026-04-28T10:51Z):
- Proxy runs on `0.0.0.0:18903` so docker bridge can reach it via
  `172.17.0.1:18903`.
- Home docker `hermes-relayer` recreated with
  `MANTLE_RPC_PRIMARY=http://172.17.0.1:18903`. With
  `clear_on_start = true` it auto-clears every restart; with
  `clear_interval = 100` it sweeps every ~10 min thereafter.
- Wallet drain so far: 0.06 MNTL + 0.79 OSMO in tx fees (~$0.50 total).

Remaining gaps as of 2026-04-28T10:51Z:
1. **Osmosis side** (152 orphans 51441..55379): publicnode osmosis IS
   stub-pubkey'd AND its tx-index does NOT cover these sequences (0
   results for seq 51441). Numia is paywalled (HTTP 401). No public
   osmosis RPC tested has tx-index this deep. Options: paid
   ($50-200/mo) or self-host osmosis archive (~5TB).
2. **45 mantle→osmosis acks** (216389..222646 + 229985..230002):
   received on osmosis, ack pending back to mantle. Same blocker —
   needs osmosis-side `write_acknowledgement` events from old heights.
3. **100 osmosis→mantle acks** (osmo-ch232 seq 54859..55212): mantle
   received them, write_ack events on mantle have publicnode tx-index
   coverage → these SHOULD clear via the proxy as the home docker
   keeps retrying.

TODO:
- Move proxy from `nohup` to a systemd user unit so it survives reboot.
- For Akash deployment: bake the proxy binary into the wrapper image
  as a sidecar (same container, small Go binary), or add a separate
  service in the SDL.
- Investigate paid osmosis archive (Polkachu, Numia, Imperator)
  one-month spend to clear the remaining 152 + 45 osmosis-side
  orphans, OR write them off permanently (which is the 2026-05-28
  follow-up cron's purpose).
