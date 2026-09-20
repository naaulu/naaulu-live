#!/bin/bash
[ -f /opt/naaulu-live/.env ] && set -a && source /opt/naaulu-live/.env && set +a

NAAULU_COUNTRY="${NAAULU_COUNTRY:-est}"
NAAULU_PRODUCT="${NAAULU_PRODUCT:-dove}"
NAAULU_NETWORK="${NAAULU_NETWORK:-est}"
NAAULU_RESOLUTION_BASE="1km"
NAAULU_RESOLUTION_COMBINED="2km"

SFTP_TARGETS="${SFTP_TARGETS:?SFTP_TARGETS is required}"

# Optional: same user:host:password:path format as SFTP_TARGETS, but receives the
# precip NetCDF tiles (archive/precip) instead of the PNG figures. Empty = skip.
SFTP_TARGETS_DATA="${SFTP_TARGETS_DATA:-}"

export RETENTION_5MIN_HOURS=2
export RETENTION_HOURLY_HOURS=20
export RETENTION_DAILY_DAYS=20

# Raw radar files are only needed briefly after download
export RETENTION_DOWNLOAD_MINUTES=15
