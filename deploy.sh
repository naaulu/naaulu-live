#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

CLEANUP_FILES=()
cleanup() { rm -f "${CLEANUP_FILES[@]}"; }
trap cleanup EXIT

ARCHIVE="${HOME}/.cache/naaulu/archive"
BUILD_DIR="${SCRIPT_DIR}/build"
WEB_USER="${WEB_USER}"
WEB_HOST="${WEB_HOST}"
REMOTE_DIR="${REMOTE_DIR}"

mkdir -p "$BUILD_DIR/live"
rm -f "$BUILD_DIR/live/"*

# Copy plot files from archive to build dir (within retention window)
copy_plots() {
    local naaulu_duration="$1"  # pt5m, pt1h, p1d
    local resolution="$2"       # 1km, 2km
    local retention_hours="$3"

    local cutoff
    cutoff=$(date -u -d "$retention_hours hours ago" +"%Y%m%d%H%M%S")

    find "$ARCHIVE/figure" -name "*.${NAAULU_COUNTRY}.${naaulu_duration}.${resolution}.${NAAULU_PRODUCT}.png" 2>/dev/null | while read -r f; do
        bn=$(basename "$f")
        ts="${bn%%.*}"
        if [[ "$ts" > "$cutoff" ]]; then
            cp -f "$f" "$BUILD_DIR/live/$bn"
        fi
    done
}

copy_plots "pt5m" "$NAAULU_RESOLUTION_BASE"    "$RETENTION_5MIN_HOURS"
copy_plots "pt1h" "$NAAULU_RESOLUTION_COMBINED" "$((RETENTION_HOURLY_DAYS * 24))"
copy_plots "p1d"  "$NAAULU_RESOLUTION_COMBINED" "$((RETENTION_DAILY_DAYS * 24))"

# Generate country-specific JSON file
pngs=$(find "$BUILD_DIR/live" -maxdepth 1 -name '*.png' -printf '%f\n' 2>/dev/null | sort)
if [ -n "$pngs" ]; then
    echo "$pngs" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip().split('\n')))" \
        > "$BUILD_DIR/live/${NAAULU_COUNTRY}.json"
else
    echo '[]' > "$BUILD_DIR/live/${NAAULU_COUNTRY}.json"
fi

echo "Build complete. Files:"
find "$BUILD_DIR" -type f | head -20

# Cleanup old files on remote (all PNGs in one directory)
cleanup_remote() {
    local naaulu_duration="$1"  # pt5m, pt1h, p1d
    local retention_hours="$2"
    local cutoff
    cutoff=$(date -u -d "$retention_hours hours ago" +"%Y%m%d%H%M%S")

    local raw_output
    raw_output=$(echo -e "ls -1 ${REMOTE_DIR}/live/\nquit" | sshpass -p "$WEB_PASS" sftp -o StrictHostKeyChecking=no "${WEB_USER}@${WEB_HOST}" 2>/dev/null || true)

    echo "Cleanup ${naaulu_duration}: got $(echo "$raw_output" | wc -l) lines, cutoff=$cutoff"

    local file_list
    file_list=$(echo "$raw_output" | grep -o '[^ ]*\.png' || true)

    if [ -z "$file_list" ]; then
        echo "No PNG files found on remote"
        return
    fi

    local to_delete=""
    while read -r f; do
        local bn
        bn=$(basename "$f")
        if [[ "$bn" == *".${NAAULU_COUNTRY}.${naaulu_duration}."* ]]; then
            local ts="${bn%%.*}"
            if [[ "$ts" < "$cutoff" ]]; then
                to_delete="${to_delete}${bn}\n"
            fi
        fi
    done <<< "$file_list"

    if [ -z "$to_delete" ]; then
        echo "No old ${naaulu_duration} files to clean"
        return
    fi

    local rm_batch
    rm_batch=$(mktemp)
    CLEANUP_FILES+=("$rm_batch")
    echo "cd ${REMOTE_DIR}/live" > "$rm_batch"
    echo -e "$to_delete" | while read -r f; do
        if [ -n "$f" ]; then echo "rm $f" >> "$rm_batch"; fi
    done
    echo "quit" >> "$rm_batch"

    local cmd_count
    cmd_count=$(grep -c "^rm " "$rm_batch" || true)
    if [ "$cmd_count" -gt 0 ]; then
        echo "Cleaning $cmd_count old files..."
        sshpass -p "$WEB_PASS" sftp -o StrictHostKeyChecking=no -oBatchMode=no -b "$rm_batch" "${WEB_USER}@${WEB_HOST}" || true
    fi
}

cleanup_remote "pt5m" "$RETENTION_5MIN_HOURS"
cleanup_remote "pt1h" "$((RETENTION_HOURLY_DAYS * 24))"
cleanup_remote "p1d"  "$((RETENTION_DAILY_DAYS * 24))"

# Deploy via SFTP
BATCH_FILE=$(mktemp)
CLEANUP_FILES+=("$BATCH_FILE")
cat <<EOF > "$BATCH_FILE"
cd ${REMOTE_DIR}/live
mput ${BUILD_DIR}/live/*.png
put ${BUILD_DIR}/live/${NAAULU_COUNTRY}.json ${NAAULU_COUNTRY}.json
quit
EOF

echo "Deploying to ${WEB_USER}@${WEB_HOST}..."
if sshpass -p "$WEB_PASS" sftp -o StrictHostKeyChecking=no -oBatchMode=no -b "$BATCH_FILE" "${WEB_USER}@${WEB_HOST}"; then
    echo "Deployment complete!"
else
    echo "Deployment FAILED!"
    exit 1
fi
