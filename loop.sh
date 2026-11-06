#!/bin/bash
set -euo pipefail

# Hourly background estimate: one container walks that hour's 12 frames,
# sleeping until each timestamp + 100 s (`estimate --delay`). The every-5-min
# tick (run.sh) waits for the frames this produces.
#
# Container name is naaulu-5min-<HH>; each hour owns its name. The `rm -f`
# below removes yesterday's leftover of the same hour only.

NAAULU_COUNTRY="${NAAULU_COUNTRY:-bel}"
NAAULU_PRODUCT="${NAAULU_PRODUCT:-eider}"
ARCHIVE_VOLUME="${ARCHIVE_VOLUME:-naaulu-archive-bel}"
DATA_VOLUME="${DATA_VOLUME:-naaulu-data-bel}"
IMAGE="${NAAULU_LIVE_IMAGE:-git.naaulu.org/naaulu/naaulu-live:latest}"
LOG="${NAAULU_LIVE_LOG:-$HOME/.local/share/naaulu-live.log}"

HOUR=$(date -u +%H)
DAY=$(date -u +%Y%m%d)
NAME="naaulu-5min-$HOUR"

podman rm -f "$NAME" >/dev/null 2>&1 || true
exec podman run --rm --name "$NAME" --pull=newer \
    -v "$ARCHIVE_VOLUME":/root/.cache/naaulu \
    -v "$DATA_VOLUME":/root/.local/share/naaulu \
    "$IMAGE" \
    naaulu estimate --first "${DAY}${HOUR}0000" --last "${DAY}${HOUR}5500" \
    --country "$NAAULU_COUNTRY" --product "$NAAULU_PRODUCT" \
    --delay 100 --log info >> "$LOG" 2>&1
