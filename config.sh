#!/bin/bash
[ -f /opt/naaulu-live/.env ] && set -a && source /opt/naaulu-live/.env && set +a

NAAULU_COUNTRY="${NAAULU_COUNTRY:-est}"
NAAULU_PRODUCT="${NAAULU_PRODUCT:-eider}"
# Space-separated list of gauge network keys for the plot overlay
NAAULU_NETWORK="${NAAULU_NETWORK:-est}"

# Seconds a tick waits for the background estimate's 5-minute frame before
# skipping the plot. The radar delay itself lives in naaulu's
# `estimate --delay` (default 100 s), not here.
FRAME_WAIT_SECONDS="${FRAME_WAIT_SECONDS:-300}"
NAAULU_RESOLUTION_BASE="1km"
NAAULU_RESOLUTION_COMBINED="2km"

SFTP_TARGETS="${SFTP_TARGETS:?SFTP_TARGETS is required}"

# Log level passed to every naaulu CLI call [critical, error, warning, info, debug]
NAAULU_LOG="${NAAULU_LOG:-info}"

# Optional: same user:host:password:path[:port[:retention_files]] format as
# SFTP_TARGETS, but receives the precip NetCDF tiles (archive/precip) instead
# of the PNG figures. Empty = skip.
SFTP_TARGETS_DATA="${SFTP_TARGETS_DATA:-}"

# ONE retention number: how many FILES to keep per duration when staging and
# delivering — the last 36 five-minute files (3 h), the last 36 hourly files
# (36 h) and the last 36 daily files (36 d). Per-target override: 6th field
# of the target spec, e.g. 7 days of 5-minute files: user:host:pass:path:22:2016
export RETENTION_FILES="${RETENTION_FILES:-36}"

# Raw radar files are only needed briefly after download
export RETENTION_DOWNLOAD_MINUTES=15
