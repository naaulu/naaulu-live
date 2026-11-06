#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Runs before config.sh, which exits when SFTP_TARGETS is missing
if ! command -v sshpass >/dev/null 2>&1; then
    echo "Error: sshpass is required for password authentication."
    echo "Install it with: sudo pacman -S sshpass"
    exit 1
fi

source "$SCRIPT_DIR/config.sh"

CLEANUP_FILES=()
cleanup() {
    [ "${#CLEANUP_FILES[@]}" -gt 0 ] && rm -f "${CLEANUP_FILES[@]}"
    return 0
}
# Installed inside each parallel target subshell. Starts from a cleared list
# and removes only the temp files that job created; the parent's job logs are
# left for the parent to replay.
subshell_cleanup() {
    [ "${#CLEANUP_FILES[@]}" -gt 0 ] && rm -f "${CLEANUP_FILES[@]}"
    return 0
}
trap cleanup EXIT

ARCHIVE="${HOME}/.cache/naaulu/archive"
BUILD_DIR="${SCRIPT_DIR}/build/${NAAULU_COUNTRY}"
DATA_BUILD_DIR="${SCRIPT_DIR}/build/${NAAULU_COUNTRY}-data"

# The publish set for this run: previous contents removed, then the newest
# timestamp staged into it.
rm -rf "$BUILD_DIR" "$DATA_BUILD_DIR"
mkdir -p "$BUILD_DIR" "$DATA_BUILD_DIR"

# Stages the newest timestamp the archive holds for one duration into the
# build directory. Older timestamps are not staged.
stage_newest() {
    local dir="$1" pattern="$2" dst="$3"

    # The archive directory exists only once the first estimate has run.
    [ -d "$dir" ] || return 0

    local newest ts
    # Filenames start with a fixed-width YYYYMMDDHHMMSS stamp; the last line of
    # a C-locale sort is the newest one.
    newest=$(find "$dir" -name "$pattern" -printf '%f\n' 2>/dev/null | LC_ALL=C sort | tail -1)
    [ -n "$newest" ] || return 0
    ts="${newest%%.*}"
    # One stamp covers several area tiles; the pattern is matched as well.
    find "$dir" -name "$pattern" -name "$ts.*" -exec cp -f -t "$dst" {} +
}

stage_newest "$ARCHIVE/figure" "*.${NAAULU_COUNTRY}.pt5m.${NAAULU_RESOLUTION_BASE}.${NAAULU_PRODUCT}.png"      "$BUILD_DIR"
stage_newest "$ARCHIVE/figure" "*.${NAAULU_COUNTRY}.pt1h.${NAAULU_RESOLUTION_COMBINED}.${NAAULU_PRODUCT}.png"  "$BUILD_DIR"
stage_newest "$ARCHIVE/figure" "*.${NAAULU_COUNTRY}.p1d.${NAAULU_RESOLUTION_COMBINED}.${NAAULU_PRODUCT}.png"   "$BUILD_DIR"
stage_newest "$ARCHIVE/precip" "*.pt5m.${NAAULU_RESOLUTION_BASE}.${NAAULU_PRODUCT}.nc"                         "$DATA_BUILD_DIR"
stage_newest "$ARCHIVE/precip" "*.pt1h.${NAAULU_RESOLUTION_COMBINED}.${NAAULU_PRODUCT}.nc"                     "$DATA_BUILD_DIR"
stage_newest "$ARCHIVE/precip" "*.p1d.${NAAULU_RESOLUTION_COMBINED}.${NAAULU_PRODUCT}.nc"                      "$DATA_BUILD_DIR"

echo "Build complete. Plot files:"
# `head -20` closes the pipe early; `|| true` absorbs the resulting SIGPIPE
# (141) under pipefail.
find "$BUILD_DIR" -type f | head -20 || true
echo "Precip tiles staged: $(find "$DATA_BUILD_DIR" -type f | wc -l)"

deploy_failed=0

# Publish one directory of files to a single SFTP target.
#   $1 target spec      user:host:password:path[:port[:options]]
#   $2 source directory
#   $3 file extension   png | nc
#
# Nothing on the target is removed and no index is written — the target's web
# server lists its own directory. Only the newest timestamp is staged locally.
#
# Two connections per target in the common case: one listing, one batch
# carrying the uploads plus a trailing `ls -l` that verifies them. The listing
# is parsed once into a name -> size map. Data uploads as "<name>.part" and is
# renamed into place. Nothing to deliver means no second connection.
sync_target() {
    local target="$1" src_dir="$2" ext="$3"
    local WEB_USER WEB_HOST WEB_PASS REMOTE_PATH WEB_PORT
    # 5th field: port (sftp -P), default 22. 6th field: options — `optional`
    # marks a target whose failure does not fail the run. A bare number in
    # that slot is the retired per-target retention value: parsed, ignored.
    local -a spec=()
    IFS=: read -r -a spec <<< "$target"
    WEB_USER="${spec[0]}" WEB_HOST="${spec[1]}" WEB_PASS="${spec[2]}"
    REMOTE_PATH="${spec[3]}" WEB_PORT="${spec[4]:-22}"

    echo ""
    echo "=== Deploying *.${ext} to ${WEB_USER}@${WEB_HOST}:${REMOTE_PATH} ==="

    # ServerAliveInterval/CountMax: a silent peer is noticed within ~60 s.
    # ConnectTimeout: fails fast while dialling. The outer `timeout` is an
    # absolute ceiling per session.
    local -a sftp_opts=(
        -o StrictHostKeyChecking=no
        -o ServerAliveInterval=15
        -o ServerAliveCountMax=4
        -o ConnectTimeout=30
        -P "$WEB_PORT"
    )
    local sftp_timeout=600

    sftp_cmd() {
        # sshpass -e reads the password from $SSHPASS, never from the command
        # line. An empty password means BatchMode=yes. `timeout` turns a
        # wedged session into exit 124; every call site tolerates failure with
        # `|| true`.
        if [ -n "$WEB_PASS" ]; then
            SSHPASS="$WEB_PASS" timeout "$sftp_timeout" sshpass -e sftp "${sftp_opts[@]}" -o BatchMode=no "${WEB_USER}@${WEB_HOST}"
        else
            echo "WARNING: empty password for ${WEB_USER}@${WEB_HOST} - trying SSH keys"
            timeout "$sftp_timeout" sftp "${sftp_opts[@]}" -o BatchMode=yes "${WEB_USER}@${WEB_HOST}"
        fi
    }

    # sftp reports path errors on stderr; they are captured here with stdout.
    listing_broken() {
        echo "$1" | grep -qE "Can't (ls|cd)|not found|No such file|Permission denied|Connection (refused|closed)|Authorization failed|Operation failed"
    }

    # One `mkdir` per path component; this sftp has no `mkdir -p`. Components
    # that already exist fail and are ignored. A leading "/" is preserved.
    mkdir_remote() {
        local path="$1" batch part acc="" prefix=""
        case "$path" in
            /*) prefix="/"; path="${path#/}" ;;
        esac
        batch=$(mktemp)
        CLEANUP_FILES+=("$batch")
        : > "$batch"
        while [ -n "$path" ]; do
            part="${path%%/*}"
            if [ "$part" != "$path" ]; then path="${path#*/}"; else path=""; fi
            [ -z "$part" ] && continue
            acc="${acc:+$acc/}$part"
            echo "mkdir ${prefix}${acc}" >> "$batch"
        done
        echo "quit" >> "$batch"
        sftp_cmd < "$batch" 2>&1 || true
    }

    # --- Connection 1: Fetch remote file listing ---
    echo "Fetching remote listing..."
    local REMOTE_LISTING LISTING_RAW

    # An empty path: the batch's `cd` is a no-op and `put` writes into the
    # account's home directory.
    if [ -z "$REMOTE_PATH" ]; then
        echo "ERROR: empty remote path for ${WEB_USER}@${WEB_HOST} - fix the target spec"
        echo "       Nothing was uploaded for this target."
        deploy_failed=1
        return 0
    fi

    # `cd` + `ls -l`, never `ls -l <dir>/`: OpenSSH's sftp prefixes path
    # arguments with the directory itself ("www/x.png"), which would put
    # directory-qualified keys into the name -> size map below.
    LISTING_RAW=$(echo -e "cd ${REMOTE_PATH}\nls -l\nquit" | sftp_cmd 2>&1 || true)

    # An unreadable path is not treated as an empty directory.
    if listing_broken "$LISTING_RAW"; then
        echo "Remote path '${REMOTE_PATH}' missing - creating it..."
        mkdir_remote "$REMOTE_PATH"

        LISTING_RAW=$(echo -e "cd ${REMOTE_PATH}\nls -l\nquit" | sftp_cmd 2>&1 || true)
        if listing_broken "$LISTING_RAW"; then
            echo "ERROR: cannot create or read '${REMOTE_PATH}' for ${WEB_USER}@${WEB_HOST}"
            echo "       Nothing was uploaded for this target. Check permissions or the path."
            echo "$LISTING_RAW" | head -3
            deploy_failed=1
            return 0
        fi
        echo "Created ${REMOTE_PATH}."
    fi

    # Only the `ls -l` body: the connect banner and sftp prompts carry no
    # filenames. The mode string may end in + or . (ACLs), so no trailing
    # space is required.
    REMOTE_LISTING=$(echo "$LISTING_RAW" | grep -E "^[-dl][rwx-]{9}" || true)

    # --- Parse the listing ONCE into a name -> size map --------------------
    # One awk pass over the listing. Only regular files can match the upload
    # set; dirs and symlinks never do.
    local -A remote_size=()
    local rsize rname
    while read -r rsize rname; do
        [ -n "$rname" ] || continue
        remote_size["$rname"]="$rsize"
    done < <(printf '%s\n' "$REMOTE_LISTING" | awk '/^-/ {name=$NF; sub(".*/", "", name); print $5, name}')

    # The `rm`s here replace content that is about to be re-uploaded under the
    # same name. Nothing is removed for age.

    # --- Queue changed files: ONE find for all local sizes -----------------
    # One `find -printf` supplies every local size; the comparison is a map
    # lookup.
    local upload_cmds="" queued=0 skipped=0
    local -A pending_size=()            # name -> size expected once delivered
    local -a pending_names=()
    local local_size name
    while read -r local_size name; do
        [ -n "$name" ] || continue
        if [ "${remote_size[$name]-}" = "$local_size" ]; then
            skipped=$((skipped + 1))
            continue
        fi
        if [ -n "${remote_size[$name]+set}" ]; then
            # Same name, different size: the old file is dropped first.
            upload_cmds+="rm $name"$'\n'
        fi
        upload_cmds+="put ${src_dir}/${name} ${name}.part"$'\n'
        upload_cmds+="rename ${name}.part ${name}"$'\n'
        pending_size["$name"]="$local_size"
        pending_names+=("$name")
        queued=$((queued + 1))
    done < <(find "$src_dir" -maxdepth 1 -type f -name "*.${ext}" -printf '%s %f\n')

    # Interrupted-batch debris: "<name>.part" files that never reached a final
    # name. A part whose final name is queued for upload is skipped; delivered
    # files are not touched.
    local part_cmds="" part_n=0 fname
    for fname in "${!remote_size[@]}"; do
        case "$fname" in
            *.${ext}.part) ;;
            *) continue ;;
        esac
        [ -n "${pending_size[${fname%.part}]+set}" ] && continue
        part_cmds+="rm $fname"$'\n'
        part_n=$(( part_n + 1 ))
    done
    [ "$part_n" -gt 0 ] && echo "Sweeping $part_n interrupted upload(s)..."

    # --- One batch: debris sweep, uploads — then a trailing `ls -l` --------
    local batch_needed=0
    [ "$queued" -gt 0 ] && batch_needed=1
    [ "$part_n" -gt 0 ] && batch_needed=1

    local verify_output="" uploaded=0
    if [ "$batch_needed" = "1" ]; then
        local BATCH
        BATCH=$(mktemp)
        CLEANUP_FILES+=("$BATCH")
        {
            echo "cd ${REMOTE_PATH}"
            printf '%s' "$part_cmds"
            printf '%s' "$upload_cmds"
            echo "ls -l"
            echo "quit"
        } > "$BATCH"

        echo "Uploading $queued files in single batch..."
        verify_output=$(sftp_cmd < "$BATCH" 2>/dev/null || true)
    else
        echo "Nothing to deliver: no new files, no stale .part."
    fi

    # The batch's trailing `ls -l`: one pass builds the delivered name -> size
    # map for every command in the batch.
    local -A delivered=()
    local dsize dname
    while read -r dsize dname; do
        [ -n "$dname" ] || continue
        delivered["$dname"]="$dsize"
    done < <(printf '%s\n' "$verify_output" | awk '/^-/ {name=$NF; sub(".*/", "", name); print $5, name}')

    local -a failed_files=()            # "src|dst" pairs awaiting a retry
    for name in "${pending_names[@]}"; do
        if [ "${delivered[$name]-}" = "${pending_size[$name]}" ]; then
            uploaded=$((uploaded + 1))
            echo "  OK: $name (${pending_size[$name]} bytes)"
        else
            failed_files+=("${src_dir}/${name}|${name}")
            echo "  FAILED: $name (expected=${pending_size[$name]} actual=${delivered[$name]:-?})"
        fi
    done

    # Failed files are retried up to 2 more times; each retry costs one extra
    # connection.
    local attempt RETRY_BATCH retry_output entry src dst still_count
    for attempt in 2 3; do
        still_count=${#failed_files[@]}
        [ "$still_count" -eq 0 ] && break

        RETRY_BATCH=$(mktemp)
        CLEANUP_FILES+=("$RETRY_BATCH")
        {
            echo "cd ${REMOTE_PATH}"
            for entry in "${failed_files[@]}"; do
                IFS='|' read -r src dst <<< "$entry"
                # `rm` of an absent file logs to stderr; a failed command does
                # not abort an sftp batch.
                echo "rm $dst"
                echo "put ${src} ${dst}.part"
                echo "rename ${dst}.part ${dst}"
            done
            echo "ls -l"
            echo "quit"
        } > "$RETRY_BATCH"

        echo "  Retry $attempt for $still_count failed item(s)..."
        retry_output=$(sftp_cmd < "$RETRY_BATCH" 2>/dev/null || true)

        delivered=()
        while read -r dsize dname; do
            [ -n "$dname" ] || continue
            delivered["$dname"]="$dsize"
        done < <(printf '%s\n' "$retry_output" | awk '/^-/ {name=$NF; sub(".*/", "", name); print $5, name}')

        local -a still_failed=()
        for entry in "${failed_files[@]}"; do
            dst="${entry##*|}"
            if [ "${delivered[$dst]-}" = "${pending_size[$dst]}" ]; then
                uploaded=$((uploaded + 1))
                echo "  OK: $dst (after retry)"
            else
                still_failed+=("$entry")
                echo "  FAILED: $dst after retry (expected=${pending_size[$dst]} actual=${delivered[$dst]:-?})"
            fi
        done
        failed_files=("${still_failed[@]}")
    done

    [ ${#failed_files[@]} -gt 0 ] && deploy_failed=1

    echo "Deployed: $uploaded new, $skipped unchanged"
    return 0
}

# --- Dispatch -------------------------------------------------------------
# Targets run in parallel, capped by DEPLOY_PARALLEL (default 16). Each target
# writes its own transcript, replayed as soon as it finishes (completion order).
# A failed target exits its subshell non-zero; `wait -n -p` collects that status.
DEPLOY_PARALLEL="${DEPLOY_PARALLEL:-16}"
case "$DEPLOY_PARALLEL" in
    ''|*[!0-9]*)
        echo "WARNING: bad DEPLOY_PARALLEL '$DEPLOY_PARALLEL', using 16" >&2
        DEPLOY_PARALLEL=16 ;;
esac
echo "Deploy pool: DEPLOY_PARALLEL=$DEPLOY_PARALLEL"

any_failed=0
running=0
declare -A pid_log=()

reap_one() {
    # Wait for the next target to finish and replay its transcript.
    local p rc=0
    wait -n -p p || rc=$?
    if [ "$rc" -eq 127 ] || [ -z "${p:-}" ]; then
        running=0
        return 1
    fi
    running=$(( running - 1 ))
    if [ "$rc" -ne 0 ]; then
        any_failed=1
    fi
    if [ -n "${pid_log[$p]-}" ]; then
        cat "${pid_log[$p]}" 2>/dev/null || true
        unset "pid_log[$p]"
    fi
    return 0
}

# A target whose spec carries `optional` in the 6th field: its failure is
# written to its transcript and does not fail the run.
target_is_optional() {
    local -a f=()
    IFS=: read -r -a f <<< "$1"
    if [ "${#f[@]}" -le 5 ]; then return 1; fi
    case ",${f[5]}," in
        *,optional,*) return 0 ;;
    esac
    return 1
}

submit_target() {
    local target="$1" src_dir="$2" ext="$3"
    local log rc=0
    log=$(mktemp)
    CLEANUP_FILES+=("$log")
    (
        # Replaces the parent's trap inside the subshell: removes only the
        # temp files this job creates.
        CLEANUP_FILES=()
        trap subshell_cleanup EXIT
        deploy_failed=0
        sync_target "$target" "$src_dir" "$ext" >"$log" 2>&1 || rc=$?
        if target_is_optional "$target" && { [ "$deploy_failed" -ne 0 ] || [ "$rc" -ne 0 ]; }; then
            echo "OPTIONAL target failed - ignored, the run continues" >> "$log"
            rc=0
        elif [ "$deploy_failed" -ne 0 ]; then
            rc=1
        fi
        exit "$rc"
    ) &
    pid_log[$!]="$log"
    running=$(( running + 1 ))
    while [ "$running" -ge "$DEPLOY_PARALLEL" ]; do
        reap_one || true
    done
}

# Reports targets whose 6th field is the retired retention value: once per
# run, not once per target. A spec whose 6th field is `optional` is not
# reported.
legacy_retention_notice() {
    local t n=0
    local -a f=()
    for t in $1; do
        f=()
        IFS=: read -r -a f <<< "$t"
        if [ "${#f[@]}" -gt 5 ]; then
            case ",${f[5]}," in
                *,optional,*) ;;
                *) n=$(( n + 1 )) ;;
            esac
        fi
    done
    if [ "$n" -gt 0 ]; then
        echo "NOTE: $n target(s) carry a legacy retention field - ignored (targets are never pruned)"
    fi
    return 0
}
legacy_retention_notice "$SFTP_TARGETS"
legacy_retention_notice "$SFTP_TARGETS_DATA"

# Deploy the PNG figures to each SFTP target
for target in $SFTP_TARGETS; do
    submit_target "$target" "$BUILD_DIR" "png"
done

# Deploy the precip NetCDF tiles to each data target
if [ -n "$SFTP_TARGETS_DATA" ]; then
    for target in $SFTP_TARGETS_DATA; do
        submit_target "$target" "$DATA_BUILD_DIR" "nc"
    done
else
    echo ""
    echo "SFTP_TARGETS_DATA not set - skipping precip tiles"
fi

# Reap whatever is still in flight
while [ "$running" -gt 0 ]; do
    reap_one || break
done

if [ "$any_failed" -eq 1 ]; then
    echo "Some deployments FAILED!"
    exit 1
fi
