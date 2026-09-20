#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

now=$(date -u)

# Floor to nearest 5-minute mark
floor_5min_date="$now"
while [ $(( $(date -u -d "$floor_5min_date" +"%M") % 5 )) -ne 0 ]; do
    floor_5min_date=$(date -u -d "$floor_5min_date - 1 minute")
done
floor_5min=$(date -u -d "$floor_5min_date" +"%Y%m%dT%H%M00")
floor_min=$(date -u -d "$floor_5min_date" +"%M" | sed 's/^0//')
floor_hour=$(date -u -d "$floor_5min_date" +"%H" | sed 's/^0//')

run_naaulu() {
    local name="$1"
    shift
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Starting $name..."
    if naaulu "$@"; then
        echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Completed $name"
    else
        echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] FAILED $name (exit $?)"
        return 1
    fi
}

run_estimate() {
    run_naaulu "estimate" estimate \
        --first "$floor_5min" \
        --country "$NAAULU_COUNTRY" \
        --product "$NAAULU_PRODUCT"
}

run_combine_hourly() {
    run_naaulu "combine-hourly" combine \
        --first "$floor_5min" \
        --country "$NAAULU_COUNTRY" \
        --duration PT1H \
        --resolution "$NAAULU_RESOLUTION_COMBINED" \
        --product "$NAAULU_PRODUCT"
}

run_combine_daily() {
    run_naaulu "combine-daily" combine \
        --first "$floor_5min" \
        --country "$NAAULU_COUNTRY" \
        --duration P1D \
        --resolution "$NAAULU_RESOLUTION_COMBINED" \
        --product "$NAAULU_PRODUCT"
}

run_plot_5min() {
    run_naaulu "plot-5min" plot \
        --first "$floor_5min" \
        --country "$NAAULU_COUNTRY" \
        --duration PT5M \
        --resolution "$NAAULU_RESOLUTION_BASE" \
        --product "$NAAULU_PRODUCT" \
        --clim 0.1 8 \
        --provinces
}

run_plot_hourly() {
    run_naaulu "plot-hourly" plot \
        --first "$floor_5min" \
        --country "$NAAULU_COUNTRY" \
        --duration PT1H \
        --resolution "$NAAULU_RESOLUTION_COMBINED" \
        --product "$NAAULU_PRODUCT" \
        --network "$NAAULU_NETWORK" \
        --clim 1 64 \
        --provinces
}

run_plot_daily() {
    run_naaulu "plot-daily" plot \
        --first "$floor_5min" \
        --country "$NAAULU_COUNTRY" \
        --duration P1D \
        --resolution "$NAAULU_RESOLUTION_COMBINED" \
        --product "$NAAULU_PRODUCT" \
        --network "$NAAULU_NETWORK" \
        --clim 1 128 \
        --provinces
}

run_clean() {
    run_naaulu "clean" clean
}

run_prune_downloads() {
    local download_dir="$HOME/.cache/naaulu/download"
    local minutes="${RETENTION_DOWNLOAD_MINUTES:-15}"

    [ -d "$download_dir" ] || return 0

    local before after
    before=$(find "$download_dir" -type f -mmin "+$minutes" 2>/dev/null | wc -l)
    if [ "$before" -gt 0 ]; then
        find "$download_dir" -type f -mmin "+$minutes" -delete
    fi
    after=$(find "$download_dir" -type f 2>/dev/null | wc -l)
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Pruned downloads older than ${minutes}m: removed $before, $after kept"
}

run_deploy() {
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Starting deploy..."
    if "$SCRIPT_DIR/deploy.sh"; then
        echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Completed deploy"
    else
        echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] FAILED deploy (exit $?)"
        return 1
    fi
}

# No argument: run full pipeline
if [ -z "${1:-}" ]; then
    if [ $(( $(date -u -d "$now" +"%s") - $(date -u -d "$floor_5min_date" +"%s") )) -le 50 ]; then
        echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Waiting for radar data..."
        while [ $(( $(date -u -d "$now" +"%s") - $(date -u -d "$floor_5min_date" +"%s") )) -le 50 ]; do
            sleep 5
            now=$(date -u)
        done
    fi

    run_estimate
    run_plot_5min

    if [ "$floor_min" -eq 0 ]; then
        run_combine_hourly
        run_plot_hourly
    fi

    if [ "$floor_hour" -eq 0 ] && [ "$floor_min" -eq 0 ]; then
        run_combine_daily
        run_plot_daily
    fi

    run_deploy

    run_prune_downloads

    if [ "$floor_hour" -eq 0 ] && [ "$floor_min" -eq 0 ]; then
        run_clean
    fi

    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Pipeline done"
    exit 0
fi

# Single command dispatch
case "$1" in
    estimate)        run_estimate ;;
    combine-hourly)  run_combine_hourly ;;
    combine-daily)   run_combine_daily ;;
    plot-5min)       run_plot_5min ;;
    plot-hourly)     run_plot_hourly ;;
    plot-daily)      run_plot_daily ;;
    clean)           run_clean ;;
    prune-downloads) run_prune_downloads ;;
    *)
        echo "Usage: $0 {estimate|combine-hourly|combine-daily|plot-5min|plot-hourly|plot-daily|clean|prune-downloads}"
        exit 1
        ;;
esac
