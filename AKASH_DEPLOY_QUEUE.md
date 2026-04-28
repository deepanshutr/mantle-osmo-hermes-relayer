# Akash redeploy queue — v0.1.7 → v0.1.8

Local validation complete (`V018_TEST_RESULTS.md`). When ready to push the
fixes to the Akash deployment (DSEQ 26581304, provider akash1x2g8wf...), run:

## (a) Commands

```bash
# 1. Push v0.1.8 image to GHCR (writes the manifest digest into ghcr metadata).
#    Requires: gh auth token with read:packages + write:packages.
echo "$(gh auth token)" | docker login ghcr.io -u deepanshutr --password-stdin
docker push ghcr.io/deepanshutr/mantle-osmo-hermes-relayer:v0.1.8

# 2. Render + send manifest update to the existing DSEQ. deploy.sh detects
#    deployment-state.json and switches to "tx deployment update" mode,
#    preserving DSEQ/lease/persistent-volume/keys. The SDL already references
#    v0.1.8 (committed during the local fix-and-validate cycle).
cd /home/deepanshutr/akash-relayer
bash deploy.sh

# 3. Tail the new container's logs to verify it picks up the v0.1.8 image
#    and the pull-mode mantle config.
DSEQ=$(jq -r .akash_dseq deployment-state.json)
PROV=$(jq -r .akash_provider deployment-state.json)
provider-services lease-logs \
  --dseq "$DSEQ" --provider "$PROV" --service relayer --follow \
  --from autonomy --keyring-backend test --home ~/.akash | tee /tmp/akash-v018-boot.log
```

## (b) Expected DSEQ after redeploy

**Same DSEQ: 26581304.** This is a `tx deployment update` (manifest re-send),
not a fresh deployment. Lease unchanged. Persistent volume `relayer-data`
preserved → keys + init marker survive the rolling restart. New container
gets the v0.1.8 image with:
- mantle `event_source = pull, interval = 6s`
- osmo `event_source = push, url = wss://osmosis.rpc.kjnodes.com/websocket`
- `clear_interval = 0`, `clear_on_start = false`
- baked `/usr/local/bin/hermes-cli` wrapper

Provider may briefly flap (~30s) during image swap. Post-swap PID changes
(verified via `provider-services lease-status`); confirm by checking
`x-server-time` header on the telemetry endpoint or `started_at` timestamp.

## (c) Verification steps post-akash-deploy

1. **Image swap confirmed.** Check the running container manifest:
   ```bash
   provider-services lease-status \
     --dseq "$DSEQ" --provider "$PROV" \
     --from autonomy --keyring-backend test --home ~/.akash
   ```
   Expect `image: ghcr.io/deepanshutr/mantle-osmo-hermes-relayer:v0.1.8`.

2. **Boot logs healthy.** From the lease-logs tail:
   - `[entrypoint ...] rendering config.toml from template (envsubst)`
   - `hermes config validate` exits 0
   - `init marker present, skipping key restore`
   - `INFO ... scanned chains:` listing both `mantle-1`/channel-0 and `osmosis-1`/channel-232 as STATE_OPEN
   - `spawned packet worker: packet::channel-232/transfer:osmosis-1->mantle-1` (osmo direction always spawns at boot due to existing pending acks).
   - **NO** `clearing triggered` or `no packet data was pulled` warnings — verifies clear_interval=0 took effect.
   - **NO** `rpc.assetmantle.one 429` errors — verifies polkachu primary swap.

3. **Telemetry probe.**
   ```bash
   EP=$(jq -r .endpoint deployment-state.json)
   curl -sS "http://${EP}/metrics" | grep -E '^(workers|wallet_balance|backlog_size|receive_packets_confirmed_total)' | head -20
   ```
   Expect `workers{type="packet"} >= 1` (osmo→mantle worker), wallet balances
   matching weekly-monitor's last reading.

4. **Functional smoke test.** Re-run the autonomy IBC bridge test (small):
   ```bash
   /home/deepanshutr/autonomy/internal/wallet/atomone/.venv/bin/python \
     /home/deepanshutr/autonomy/scripts/ibc_test_mantle_osmo.py --leg out --amount 100000
   ```
   Expect <90s round-trip (allow first-cycle warmup margin). Then leg back.

5. **Stop the local home-server hot-standby** (this v0.1.8 container) for
   10 minutes after Akash flips. Verify Akash alone keeps relaying by
   sending a 0.1 MNTL test through and confirming the recv tx memo reads
   `hermes:mantle-osmo` AND originates from the akash provider's egress IP
   (or simply that the recv lands in <90s). Then restart the local container
   so we keep the dual-relayer redundancy.

## (d) Regressions that might affect remote-only env

Local has different network conditions than Akash provider. Things that
could break ONLY on Akash:

- **Provider firewall / egress.** Akash providers occasionally block outbound
  TLS to certain CDNs. Polkachu RPC (Cloudflare) and kjnodes (own infra)
  are widely used — low risk — but if mantle pull starts failing on Akash
  with no symmetric local failure, swap `MANTLE_RPC_PRIMARY` to
  `https://rpc.assetmantle.one` (env var change in deploy.yaml; no rebuild).

- **Persistent volume re-mount quirks.** If Akash's storage layer hiccups
  during the image swap, the volume may temporarily mount empty. Symptom:
  entrypoint runs key-restore again from `RELAYER_MNEMONIC`. Mitigation
  is automatic (idempotent), but watch for double-billed gas if the
  restored container disagrees with the akash-deployed one for the same
  account.sequence (account_sequence_mismatch errors are harmless).

- **Telemetry port `global: true`.** Already exposed in v0.1.7. v0.1.8
  doesn't change SDL ports. If the lease IP changes (provider re-allocates
  port mapping), update `endpoint` in `deployment-state.json` and rerun
  `health-check.sh` to re-baseline.

- **GHCR pull rate.** Provider pulls v0.1.8 on update. If GHCR
  throttles (5GB/hour anonymous limit), the credentialed pull
  (`__GHCR_TOKEN__` injected by `deploy.sh`) bypasses it. Verify the
  token still has `read:packages` scope — `gh auth status`.

- **clear_interval=0 + Akash startup.** Container restarts on Akash may
  surface a brief "no packet workers spawned for mantle direction yet"
  window if there are no pending mantle outbound packets at boot. With
  `clear_on_start=false` we don't proactively scan. The first new packet
  triggers worker spawn; until then the relayer is *passively* monitoring.
  This matches local v0.1.8 behavior — not a regression.

## Local v0.1.8 status when redeploying

Leave the local v0.1.8 container running during the Akash redeploy. The
two relayers share the same wallet; Cosmos IBC dedupes via packet sequence
on-chain. The "loser" sees `account_sequence_mismatch` and discards
harmlessly. Once Akash v0.1.8 is verified healthy, both can run
indefinitely as planned (akash primary, home hot-standby).

## Rollback plan

If v0.1.8 misbehaves on Akash:

```bash
# 1. Revert deploy.yaml to v0.1.7 image tag
sed -i 's/relayer:v0.1.8/relayer:v0.1.7/g' /home/deepanshutr/akash-relayer/deploy.yaml

# 2. Re-render + update — same DSEQ
bash /home/deepanshutr/akash-relayer/deploy.sh
```

v0.1.7 image is still in GHCR (not pruned). 30-second downtime during
revert. Local container can hold packets in the meantime.
