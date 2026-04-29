# Orphan recovery loop — running notes

12 stuck seqs at h<41M on osmo→mantle: 51441, 52117..52127
Approaches tried this loop:

## Iteration 1 (2026-04-28 ~17:19 UTC)

### Tried
- 10 LCDs `/cosmos/tx/v1beta1/txs?events=...` — all returned 0 results
- gRPC archive ports on polkachu/kjnodes/osmosis — DNS doesn't resolve (none exist)
- Numia GraphQL — Unauthorized
- ICF/cosmos.directory bdjuno — DNS doesn't resolve
- snapshots.osmosis.zone listing — only recent + ccvalidators 22.4 TiB

### Conclusion
No new public archive endpoint found. The tx-index horizon at h~41M is universal
across all probed free providers. Going further requires:
1. Paid archive RPC ($50-200/mo, signup-gated)
2. ccvalidators 22.4 TiB snapshot download
3. Community help via GitHub issue / forum

### Next: file GitHub issue with full context

## Iteration 2 (~17:43 UTC)

### Tried
- mantle archive endpoints — polkachu has tx-index from h>=20.6M (most of mantle history),
  publicnode from h=21.1M. But adjacent osmo seqs (51440, 51442, 52116, 52128) return 0
  recv_packet hits even within these ranges. Polkachu's mantle index appears partial
  (only 6 channel-232 recv_packets total — implausibly low).
- rpc.assetmantle.one (our own aggregator) earliest=0 — but mantle's data doesn't help
  for osmo-side send_packet events.
- ccvalidators 22 TiB tarball — supports range requests but lz4+tar isn't random-access,
  full download needed.
- Mintscan / mapofzones — auth-gated or unreachable.

### Conclusion
mantle-side data won't unblock osmo-source orphans. Only path is osmo full archive,
which remains paid-only.

### Next
- Iteration 3: post to Reddit r/cosmosnetwork via API search, ping #osmosis on cosmos
  network discord (autonomous via webhook? unlikely). Check GitHub issue.

## Iteration 3 (~17:55 UTC)

### Tried
- GitHub issue #1 — 0 comments, 0 reactions yet
- Reddit search r/cosmosnetwork — nothing relevant
- forum.cosmos.network — searched, nothing relevant
- **POSTED**: https://github.com/osmosis-labs/osmosis/discussions/9682 (Q&A asking for archive RPC)
- **POSTED**: https://github.com/cosmos/ibc-go/discussions/8918 (Show-and-tell sharing the pattern, includes link to osmosis discussion)

### Result
Two community discussions filed across ibc-go and osmosis-labs. Tooling is shared with the
ibc-go community as a generalizable pattern; the osmosis-labs Q&A directly asks for archive
help with the 12 specific seqs.

### Next iteration (final, ~5 min from deadline)
Will recheck both discussions + issue, finalize state, persist final notes.

## Iteration 4 (extended loop)

### Tried
- rpc.assetmantle.one /tx_search for adjacent recv_packets (51440, 52116, 52128, etc.)
  → all 0; tx-index lowest is h=20,644,001 (same as polkachu mantle)
- mantle has only 8 recv_packets via channel-232 in tx-index window — bulk of channel
  history is below the index horizon
- Numia variants (osmosis-rpc.numia.xyz, api.numia.xyz/v1, explorer.numia.xyz/api) — all Unauthorized
- explorer.assetmantle.one — backend isn't synced/exposing useful tx queries yet
- Community channels: 0 replies on issue + 2 discussions

### Conclusion
mantle's archive doesn't cover the era either. Both osmo and mantle tx-index horizons
are well above where the orphans live. The pattern is universal: validators rotate to
pruned-tx-index at ~6mo intervals.

### Next iteration: validator-specific endpoints + Twitter/Nitter search

## Iteration 5 (extended)

### Tried
- Validator URL pattern sweep (kingnodes, everstake, binary-builders, stakeflow,
  blockdaemon, imperator, etc.) — no hits
- validators.cosmos.directory restake list — only 10 RPC endpoints, all already probed
- Cosmoscan / Mintscan / chainscan / stakingrewards APIs — DNS not found or 404
- Nitter mirrors (nitter.net, poast, xcancel) — Cloudflare-blocked or empty
- DDG search "osmosis archive rpc tx_index 2024" — only links docs.osmosis.zone
  (no archive providers mentioned in docs)
- Official osmosis docs (raw markdown) — no archive RPC listed

### Conclusion
The space is genuinely fully exhausted for free public archive tx-index < h=41M.
The 12 stuck packets require either (a) paid archive subscription with email signup
or (b) self-hosted 22 TiB sync. Both are non-autonomous from this session.

### Status of community channels
- issue #1, osmosis discussion #9682, ibc-go discussion #8918 — all 0 replies

## Iteration 6 (extended)

### Tried
- Fresh retry of all 12 seqs across 13 different public RPCs — 0/12 hits (confirms
  archive horizon is universal at h>=41M, not nondeterministic)
- **Filed**: https://github.com/cosmos/chain-registry/issues/7647 — proposing
  archive-discovery documentation in chain-registry, includes specific ask for
  the 12 seqs
- Cross-linked all 4 channels (issue + 2 discussions + chain-registry issue)

### Result
Archive horizon is hard. Community channels remain at 0 replies but the chain-registry
issue has broader audience than per-chain discussions.

## Iteration 7 (extended)

### Tried
- GitHub code search for hardcoded osmosis archive URLs — found 28 references
- Pulled new RPC list from PulsarDataSolutions/IBC-Token-Data-Cosmos and notional-labs/restake-tools
- Probed 13 new endpoints not in chain-registry:
  - rpc-osmosis-ia.cosmosia.notional.ventures (HTTP/2 protocol err, http1 SSL eof)
  - osmosis.api.onfinality.io/public (DNS not found)
  - osmosis.validator.network (DNS not found)
  - osmosis-rpc.reece.sh (timeout)
  - osmosis-mainnet-rpc.autostake.com (404)
  - rpc-osmosis-01.stakeflow.io (DNS)
  - osmosis-rpc.onivalidator.com (DNS)
  - rpc-osmosis.blockapsis.com (DNS)
  - osmosis-mainnet.rpc.l0vd.com (DNS)
  - osmosis-rpc.quickapi.com (DNS)
  - osmosis.interstellar-lounge.org (DNS)
  - osmosis-rpc.w3coins.io (DNS)
  - rpc-osmosis.cosmos-spaces.cloud (DNS)
- All dead. The list was outdated; many providers shut down.

### Conclusion
The set of operating Osmosis RPCs in 2026 is much smaller than what's indexed in github
configs from earlier years. The endpoints we already probed in chain-registry are the
complete current set.

## Iteration 8 — final wrap

### Tried
- Recheck all 4 community channels — still 0 replies (typical; takes days/weeks)
- Notional cosmosia variants (rpc-osmosis-ia, rpc-osmosis, etc.) — domains
  return parked-page HTML; service is DEAD (notional.ventures retired)

### Final result
1-hour autonomous loop exhausted every free archive avenue. The 12 stuck seqs
(51441, 52117..52127) at h<41M on osmosis-1 channel-232 remain blocked.

### Truly viable resolution paths (all non-autonomous)
1. Pay Numia / Polkachu private / AllThatNode for archive RPC ($50-200/mo, 1mo enough)
2. Self-host: download 22.4 TiB ccvalidators snapshot, sync archive node (~50hr+ at 1Gbps)
3. Wait for community reply on the 4 filed channels (could take weeks)

### Stuck value vs cost (very rough)
- 12 packets × ~5,500 MNTL/packet × $0.01/MNTL ≈ $600 stuck
- Recovery cost: $50/mo paid archive ≈ $50 to unstick all 12 in one batch
- Marginal value if we don't operate the bridge for these specific users

### Files persisted
- `/tmp/orphan-loop/state.json` — full iteration log
- `/tmp/orphan-loop/notes.md` — this writeup
- `~/akash-relayer/scripts/orphan-recovery/` — toolkit + 40 recovered packets, in git

### Community channels filed (all 0 replies after 1hr)
- https://github.com/deepanshutr/mantle-osmo-hermes-relayer/issues/1 (issue)
- https://github.com/osmosis-labs/osmosis/discussions/9682 (Q&A)
- https://github.com/cosmos/ibc-go/discussions/8918 (Show-and-tell)
- https://github.com/cosmos/chain-registry/issues/7647 (chain-registry proposal)
