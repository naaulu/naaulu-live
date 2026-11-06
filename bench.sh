#!/bin/bash
# bench.sh — scale test for deploy.sh against a local, rootless SFTP server.
#
# Starts a throwaway sshd (internal-sftp) on 127.0.0.1, generates a fake
# rainfall archive, and runs the REAL deploy.sh against N synthetic customers.
# Five phases cover what production does:
#
#   cold    first delivery: the newest stamp of each duration to every target
#   steady  one tick: a new 5-min frame arrived, one hourly frame changed size
#   noop    nothing changed: the second connection must be skipped entirely
#   debris  stray *.part swept; targets keep everything (we never delete there)
#   optfail an unreachable target: `optional` must not fail the run, a plain
#           spec must
#
# Usage: ./bench.sh [-n targets] [-p parallel] [-k]
#   -n   customers per tier (figures + data each), default 100
#   -p   DEPLOY_PARALLEL, default 16
#   -k   keep $BENCH_DIR for inspection (sshd is always stopped)
#
# Auth: the bench daemon authorizes your real ~/.ssh/*.pub keys (read-only);
# deploy.sh authenticates with them in BatchMode. If the bench added a
# `[127.0.0.1]:<port>` known_hosts line that was not there before, it is
# removed again on exit.

set -uo pipefail

TARGETS=100
PAR=16
KEEP=0
while getopts "n:p:kh" opt; do
    case "$opt" in
        n) TARGETS="$OPTARG" ;;
        p) PAR="$OPTARG" ;;
        k) KEEP=1 ;;
        h) grep '^# ' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "usage: $0 [-n targets] [-p parallel] [-k]" >&2; exit 2 ;;
    esac
done
shift $((OPTIND - 1))

REPO="$(cd "$(dirname "$0")" && pwd)"
DEPLOY="${DEPLOY:-$REPO/deploy.sh}"   # point at another deploy.sh to compare
PORT=2290
B="/tmp/opencode/naaulu-bench"
DEST="$B/dest"
BH="$B/home"                  # HOME seen by deploy.sh (archive lives under it)
LOGS="$B/logs"
SSH_USER="$(id -un)"
FAILURES=0

# Archive depth:
#   pt5m 288 stamps x 5 min = 24 h
#   pt1h 120 stamps         = 5 d
#   p1d   40 stamps         = 40 d
N5M=288
N1H=120
N1D=40
NEW_TICKS=6                     # frames that "arrive" for the steady phase
REWRITES=1                      # existing frame whose size changes

# Newest-stamp staging: one file per duration per tier. A target receives
# 3 png + 3 nc on the first run, then one file per new frame.
EXP_STAGED=3                        # pt5m + pt1h + p1d, per tier
EXP_COLD=$((2 * EXP_STAGED))        # png + nc, per customer
EXP_STEADY=$((2 * (1 + REWRITES)))  # new newest frame + rewritten hourly, both tiers
EXP_REMOTE=$((EXP_STAGED + 1))      # what a target holds after steady: 4
EXP_ARCHIVE=$((N5M + N1H + N1D))    # generated, for the header line only

# Unreachable target for phase 5: nothing listens on port 1.
BAD_TARGET="nodeploy:127.0.0.1::${DEST}/bad:1"

fail() { echo "FAIL: $*"; FAILURES=$((FAILURES + 1)); }
now_ms() { date +%s%3N; }

# --- teardown -------------------------------------------------------------
SSHD_PID=""
KH_HAD_PORT=0
BUILD_MOVED=""
teardown() {
    [ -n "$SSHD_PID" ] && kill "$SSHD_PID" 2>/dev/null
    if [ "$KH_HAD_PORT" -eq 0 ] && [ -f "$HOME/.ssh/known_hosts" ]; then
        local tmp
        tmp=$(mktemp)
        grep -vF "[127.0.0.1]:$PORT " "$HOME/.ssh/known_hosts" > "$tmp" || true
        cat "$tmp" > "$HOME/.ssh/known_hosts"   # keep inode/perms
        rm -f "$tmp"
    fi
    if [ -n "$BUILD_MOVED" ]; then
        rm -rf "$REPO/build"
        mv "$BUILD_MOVED" "$REPO/build"
    fi
    # Anything a deploy left in the account's home directory.
    rm -rf "$HOME/tmp/opencode/naaulu-bench"
    rmdir "$HOME/tmp/opencode" "$HOME/tmp" 2>/dev/null || true
    if [ "$KEEP" = 0 ]; then rm -rf "$B"; else echo "kept: $B"; fi
}
trap teardown EXIT

# --- preflight ------------------------------------------------------------
command -v sshpass >/dev/null 2>&1 || { echo "sshpass is required"; exit 1; }
command -v sftp    >/dev/null 2>&1 || { echo "sftp is required"; exit 1; }
[ -x /usr/sbin/sshd ] || { echo "/usr/sbin/sshd is required"; exit 1; }
[ -f "$DEPLOY" ] || { echo "deploy.sh not found in $REPO"; exit 1; }

shopt -s nullglob
PUBS=( "$HOME"/.ssh/*.pub )
shopt -u nullglob
[ ${#PUBS[@]} -gt 0 ] || { echo "no ~/.ssh/*.pub key found (needed to auth to the bench sshd)"; exit 1; }

grep -qF "[127.0.0.1]:$PORT " "$HOME/.ssh/known_hosts" 2>/dev/null && KH_HAD_PORT=1
if [ -d "$REPO/build" ]; then
    mkdir -p "$B"
    BUILD_MOVED="$B/build.moved"
    mv "$REPO/build" "$BUILD_MOVED"
fi

# Fresh state: leftovers from a failed or -k run are removed.
rm -rf "$DEST" "$LOGS" "$BH/.cache"
mkdir -p "$B/etc" "$BH/.ssh" "$DEST" "$LOGS"

# --- throwaway sshd -------------------------------------------------------
cat "${PUBS[@]}" > "$B/etc/authorized_keys"
chmod 700 "$BH" "$BH/.ssh"
chmod 600 "$B/etc/authorized_keys"
# fresh key each run
rm -f "$B/etc/hostkey" "$B/etc/hostkey.pub"
ssh-keygen -q -t ed25519 -N "" -f "$B/etc/hostkey"
cat > "$B/etc/sshd_config" <<EOF
Port $PORT
HostKey $B/etc/hostkey
PidFile $B/etc/sshd.pid
AuthorizedKeysFile $B/etc/authorized_keys
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
MaxStartups 300:30:300
Subsystem sftp internal-sftp
LogLevel VERBOSE
EOF
/usr/sbin/sshd -f "$B/etc/sshd_config" -E "$B/sshd.log" -D &
SSHD_PID=$!
for _ in $(seq 1 50); do
    ss -ltnH "sport = :$PORT" 2>/dev/null | grep -q . && break
    sleep 0.1
done
if ! ss -ltnH "sport = :$PORT" 2>/dev/null | grep -q .; then
    echo "sshd did not come up on port $PORT:"; tail -5 "$B/sshd.log"; exit 1
fi

# --- fake archive ---------------------------------------------------------
FIG="$BH/.cache/naaulu/archive/figure"
NC="$BH/.cache/naaulu/archive/precip"
mkdir -p "$FIG" "$NC"

for ((i = 0; i < N5M; i++)); do
    ts=$(date -u -d "-$((i * 300)) seconds" +%Y%m%d%H%M%S)
    sz=$((24000 + (i % 977)))
    head -c "$sz" /dev/urandom > "$FIG/${ts}.bel.pt5m.1km.eider.png"
    head -c "$sz" /dev/urandom > "$NC/${ts}.pt5m.1km.eider.nc"
done
for ((i = 0; i < N1H; i++)); do
    ts=$(date -u -d "-$((i * 3600)) seconds" +%Y%m%d%H%M%S)
    sz=$((26000 + (i % 977)))
    head -c "$sz" /dev/urandom > "$FIG/${ts}.bel.pt1h.2km.eider.png"
    head -c "$sz" /dev/urandom > "$NC/${ts}.pt1h.2km.eider.nc"
done
for ((i = 0; i < N1D; i++)); do
    ts=$(date -u -d "-$((i * 86400)) seconds" +%Y%m%d%H%M%S)
    sz=$((28000 + (i % 977)))
    head -c "$sz" /dev/urandom > "$FIG/${ts}.bel.p1d.2km.eider.png"
    head -c "$sz" /dev/urandom > "$NC/${ts}.p1d.2km.eider.nc"
done

# --- target list ----------------------------------------------------------
FIG_TARGETS=""
DATA_TARGETS=""
for ((i = 1; i <= TARGETS; i++)); do
    c=$(printf "%03d" "$i")
    # empty password field => BatchMode key auth; 5th field is the port
    FIG_TARGETS+="${SSH_USER}:127.0.0.1::${DEST}/c${c}/www:${PORT} "
    DATA_TARGETS+="${SSH_USER}:127.0.0.1::${DEST}/c${c}/data:${PORT} "
done

# --- runner ---------------------------------------------------------------
run_deploy() {  # label [extra figure targets appended to SFTP_TARGETS]
    local label="$1" extra="${2:-}" t0 t1 rc sec uploads
    t0=$(now_ms)
    timeout 900 env \
        HOME="$BH" \
        NAAULU_COUNTRY=bel \
        NAAULU_PRODUCT=eider \
        DEPLOY_PARALLEL="$PAR" \
        SFTP_TARGETS="$FIG_TARGETS$extra" \
        SFTP_TARGETS_DATA="$DATA_TARGETS" \
        bash "$DEPLOY" > "$LOGS/$label.log" 2>&1
    rc=$?
    t1=$(now_ms)
    sec=$(awk "BEGIN{printf \"%.1f\", ($t1 - $t0) / 1000}")
    uploads=$(grep -h "^Deployed:" "$LOGS/$label.log" | awk '{s += $2} END {print s + 0}')
    printf "  %-8s %7s s   uploads=%-6s rc=%s\n" "$label" "$sec" "$uploads" "$rc"
    RUN_RC=$rc
    RUN_UPLOADS=$uploads
}

count_ext() { find "$1" -maxdepth 1 -name "*.$2" -type f 2>/dev/null | wc -l; }
parts() { find "$DEST" -name '*.part' -type f 2>/dev/null | wc -l; }
log_has() { grep -qF "$2" "$LOGS/$1.log"; }
log_count() { grep -cF "$2" "$LOGS/$1.log" || true; }

echo "== naaulu-live deploy benchmark =="
echo "targets:   $TARGETS figure + $TARGETS data"
echo "parallel:  DEPLOY_PARALLEL=$PAR"
echo "sshd:      127.0.0.1:$PORT (rootless, internal-sftp)"
echo "archive:   $EXP_ARCHIVE png + $EXP_ARCHIVE nc generated"
echo "staged:    $EXP_STAGED png + $EXP_STAGED nc per target (newest stamp)"
echo ""
echo "phase         time     note"

# --- phase 1: cold --------------------------------------------------------
run_deploy cold
[ "$RUN_RC" -eq 0 ] || fail "cold: rc=$RUN_RC"
[ "$RUN_UPLOADS" -eq $((EXP_COLD * TARGETS)) ] || \
    fail "cold: uploaded $RUN_UPLOADS, expected $((EXP_COLD * TARGETS))"
[ "$(count_ext "$DEST/c001/www" png)" -eq "$EXP_STAGED" ] || \
    fail "cold: c001/www has $(count_ext "$DEST/c001/www" png) png, expected $EXP_STAGED"
lastc=$(printf "%03d" "$TARGETS")
[ "$(count_ext "$DEST/c${lastc}/data" nc)" -eq "$EXP_STAGED" ] || \
    fail "cold: c${lastc}/data has $(count_ext "$DEST/c${lastc}/data" nc) nc, expected $EXP_STAGED"
# staging itself must be newest-only: 448 files sit in the archive, 3 are staged
[ "$(count_ext "$REPO/build/bel" png)" -eq "$EXP_STAGED" ] || \
    fail "cold: staged $(count_ext "$REPO/build/bel" png) png, expected $EXP_STAGED"
log_has cold "Remote path" || fail "cold: remote paths were never created"

# --- phase 2: steady tick -------------------------------------------------
for ((k = 0; k < NEW_TICKS; k++)); do
    ts=$(date -u -d "+$(((k + 1) * 300)) seconds" +%Y%m%d%H%M%S)
    head -c $((24500 + k)) /dev/urandom > "$FIG/${ts}.bel.pt5m.1km.eider.png"
    head -c $((24500 + k)) /dev/urandom > "$NC/${ts}.pt5m.1km.eider.nc"
done
# An existing frame that is still the newest of its duration changes size ->
# exercises the "rm + re-put" branch.
changed=$(find "$FIG" -maxdepth 1 -name '*.pt1h.2km.eider.png' -printf '%f\n' | LC_ALL=C sort | tail -1)
changed_nc="${changed/.bel./.}"
changed_nc="${changed_nc%.png}.nc"
head -c 26001 /dev/urandom > "$FIG/$changed"
head -c 26001 /dev/urandom > "$NC/$changed_nc"

run_deploy steady
[ "$RUN_RC" -eq 0 ] || fail "steady: rc=$RUN_RC"
# only the newest of the six new frames is staged
[ "$RUN_UPLOADS" -eq $((EXP_STEADY * TARGETS)) ] || \
    fail "steady: uploaded $RUN_UPLOADS, expected $((EXP_STEADY * TARGETS))"
[ "$(count_ext "$DEST/c001/www" png)" -eq "$EXP_REMOTE" ] || \
    fail "steady: c001/www holds $(count_ext "$DEST/c001/www" png) png, expected $EXP_REMOTE"

# --- phase 3: noop --------------------------------------------------------
run_deploy noop
[ "$RUN_RC" -eq 0 ] || fail "noop: rc=$RUN_RC"
[ "$RUN_UPLOADS" -eq 0 ] || fail "noop: uploaded $RUN_UPLOADS, expected 0"
[ "$(log_count noop "Nothing to deliver")" -eq $((2 * TARGETS)) ] || \
    fail "noop: 'Nothing to deliver' x$(log_count noop 'Nothing to deliver'), expected x$((2 * TARGETS))"
if grep -q "in single batch" "$LOGS/noop.log"; then
    fail "noop: a batch connection was opened although nothing changed"
fi

# --- phase 4: debris ------------------------------------------------------
# Stray *.part planted on one target; no file is deleted from a target, and
# staging must still be newest-only.
: > "$DEST/c001/www/20260101000000.bel.pt5m.1km.eider.png.part"
: > "$DEST/c001/data/20260101000000.pt5m.1km.eider.nc.part"

run_deploy debris
[ "$RUN_RC" -eq 0 ] || fail "debris: rc=$RUN_RC"
[ "$RUN_UPLOADS" -eq 0 ] || fail "debris: uploaded $RUN_UPLOADS, expected 0"
staged=$(count_ext "$REPO/build/bel" png)
[ "$staged" -eq "$EXP_STAGED" ] || \
    fail "debris: staged $staged png locally, expected $EXP_STAGED (newest stamp only)"
www=$(count_ext "$DEST/c001/www" png)
[ "$www" -eq "$EXP_REMOTE" ] || \
    fail "debris: c001/www holds $www png, expected $EXP_REMOTE (targets are never pruned)"
data=$(count_ext "$DEST/c001/data" nc)
[ "$data" -eq "$EXP_REMOTE" ] || \
    fail "debris: c001/data holds $data nc, expected $EXP_REMOTE"
[ "$(parts)" -eq 0 ] || fail "debris: $(parts) *.part survived, the sweep missed them"
[ "$(log_count debris "Cleanup")" -eq 0 ] || fail "debris: logged a remote cleanup"
# Only the two c001 targets had anything to do (the planted debris); every
# other target must have skipped its second connection.
exp_nothing=$((2 * TARGETS - 2))
[ "$(log_count debris "Nothing to deliver")" -eq "$exp_nothing" ] || \
    fail "debris: 'Nothing to deliver' x$(log_count debris 'Nothing to deliver'), expected x$exp_nothing"

# --- phase 5: optional vs required failure --------------------------------
# An unreachable target marked `optional` must not fail the run; the same
# target without the option must fail it.
run_deploy optfail " $BAD_TARGET:optional"
[ "$RUN_RC" -eq 0 ] || fail "optfail: rc=$RUN_RC, an optional target must not fail the run"
log_has optfail "ERROR: cannot create or read" || fail "optfail: the failure itself was not reported"
log_has optfail "OPTIONAL target failed - ignored, the run continues" || fail "optfail: optional marker missing"
[ "$(log_count optfail "Nothing to deliver")" -eq $((2 * TARGETS)) ] || \
    fail "optfail: $(log_count optfail 'Nothing to deliver') real targets completed, expected $((2 * TARGETS))"

run_deploy reqfail " $BAD_TARGET"
[ "$RUN_RC" -ne 0 ] || fail "reqfail: a plain failing target must fail the run"
log_has reqfail "Some deployments FAILED" || fail "reqfail: failure report missing"

# --- global invariants ----------------------------------------------------
[ "$(parts)" -eq 0 ] || fail "$(parts) *.part files survived on the targets"
# Delivered files must be web-readable: a web server answers 403 for a 600 file.
png_mode=$(stat -c %a "$DEST/c001/www/$(ls "$DEST/c001/www" | grep '\.bel\.pt5m\..*\.png$' | head -1)" 2>/dev/null || echo missing)
[ "$png_mode" = "644" ] || fail "png mode is $png_mode, expected 644"
nc_mode=$(stat -c %a "$DEST/c001/data/$(ls "$DEST/c001/data" | grep '\.pt5m\..*\.nc$' | head -1)" 2>/dev/null || echo missing)
[ "$nc_mode" = "644" ] || fail "nc mode is $nc_mode, expected 644"
for f in "$LOGS"/*.log; do
    # reqfail is phase 5's control: it is SUPPOSED to report a failure.
    if [ "$(basename "$f")" = "reqfail.log" ]; then continue; fi
    grep -q "FAILED:" "$f" && fail "$(basename "$f"): contains FAILED lines"
    grep -q "Some deployments FAILED" "$f" && fail "$(basename "$f"): deploy reported failure"
done
log_has cold "Deploy pool: DEPLOY_PARALLEL=$PAR" || fail "dispatch header missing"

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "assertions: ALL PASSED"
    exit 0
else
    echo "assertions: $FAILURES FAILED"
    echo "--- sshd log tail ---"; tail -10 "$B/sshd.log" 2>/dev/null
    echo "--- cold log tail ---"; tail -20 "$LOGS/cold.log" 2>/dev/null
    KEEP=1   # keep evidence on failure
    exit 1
fi
