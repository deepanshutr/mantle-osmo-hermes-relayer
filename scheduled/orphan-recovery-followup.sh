#!/usr/bin/env bash
# One-shot follow-up agent fired by cron on 2026-05-28 to revisit the
# 562 stuck IBC packets from the channel-recovery period.
#
# What it does: launches a fresh Claude Code session with the full
# context as prompt; the agent then probes RPCs, decides whether
# anything has changed, and posts findings to Telegram.
#
# Cron line installed in this user's crontab:
#   17 10 28 5 *  /home/deepanshutr/akash-relayer/scheduled/orphan-recovery-followup.sh

set -uo pipefail
export PATH="/home/deepanshutr/.local/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

LOG="/home/deepanshutr/akash-relayer/scheduled/orphan-recovery-followup.log"
mkdir -p "$(dirname "$LOG")"

PROMPT='Follow-up on the mantle-1↔osmosis-1 IBC Hermes relayer orphan packet recovery (scheduled 2026-04-28, firing 2026-05-28).

Context:
- Relayer is live: Akash DSEQ 26581304 + home docker hot-standby. Repo: https://github.com/deepanshutr/mantle-osmo-hermes-relayer.
- 562 historical packets stuck (mantle 408, osmosis 154) — pre-recovery from props #82/#1010, no public RPC retains tx-index that far back.
- Genesis sync via cosmovisor blocked: v1.0.1 binary panics on InitChain from origin genesis. Needs binary chain v0.3.0 → v1.0.0-RC1 → v1.0.0 → v1.0.1.
- Full plan: /home/deepanshutr/akash-relayer/ARCHIVE_NODE.md
- Lessons: /home/deepanshutr/akash-relayer/deployment-state.json (orphaned_pending_packets_writeoff section)

Tasks for this follow-up:

1. Check current relayer health — read deployment-state.json, hit both metrics endpoints (home http://127.0.0.1:3001/metrics, Akash via the endpoint in state file), count pending packets vs starting (was 408 mantle + 154 osmo).

2. Re-test public RPC archive depth for the 408 mantle orphans — try seq 229672 (was at h=20231160) on rpc.assetmantle.one, polkachu, publicnode, kjnodes. If ANY RPC now returns a tx_search hit AND can serve the block, restart hermes against that RPC and watch the orphans clear. Use the env-var override on the home docker container, then verify backlog decreases.

3. If still no public archive: send deepanshu a Telegram update with three options:
   - (a) writeoff stays — channel quiet, orphans not worth recovering
   - (b) paid archive RPC ~$50-200/mo from Numia/Imperator/Polkachu
   - (c) self-host archive via cosmovisor binary chain (~3 days sync, ~100GB disk)

4. Whatever the outcome, post a summary to Telegram via PYTHONPATH=/home/deepanshutr/autonomy/internal /home/deepanshutr/autonomy/internal/wallet/atomone/.venv/bin/python -c "from notification.telegram import send_alert; send_alert(arg, parse_mode='"'"'HTML'"'"')"

DO NOT spend money on archive RPC without explicit approval. Just present findings.'

{
  echo ""
  echo "============================================================"
  date -u +%FT%TZ
  echo "============================================================"
  cd /home/deepanshutr/akash-relayer
  printf '%s' "$PROMPT" | claude -p --model opus 2>&1
} >> "$LOG" 2>&1

# One-shot semantics: remove the cron line that invoked this script so
# it doesn't re-fire May 28 next year. Keep all other crontab entries.
crontab -l 2>/dev/null \
  | grep -v 'orphan-recovery-followup.sh' \
  | grep -v '1-month orphan-recovery follow-up' \
  | crontab -
