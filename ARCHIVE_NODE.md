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
