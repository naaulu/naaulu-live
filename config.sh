#!/bin/bash
[ -f /opt/naaulu-live/.env ] && set -a && source /opt/naaulu-live/.env && set +a

NAAULU_COUNTRY="${NAAULU_COUNTRY:-est}"
NAAULU_PRODUCT="${NAAULU_PRODUCT:-eider}"
# Space-separated list of gauge network keys for the plot overlay
NAAULU_NETWORK="${NAAULU_NETWORK:-est}"

# Seconds a tick waits for the background estimate's 5-minute frame before
# skipping the plot.
FRAME_WAIT_SECONDS="${FRAME_WAIT_SECONDS:-300}"
NAAULU_RESOLUTION_BASE="1km"
NAAULU_RESOLUTION_COMBINED="2km"

# Required for the deploy-invoking modes (bare run.sh and `run.sh deploy`),
# optional for the compute-only modes.
case "${1:-}" in
    ''|deploy) SFTP_TARGETS="${SFTP_TARGETS:?SFTP_TARGETS is required}" ;;
    *)         SFTP_TARGETS="${SFTP_TARGETS:-}" ;;
esac

# Log level passed to every naaulu CLI call [critical, error, warning, info, debug]
NAAULU_LOG="${NAAULU_LOG:-info}"

# Optional: same user:host:password:path[:port[:options]] format as
# SFTP_TARGETS, but receives the precip NetCDF tiles (archive/precip) instead
# of the PNG figures. Empty = skip. Options: `optional` = a failure here never
# fails the run.
SFTP_TARGETS_DATA="${SFTP_TARGETS_DATA:-}"

# Minutes to keep raw downloaded radar files
export RETENTION_DOWNLOAD_MINUTES=15
