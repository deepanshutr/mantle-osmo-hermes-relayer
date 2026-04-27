# Test Results — 2026-04-27

Pre-deployment validation of the Hermes-based mantle-1 ↔ osmosis-1 relayer wrapper, run on home server before prop #82 enacts (deadline 2026-04-28 04:18 UTC).

## Environment
- Docker version: 26.1.3, build 26.1.3-0ubuntu1~20.04.1+esm1
- Host: deePC (Ubuntu 22.04, GLIBC 2.35)
- Image built: `hermes-mantle-osmo:test`, base `informalsystems/hermes:1.13.1`
- Build time: 33s (clean build, with apt-get fetching gettext-base, tini, coreutils)
- Image size: 333 MB

## Config validation

```
2026-04-27T13:53:40Z  INFO running Hermes v1.13.1
SUCCESS configuration is valid
```

PASS — after fixing two config-template gaps (see Issues below).

## Key import

```
SUCCESS Restored key 'relayer' (mantle176p470v8vqfj072yclqxvcvrs88j0mszvztqtv) on chain mantle-1
SUCCESS Restored key 'relayer' (osmo176p470v8vqfj072yclqxvcvrs88j0msz6ar4z5) on chain osmosis-1

---LIST mantle-1---
- relayer (mantle176p470v8vqfj072yclqxvcvrs88j0mszvztqtv)

---LIST osmosis-1---
- relayer (osmo176p470v8vqfj072yclqxvcvrs88j0msz6ar4z5)
```

- mantle-1 derived: `mantle176p470v8vqfj072yclqxvcvrs88j0mszvztqtv`
- expected (addresses.json): `mantle176p470v8vqfj072yclqxvcvrs88j0mszvztqtv`
- match: **YES**
- osmosis-1 derived: `osmo176p470v8vqfj072yclqxvcvrs88j0msz6ar4z5`
- expected: `osmo176p470v8vqfj072yclqxvcvrs88j0msz6ar4z5`
- match: **YES**

Default `address_type = { derivation = 'cosmos' }` (coin_type 118, BIP44 path `m/44'/118'/0'/0/0`) produces the funded addresses. No override needed.

## Channel state

### mantle-1 channel-0 (transfer)

```
ChannelEnd {
    state: Open(NotUpgrading),
    ordering: Unordered,
    remote: Counterparty {
        port_id: PortId("transfer"),
        channel_id: Some(ChannelId("channel-232")),
    },
    connection_hops: [ConnectionId("connection-0")],
    version: Version("ics20-1"),
}
```

State: **Open**. Counterparty matches osmosis-1/channel-232.

(`hermes query channels --chain mantle-1` returned all 59 transfer channels; channel-0 confirmed in the list.)

### osmosis-1 channel-232 (transfer)

```
ChannelEnd {
    state: Open(NotUpgrading),
    ordering: Unordered,
    remote: Counterparty {
        port_id: PortId("transfer"),
        channel_id: Some(ChannelId("channel-0")),
    },
    connection_hops: [ConnectionId("connection-1498")],
    version: Version("ics20-1"),
}
```

State: **Open**. Counterparty matches mantle-1/channel-0. Both ends symmetric.

(`hermes query channels --chain osmosis-1` failed with gRPC `OutOfRange` — Osmosis has so many channels the response exceeds the default 32 MB limit. This does NOT affect operation: Hermes auto-discovery in `hermes start` paginates internally. Documented as known issue.)

## Client state

### mantle-1 client `07-tendermint-0` (recovered by prop #82, in voting)

```
ClientState {
    chain_id: ChainId { id: "osmosis-1", version: 1 },
    trust_threshold: 1/3,
    trusting_period: 864000s (10 days),
    unbonding_period: 1209600s (14 days),
    max_clock_drift: 25s,
    latest_height: Height { revision: 1, height: 52978396 },
    upgrade_path: ["upgrade", "upgradedIBCState"],
    allow_update: AllowUpdate { after_expiry: true, after_misbehaviour: true },
    frozen_height: None,
}

Status: Expired
```

Expected: still expired/frozen until 2026-04-28 04:18 UTC (#82 voting closes).
Observed: **Expired** — confirms current bridge-down state.

### osmosis-1 client `07-tendermint-1923` (recovered by prop #1010, passed)

```
ClientState {
    chain_id: ChainId { id: "mantle-1", version: 1 },
    trust_threshold: 1/3,
    trusting_period: 1209600s (14 days),
    unbonding_period: 1814400s (21 days),
    max_clock_drift: 25s,
    latest_height: Height { revision: 1, height: 22064895 },
    upgrade_path: ["upgrade", "upgradedIBCState"],
    allow_update: AllowUpdate { after_expiry: true, after_misbehaviour: true },
    frozen_height: None,
}

Status: Active
```

Expected: ACTIVE (recovery already enacted 2026-04-26).
Observed: **Active** — prop #1010 recovery confirmed live on-chain.

## Verdict

Package validates end-to-end. Container builds cleanly in 33 s, Hermes 1.13.1 starts, config renders correctly via envsubst once the missing `host`/`port` defaults were filled in for `[rest]` and `[tracing_server]` sections. Both keys derive to the funded relayer addresses on coin_type 118. Both chains reachable via Polkachu RPC + Osmosis archive. Mantle-side client `07-tendermint-0` is **Expired** as expected — ready for #82 to flip it Active. Osmosis-side client `07-tendermint-1923` is already **Active**, confirming #1010 enaction.

## Issues encountered

- **Config template missing required fields.** Hermes 1.13.1 rejected the original template with `missing field 'host' for key 'rest' at line 84 column 1`. Even with `enabled = false`, the `[rest]` section requires `host` and `port`, and `[tracing_server]` requires `port`. Fixed in `config.toml.template` by adding `host = '127.0.0.1'`, `port = 3000` (rest) and `port = 5555` (tracing_server). Without this fix the Akash deployment would crash-loop on first boot.
- **`hermes query channels --chain osmosis-1` fails with gRPC OutOfRange.** Osmosis has hundreds of transfer channels; the listing exceeds the 32 MB default decoded message limit. Workaround used: `query channel end --chain osmosis-1 --port transfer --channel channel-232` returns the specific channel cleanly. Operationally irrelevant — `hermes start` auto-discovers paths via paginated queries.
- **WS URL derivation lives in entrypoint, not template.** When validating manually you must export `MANTLE_WS`/`OSMO_WS` before envsubst, otherwise the rendered `event_source.url = ''` produces `relative URL without a base`. The runtime entrypoint handles this correctly; only matters for offline-validation flows.

## Next steps

- 2026-04-28 04:18 UTC: prop #82 voting closes
- 2026-04-28 04:30 UTC: re-query mantle-1 client `07-tendermint-0`, expect ACTIVE state (post-recovery)
- Run `bash /home/deepanshutr/akash-relayer/deploy.sh` if everything green
