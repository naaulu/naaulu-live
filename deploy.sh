#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

CLEANUP_FILES=()
cleanup() { rm -f "${CLEANUP_FILES[@]}"; }
trap cleanup EXIT

ARCHIVE="${HOME}/.cache/naaulu/archive"
BUILD_DIR="${SCRIPT_DIR}/build/${NAAULU_COUNTRY}"
DATA_BUILD_DIR="${SCRIPT_DIR}/build/${NAAULU_COUNTRY}-data"

mkdir -p "$BUILD_DIR" "$DATA_BUILD_DIR"

# Copy only when the staged copy is missing or a different size. Archive files
# are immutable per timestamp, so re-copying the whole retention window
# (~835 files, ~25 MB) every 5 minutes would only be thrown away by the
# size-compare below.
stage_file() {
    local src="$1" dst="$2"
    if [ -f "$dst" ] && [ "$(stat -c%s "$src")" = "$(stat -c%s "$dst")" ]; then
        return 0
    fi
    cp -f "$src" "$dst"
}

# Drop staged files that aged past their window. This replaces the old
# "wipe both build dirs on every run", which forced a full re-copy each time.
prune_staged() {
    local dir="$1" pattern="$2" retention_hours="$3"
    local cutoff
    cutoff=$(date -u -d "$retention_hours hours ago" +"%Y%m%d%H%M%S")

    find "$dir" -name "$pattern" -type f 2>/dev/null | while read -r f; do
        bn=$(basename "$f")
        ts="${bn%%.*}"
        if [[ "$ts" < "$cutoff" ]]; then
            rm -f "$f"
        fi
    done
}

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
            stage_file "$f" "$BUILD_DIR/$bn"
        fi
    done
}

# Same, for the precip NetCDF tiles. These carry no country code in the name,
# so they are matched on duration/resolution/product only.
copy_netcdf() {
    local naaulu_duration="$1"  # pt5m, pt1h, p1d
    local resolution="$2"       # 1km, 2km
    local retention_hours="$3"

    local cutoff
    cutoff=$(date -u -d "$retention_hours hours ago" +"%Y%m%d%H%M%S")

    find "$ARCHIVE/precip" -name "*.${naaulu_duration}.${resolution}.${NAAULU_PRODUCT}.nc" 2>/dev/null | while read -r f; do
        bn=$(basename "$f")
        ts="${bn%%.*}"
        if [[ "$ts" > "$cutoff" ]]; then
            stage_file "$f" "$DATA_BUILD_DIR/$bn"
        fi
    done
}

# Prune the build dirs first, so anything that aged out of the retention window
# is dropped instead of lingering and being re-uploaded after the remote cleanup
# deletes its twin.
for duration_spec in "pt5m:${RETENTION_5MIN_HOURS}" "pt1h:${RETENTION_HOURLY_HOURS}" "p1d:$((RETENTION_DAILY_DAYS * 24))"; do
    IFS=: read -r spec_duration spec_hours <<< "$duration_spec"
    prune_staged "$BUILD_DIR"       "*.${NAAULU_COUNTRY}.${spec_duration}.*" "$spec_hours"
    prune_staged "$DATA_BUILD_DIR"  "*.${spec_duration}.*"                   "$spec_hours"
done

copy_plots "pt5m" "$NAAULU_RESOLUTION_BASE"    "$RETENTION_5MIN_HOURS"
copy_plots "pt1h" "$NAAULU_RESOLUTION_COMBINED" "$RETENTION_HOURLY_HOURS"
copy_plots "p1d"  "$NAAULU_RESOLUTION_COMBINED" "$((RETENTION_DAILY_DAYS * 24))"

copy_netcdf "pt5m" "$NAAULU_RESOLUTION_BASE"    "$RETENTION_5MIN_HOURS"
copy_netcdf "pt1h" "$NAAULU_RESOLUTION_COMBINED" "$RETENTION_HOURLY_HOURS"
copy_netcdf "p1d"  "$NAAULU_RESOLUTION_COMBINED" "$((RETENTION_DAILY_DAYS * 24))"

echo "Build complete. Plot files:"
find "$BUILD_DIR" -type f | head -20
echo "Precip tiles staged: $(find "$DATA_BUILD_DIR" -type f | wc -l)"

deploy_failed=0

# Publish one directory of files to a single SFTP target.
#   $1 target spec      user:host:password:path
#   $2 source directory
#   $3 file extension   png | nc
#   $4 country tag      matched as ".<tag>.<duration>." — pass "" for the precip
#                       tiles, whose names carry no country code
#   $5 emit_json        1 = build and upload <country>.json (viewer index),
#                       0 = files only
sync_target() {
    local target="$1" src_dir="$2" ext="$3" country_tag="$4" emit_json="$5"
    local WEB_USER WEB_HOST WEB_PASS REMOTE_PATH
    IFS=: read -r WEB_USER WEB_HOST WEB_PASS REMOTE_PATH <<< "$target"

    echo ""
    echo "=== Deploying *.${ext} to ${WEB_USER}@${WEB_HOST}:${REMOTE_PATH} ==="

    sftp_cmd() {
        sshpass -p "$WEB_PASS" sftp -o StrictHostKeyChecking=no "${WEB_USER}@${WEB_HOST}"
    }

    # sftp reports path errors on stderr, which a bare `2>/dev/null` swallows.
    listing_broken() {
        echo "$1" | grep -qE "Can't (ls|cd)|not found|No such file|Permission denied|Connection (refused|closed)|Authorization failed|Operation failed"
    }

    # This sftp rejects `mkdir -p` ("Invalid flag -p"), so issue one mkdir per
    # path component. Components that already exist just fail and are ignored.
    mkdir_remote() {
        local path="$1" batch part acc=""
        batch=$(mktemp)
        CLEANUP_FILES+=("$batch")
        : > "$batch"
        while [ -n "$path" ]; do
            part="${path%%/*}"
            if [ "$part" != "$path" ]; then path="${path#*/}"; else path=""; fi
            [ -z "$part" ] && continue
            acc="${acc:+$acc/}$part"
            echo "mkdir $acc" >> "$batch"
        done
        echo "quit" >> "$batch"
        sftp_cmd < "$batch" 2>&1 || true
    }

    # --- Connection 1: Fetch remote file listing ---
    echo "Fetching remote listing..."
    local REMOTE_LISTING LISTING_RAW

    # Guard before anything dials out: with an empty path the batch's `cd` is a
    # no-op, so `put` would silently write into the account's home directory.
    if [ -z "$REMOTE_PATH" ]; then
        echo "ERROR: empty remote path for ${WEB_USER}@${WEB_HOST} - fix the target spec"
        echo "       Nothing was uploaded for this target."
        deploy_failed=1
        return 0
    fi

    LISTING_RAW=$(echo -e "ls -l ${REMOTE_PATH}/\nquit" | sftp_cmd 2>&1 || true)

    # An unreadable path must not be treated as an empty directory: the listing
    # below would come back empty so every file looks "new" (full re-upload each
    # run), cleanup would see nothing to delete, and `cd` in the upload batch
    # would fail while `put` still succeeds — dropping files in the account's
    # home directory instead of the target path.
    if listing_broken "$LISTING_RAW"; then
        echo "Remote path '${REMOTE_PATH}' missing - creating it..."
        mkdir_remote "$REMOTE_PATH"

        LISTING_RAW=$(echo -e "ls -l ${REMOTE_PATH}/\nquit" | sftp_cmd 2>&1 || true)
        if listing_broken "$LISTING_RAW"; then
            echo "ERROR: cannot create or read '${REMOTE_PATH}' for ${WEB_USER}@${WEB_HOST}"
            echo "       Nothing was uploaded for this target. Check permissions or the path."
            echo "$LISTING_RAW" | head -3
            deploy_failed=1
            return 0
        fi
        echo "Created ${REMOTE_PATH}."
    fi

    # Keep only the `ls -l` body: the connect banner and sftp prompts carry no
    # filenames, and leaving them in would confuse the size lookups below.
    # No trailing-space requirement — the mode string may end in + or . (ACLs).
    REMOTE_LISTING=$(echo "$LISTING_RAW" | grep -E "^[-dl][rwx-]{9}" || true)

    # --- Connection 2: Cleanup old files (single batch for all durations) ---
    local CLEANUP_BATCH
    CLEANUP_BATCH=$(mktemp)
    CLEANUP_FILES+=("$CLEANUP_BATCH")
    echo "cd ${REMOTE_PATH}" > "$CLEANUP_BATCH"

    local CLEANUP_COUNT=0
    for duration_spec in "pt5m:${RETENTION_5MIN_HOURS}" "pt1h:${RETENTION_HOURLY_HOURS}" "p1d:$((RETENTION_DAILY_DAYS * 24))"; do
        IFS=: read -r naaulu_duration retention_hours <<< "$duration_spec"
        local cutoff
        cutoff=$(date -u -d "$retention_hours hours ago" +"%Y%m%d%H%M%S")

        # PNGs are namespaced by country, the NetCDF tiles are not
        local needle
        if [ -n "$country_tag" ]; then
            needle=".${country_tag}.${naaulu_duration}."
        else
            needle=".${naaulu_duration}."
        fi

        local tmp_hits
        tmp_hits=$(mktemp)
        echo "$REMOTE_LISTING" | grep -o "[^ ]*\.${ext}" | while read -r f; do
            bn=$(basename "$f")
            if [[ "$bn" == *"$needle"* ]]; then
                ts="${bn%%.*}"
                if [[ "$ts" < "$cutoff" ]]; then
                    echo "rm $bn"
                fi
            fi
        done > "$tmp_hits" || true

        local count
        count=$(wc -l < "$tmp_hits")
        CLEANUP_COUNT=$((CLEANUP_COUNT + count))
        cat "$tmp_hits" >> "$CLEANUP_BATCH"
        rm -f "$tmp_hits"
        echo "Cleanup ${naaulu_duration}: ${count} old files (cutoff=$cutoff)"
    done

    if [ "$CLEANUP_COUNT" -gt 0 ]; then
        echo "Cleaning $CLEANUP_COUNT old files in single batch..."
        echo "quit" >> "$CLEANUP_BATCH"
        sftp_cmd < "$CLEANUP_BATCH" >/dev/null 2>&1 || true
    else
        rm -f "$CLEANUP_BATCH"
        echo "No old files to clean"
    fi

    # --- Connection 3: Upload changed files in single batch (with post-upload listing) ---
    local UPLOAD_BATCH
    UPLOAD_BATCH=$(mktemp)
    CLEANUP_FILES+=("$UPLOAD_BATCH")
    echo "cd ${REMOTE_PATH}" > "$UPLOAD_BATCH"

    local uploaded=0
    local skipped=0
    local upload_files=()

    local src_file bn local_size remote_size
    for src_file in "$src_dir"/*.${ext}; do
        [ -f "$src_file" ] || continue
        bn=$(basename "$src_file")
        local_size=$(stat -c%s "$src_file")

        remote_size=$(echo "$REMOTE_LISTING" | grep "$bn" | awk '{print $5}' | head -1 || true)

        if [ "$local_size" = "$remote_size" ]; then
            skipped=$((skipped + 1))
            continue
        fi

        echo "put ${src_file} ${bn}" >> "$UPLOAD_BATCH"
        upload_files+=("${bn}:${local_size}")
    done

    local failed_files=()
    local upload_output=""

    if [ ${#upload_files[@]} -gt 0 ]; then
        echo "Uploading ${#upload_files[@]} files in single batch..."
        echo "ls -l" >> "$UPLOAD_BATCH"
        echo "quit" >> "$UPLOAD_BATCH"

        upload_output=$(sftp_cmd < "$UPLOAD_BATCH" 2>/dev/null || true)

        # Verify uploads against the post-upload listing
        for entry in "${upload_files[@]}"; do
            IFS=: read -r fname expected_size <<< "$entry"
            actual_size=$(echo "$upload_output" | grep "^-" | grep -F "$fname" | awk '{print $5}' | head -1 || true)
            if [ "$expected_size" = "$actual_size" ]; then
                echo "  OK: $fname ($actual_size bytes)"
                uploaded=$((uploaded + 1))
            else
                echo "  FAILED: $fname (expected=$expected_size actual=${actual_size:-?})"
                failed_files+=("$entry")
            fi
        done

        # Retry failed files (up to 2 more attempts)
        for attempt in 1 2; do
            [ ${#failed_files[@]} -eq 0 ] && break

            local RETRY_BATCH
            RETRY_BATCH=$(mktemp)
            CLEANUP_FILES+=("$RETRY_BATCH")
            echo "cd ${REMOTE_PATH}" > "$RETRY_BATCH"

            local retry_files=()
            for entry in "${failed_files[@]}"; do
                IFS=: read -r fname expected_size <<< "$entry"
                echo "put ${src_dir}/${fname} ${fname}" >> "$RETRY_BATCH"
                retry_files+=("$entry")
            done

            echo "ls -l" >> "$RETRY_BATCH"
            echo "quit" >> "$RETRY_BATCH"

            echo "  Retry $((attempt+1)) for ${#retry_files[@]} failed files..."
            local sftp_output
            sftp_output=$(sftp_cmd < "$RETRY_BATCH" 2>/dev/null || true)

            failed_files=()
            for entry in "${retry_files[@]}"; do
                IFS=: read -r fname expected_size <<< "$entry"
                actual_size=$(echo "$sftp_output" | grep "^-" | grep -F "$fname" | awk '{print $5}' | head -1 || true)
                if [ "$expected_size" = "$actual_size" ]; then
                    echo "  OK: $fname ($actual_size bytes)"
                    uploaded=$((uploaded + 1))
                else
                    echo "  FAILED: $fname after retry (expected=$expected_size actual=${actual_size:-?})"
                    failed_files+=("$entry")
                fi
            done
        done

        [ ${#failed_files[@]} -gt 0 ] && deploy_failed=1
    else
        # Nothing changed: opening a connection just to issue cd+quit would be
        # a pointless round trip. upload_output stays empty, which makes the
        # JSON block re-list the remote below, exactly as before.
        upload_output=""
    fi

    echo "Deployed: $uploaded new, $skipped unchanged"

    # --- Generate and upload the JSON viewer index (figures only) ---
    if [ "$emit_json" != "1" ]; then
        return 0
    fi

    local JSON_FILE="${BUILD_DIR}/${NAAULU_COUNTRY}.json"
    if [ -n "$upload_output" ]; then
        # Use the post-upload listing (includes old + newly uploaded files)
        REMOTE_PNGS=$(echo "$upload_output" | grep "^-" | awk '{print $NF}' | grep "\.${NAAULU_COUNTRY}\." | sort -u || true)
    else
        # No uploads happened, re-list remote to get post-cleanup state
        echo "Re-listing remote for JSON..."
        local POST_CLEANUP_LISTING
        POST_CLEANUP_LISTING=$(echo -e "ls -l ${REMOTE_PATH}/\nquit" | sftp_cmd 2>/dev/null || true)
        REMOTE_PNGS=$(echo "$POST_CLEANUP_LISTING" | grep "^-" | awk '{print $NF}' | grep "\.${NAAULU_COUNTRY}\." | sort -u || true)
    fi

    if [ -n "$REMOTE_PNGS" ]; then
        echo "$REMOTE_PNGS" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip().split('\n')))" > "$JSON_FILE"
    else
        echo '[]' > "$JSON_FILE"
    fi

    echo "JSON generated with $(grep -c '.png' "$JSON_FILE" || echo 0) files"

    # --- Connection 4 (conditional): Upload JSON with verification ---
    local json_size
    json_size=$(stat -c%s "$JSON_FILE")
    local attempt_ok=0
    local attempt JSON_BATCH json_output remote_json_size
    for attempt in 1 2 3; do
        JSON_BATCH=$(mktemp)
        CLEANUP_FILES+=("$JSON_BATCH")
        echo -e "cd ${REMOTE_PATH}\nput ${JSON_FILE} ${NAAULU_COUNTRY}.json\nls -l\nquit" > "$JSON_BATCH"

        json_output=$(sftp_cmd < "$JSON_BATCH" 2>/dev/null || true)

        remote_json_size=$(echo "$json_output" | grep "^-" | grep -F "${NAAULU_COUNTRY}.json" | awk '{print $5}' | head -1 || true)

        if [ "$json_size" = "$remote_json_size" ]; then
            echo "JSON deployed!"
            attempt_ok=1
            break
        fi
        echo "JSON RETRY $attempt (local=$json_size remote=${remote_json_size:-?})"
    done

    if [ "$attempt_ok" -eq 0 ]; then
        echo "JSON deployment FAILED!"
        deploy_failed=1
    fi
}

# Deploy the PNG figures to each SFTP target (uploads the JSON viewer index too)
for target in $SFTP_TARGETS; do
    sync_target "$target" "$BUILD_DIR" "png" "$NAAULU_COUNTRY" 1
done

# Deploy the precip NetCDF tiles to each data target (no JSON index)
if [ -n "$SFTP_TARGETS_DATA" ]; then
    for target in $SFTP_TARGETS_DATA; do
        sync_target "$target" "$DATA_BUILD_DIR" "nc" "" 0
    done
else
    echo ""
    echo "SFTP_TARGETS_DATA not set - skipping precip tiles"
fi

if [ "$deploy_failed" -eq 1 ]; then
    echo "Some deployments FAILED!"
    exit 1
fi
