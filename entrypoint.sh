#!/bin/bash
set -euo pipefail

# Seed the boundary cache from the image's baked copy before anything runs.
# Runs on every (ephemeral) container start: -u makes it a metadata-only
# no-op when the volume already matches the image, upgrades the volume when
# a new image bakes fresh data, and keeps even fresher files (written by an
# on-demand fetch) instead of downgrading them. Seeding is best-effort — a
# read-only volume must not take the container down; plots then fall back
# to whatever the cache holds or draw gaps.
if [ -d /opt/naaulu-boundaries ] && [ -n "$(ls -A /opt/naaulu-boundaries 2>/dev/null)" ]; then
    { mkdir -p /root/.local/share/naaulu/boundaries \
      && cp -a -u /opt/naaulu-boundaries/. /root/.local/share/naaulu/boundaries/; } \
        || echo "naaulu-live: boundary seed skipped" >&2
fi

exec "$@"
