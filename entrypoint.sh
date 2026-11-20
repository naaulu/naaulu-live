#!/bin/bash
set -euo pipefail

# Seeds the boundary cache from the image's baked copy before anything runs.
# Runs on every container start; `cp -a -u` is a no-op when the volume already
# matches the image and keeps files written by an on-demand fetch. Best-effort:
# a read-only volume does not take the container down.
if [ -d /opt/naaulu-boundaries ] && [ -n "$(ls -A /opt/naaulu-boundaries 2>/dev/null)" ]; then
    { mkdir -p /root/.local/share/naaulu/boundaries \
      && cp -a -u /opt/naaulu-boundaries/. /root/.local/share/naaulu/boundaries/; } \
        || echo "naaulu-live: boundary seed skipped" >&2
fi

exec "$@"
