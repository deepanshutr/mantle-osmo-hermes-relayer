# Orphan packet recovery — final state 2026-04-28

## Result: 335 / 347 cleared (96.5%)

| Direction       | Started | Cleared | Remaining |
|-----------------|---------|---------|-----------|
| mantle (acks)   | 195     | 195     | **0**     |
| osmo→mantle     | 152     | 140     | **12**    |
| **Total**       | 347     | 335     | 12        |

The 12 remaining (`51441, 52117..52127`) are at h<41M and need a true full-archive
osmosis node — every public RPC's tx-index (lavenderfive, freshstaking, ecostake,
publicnode, validatus, etc.) prunes back to ~h=41M. Only paid archive providers
(Numia / Polkachu private / AllThatNode, $50–200/mo) or a self-hosted archive
(~22 TiB snapshot from ccvalidators) reach further back.

The remaining packets are all osmo→mantle "unreceived" with timeouts already passed.
They are blocked only on retrieving the original `send_packet` event payload — the
IBC packet commitments themselves still exist on osmosis at the current height (they
persist until ack/timeout), so once the event payload is recovered the timeout flow
clears them via lookup against current state, not archive state.

## Two breakthroughs

### 1) Mock-RPC for ack flow (mantle direction, 295 cleared)
- 20 mantle commits used a wasm ack hash from Skip swap_and_action: matches
  `{"result":"<base64 of {\"contract_result\":null,\"ibc_ack\":\"<base64 of {\"result\":\"AQ==\"}>\"}>"}`
- 25 used the standard `{"result":"AQ=="}` ack
- Synthesizing reverse proxy (`osmo-mock.go`) returns fake `tx_search`/`block_search`/`block_results`
  in CometBFT 0.38 format (plain-string attributes, `finalize_block_events`); hermes parses
  the synthesized event, builds proof from real osmosis state via passthrough, submits
  MsgAcknowledgePacket on mantle.

### 2) Timeout flow against current state (osmo direction, 24+ cleared)
The unreceived osmo→mantle packets all had `timeout_timestamp` in the past (Feb 2026,
today is Apr 28). hermes' `tx packet-recv` automatically falls back to MsgTimeout when
timeouts have passed, refunding the original osmo sender.

The unlock: **archive RPC is not actually needed**. IBC packet commitments persist on
the source chain until ack/timeout, so the merkle proof of the commitment is available
at any current height — public RPCs serve it without issue. Only the `send_packet`
event payload needs to be recovered, which lavenderfive's archive tx-index has for
heights ≥ ~41M. We use a second mock (`osmo-mock-recv.go`) to inject that event into
hermes' discovery path while letting all proof queries pass through to the live osmosis
network.

## Files

- `osmo-mock.go` — write_acknowledgement synthesizer (mantle ack flow, port 18905)
- `osmo-mock-recv.go` — send_packet synthesizer (osmo timeout/recv flow, port 18906)
- `mantle-packets.jsonl` — 45 mantle send_packet events for the ack flow
- `osmo-send-packets.jsonl` — osmo send_packet events for the timeout flow
- `standard-ack-seqs.txt`, `custom-ack-seqs.txt`, `osmo-unreceived-seqs.txt` — inventories

## Reproduction — ack flow (mantle direction)

See git log for the full recipe. Summary:

```bash
go build -o osmo-mock osmo-mock.go
./osmo-mock -addr 0.0.0.0:18905 -packets mantle-packets.jsonl &

docker pause hermes-relayer-v018
docker run --rm -v hermes-state:/home/hermes/.hermes \
  -e RELAYER_MNEMONIC=... --user root --entrypoint bash \
  ghcr.io/deepanshutr/mantle-osmo-hermes-relayer:v0.1.8 \
  -c '
    sed -i "s|https://osmosis.rpc.kjnodes.com|http://172.17.0.1:18905|g" /home/hermes/.hermes/config.toml
    exec gosu hermes hermes tx packet-ack \
      --src-chain osmosis-1 --dst-chain mantle-1 \
      --src-port transfer --src-channel channel-232 \
      --packet-sequences <csv>
  '
docker unpause hermes-relayer-v018
```

## Reproduction — timeout flow (osmo direction)

```bash
# 1. Identify pending osmo commitments
curl -s "https://lcd.osmosis.zone/ibc/core/channel/v1/channels/channel-232/ports/transfer/packet_commitments?pagination.limit=300" \
  | jq -r '.commitments[].sequence'

# 2. Recover send_packet events from lavenderfive (archive tx-index, h>=41M)
#    For each seq: GET /tx_search?query="send_packet.packet_src_channel='channel-232' AND send_packet.packet_sequence='X'"
#    Then GET /tx?hash=0x<HASH> to fetch the full event payload.
#    Throttle 10–15s/req; lavenderfive 429s on faster cadence.

# 3. Build osmo-send-packets.jsonl from the recovered events.

# 4. Build and run the recv mock
go build -o osmo-mock-recv osmo-mock-recv.go
./osmo-mock-recv -addr 0.0.0.0:18906 -packets osmo-send-packets.jsonl &

# 5. Pause home docker (avoid wallet collision on osmo signer)
docker pause hermes-relayer-v018

# 6. Run hermes clear packets — auto-detects timeout vs recv per packet
docker run --rm \
  -v hermes-state:/home/hermes/.hermes \
  -e RELAYER_MNEMONIC=... \
  --user root --entrypoint bash \
  ghcr.io/deepanshutr/mantle-osmo-hermes-relayer:v0.1.8 \
  -c '
    sed -i "s|http://172.17.0.1:18905|http://172.17.0.1:18906|g" /home/hermes/.hermes/config.toml
    exec gosu hermes hermes clear packets \
      --chain osmosis-1 --port transfer --channel channel-232 \
      --packet-sequences <csv>
  '

# 7. Unpause home docker
docker unpause hermes-relayer-v018
```

For our 24-seq batch this produced one TimeoutPacket per sequence in a single tx
on osmo, refunding the IBC voucher to each original sender.

## What's still blocked

12 osmo→mantle commitments at h<41M need archive tx-index for the `send_packet` event.
Sequences listed in `osmo-unreceived-blocked-archive.txt`. Probed >25 public/free RPC
endpoints — all tx-index horizons are at h>=41M:

| Endpoint                              | earliest tx-index |
|---------------------------------------|-------------------|
| rpc-osmosis.freshstaking.com:31657    | ~41,066,117       |
| rpc.lavenderfive.com:443/osmosis      | ~41,000,000       |
| rpc.osmosis.zone                      | 57,510,159        |
| osmosis-rpc.publicnode.com:443        | 58,779,971        |
| osmosis-rpc.polkachu.com              | 58,253,324        |
| Numia / Polkachu private / AllThatNode| paid signup       |

To unblock:
- pay for full-archive RPC ($50–200/mo, Numia / Polkachu private / AllThatNode)
- self-host archive (22.4 TiB snapshot from `dl-eu1.ccvalidators.com/SNAPSHOTS/archive/osmosis/`)

For everything else the timeout-vs-current-state trick removes the archive requirement entirely.
