# Naaulu Live

Real-time rainfall estimation pipeline for countries. Runs in a Podman container, generates 5-minute, hourly, and daily rainfall plots, and deploys them to a web server.

## Architecture

```
Host cron → hourly background container (one per hour, 12 frames each)
  └── estimate  (hourly) → 5-min rainfall; naaulu waits T+100 s per frame
Host cron → podman run (ephemeral */5 min container, waits for the frame)
  ├── combine   (hourly/daily) → hourly/daily accumulations
  ├── plot      (after the frame arrives + hourly/daily) → PNG maps
  └── deploy    (every run) → SFTP figures + JSON index  → SFTP_TARGETS
                           → SFTP NetCDF tiles (opt.)    → SFTP_TARGETS_DATA
```

## Prerequisites

- A Debian 13 (Trixie) server
- SFTP credentials for the hosting server

## Install

```bash
sudo apt update
sudo apt install -y podman
sudo loginctl enable-linger $(whoami)
mkdir -p ~/.local/share
podman volume create naaulu-archive-bel
podman volume create naaulu-data-bel
podman pull git.naaulu.org/naaulu/naaulu-live:latest
```

> **Note:** `latest` is built for linux/amd64.

> **Note:** `loginctl enable-linger` is required so Podman can access the container runtime directory from cron jobs. Without it, cron runs without your user session and the storage paths are not available.

> **Note:** `~/.local/share` holds the cron log. Without it the redirect fails and the pipeline never runs.

### Testing image (`next`)

Pushes to the `next` branch build `git.naaulu.org/naaulu/naaulu-live:next` instead of `:latest`, so you can try unreleased changes without touching production. It tracks the same branch upstream: the build passes `NAAULU_BRANCH=next`, so the image clones `naaulu`'s `next` branch too:

```bash
podman pull git.naaulu.org/naaulu/naaulu-live:next
```

Run it exactly like the commands below, but with the `:next` tag. To publish, merge `next` into `main` in both `naaulu` and `naaulu-live`, which rebuilds `:latest`.

### Baked boundary data

Province lines and city labels come from a cached OpenStreetMap extract
(fetched through Geofabrik Postpass). Because the pipeline is time critical,
that cache is **prefetched at image build time** and never fetched at run
time:

- `--build-arg NAAULU_BOUNDARIES=EST,BEL` selects the countries (comma-
  separated ISO3 codes). **The default is every European country naaulu
  supports (46)**: ≈ 460 MB unpacked in the image, ~133 MB extra per pull
  (compressed), and ~15 minutes of Postpass queries at build time. Narrow
  it in CI if that trade-off is wrong for a slimmer image.
- The build runs `prefetch_boundaries.py` and **fails loudly** if a tier
  cannot be filled — a broken build beats a plot that stalls on its first
  run.
- The pristine copy sits at `/opt/naaulu-boundaries`, deliberately *outside*
  `/root/.local/share/naaulu`, because the declared volume would shadow
  image content at that path.
- On every container start `entrypoint.sh` seeds
  `/root/.local/share/naaulu/boundaries` from that copy with `cp -u`:
  a metadata-only no-op when the volume already matches the image, an
  upgrade when a new image bakes fresh data, and never a downgrade of
  fresher files. This is also what keeps **pre-existing** `naaulu-data-*`
  volumes working across image updates.
- Runtime therefore reads from disk. Should a tier ever still be missing
  (country added to `NAAULU_COUNTRY` without a rebuild, deleted file),
  naaulu fills it on demand once — or, with `NAAULU_BOUNDARIES_OFFLINE=1`
  exported, draws the gap instead of ever touching the network.
- `run.sh prefetch-boundaries` warms a country manually at any time.

## Run

Test a one-off run:

```bash
podman run --rm \
  -v naaulu-archive-bel:/root/.cache/naaulu \
  -v naaulu-data-bel:/root/.local/share/naaulu \
  -e SFTP_TARGETS="<sftp-username>:<sftp-host>:<sftp-password>:<remote-path>" \
  -e NAAULU_COUNTRY=bel \
  -e NAAULU_NETWORK="bel bel_spw bel_vmm" \
  -e KNMI_API_KEY="<key>" \
  git.naaulu.org/naaulu/naaulu-live:latest /opt/naaulu-live/run.sh
```

Add a cron job (`crontab -e`):

```cron
# background estimate: hourly, one container, 12 frames, each waits T+100 s
0 * * * * "$HOME/naaulu-live-loop.sh"
*/5 * * * * timeout --kill-after=30 20m podman run --rm --pull=newer -v naaulu-archive-bel:/root/.cache/naaulu -v naaulu-data-bel:/root/.local/share/naaulu -e SFTP_TARGETS="<sftp-username>:<sftp-host>:<sftp-password>:<remote-path>" -e NAAULU_COUNTRY=bel -e NAAULU_NETWORK="bel bel_spw bel_vmm" git.naaulu.org/naaulu/naaulu-live:latest /opt/naaulu-live/run.sh >> ~/.local/share/naaulu-live.log 2>&1
```

> **Install once:** the hourly loop lives in `loop.sh` — `install -m 755 loop.sh "$HOME/naaulu-live-loop.sh"`. It holds the container name, volumes and flags; `NAAULU_COUNTRY`, `NAAULU_LIVE_LOG` and friends can be overridden in the cron line's environment. The `--delay 100` it passes is deliberate: an image that predates the flag refuses to start instead of computing frames before the radar volume exists.

> **Note:** The tick container is deliberately left **unnamed** — do not add `--name` back. A fixed name silently serialized runs: a run waits up to `FRAME_WAIT_SECONDS` (300 s) for the background frame before plotting, so it can creep past the 5-minute tick — the next one would find the name taken and exit without running anything. (The background loop is deliberately named, one container per hour `naaulu-5min-<HH>`: each computes its own hour's frames and exits; its cron line's `rm -f` only ever removes yesterday's leftover of the same hour.) Every other tick was dropped — and because `run.sh` only computes its own `--first`, a dropped tick is a permanently missing 5-minute frame, not a delayed one. Unnamed, a slow run simply overlaps the next; `podman ps` briefly showing two containers after a tick is expected and harmless, since the runs are phase-shifted and radar files are timestep-namespaced.

> **Note:** The `timeout` wrapper is load-bearing, not decoration. `ssh` sends no keepalives by default, so a silent SFTP peer leaves the container blocked in `read()` forever, and `--rm` only cleans up on exit. Runs no longer block each other, so a hung container is not an outage — it accumulates one per tick, each holding SFTP connections, until this cap reaps it. `deploy.sh` sets `ServerAliveInterval`/`ConnectTimeout` per session; this is the outer backstop.

### Housekeeping

Two daily jobs keep the host healthy. Add them alongside the cron line above:

```cron
7  4 * * * : > "$HOME/.local/share/naaulu-live.log"
17 4 * * * podman image prune -f && podman container prune -f
```

- **Log** — the cron line appends forever, so truncate daily to retain the last 24 h. Truncate rather than rename: the container holds the log open with `>>`, and an `O_APPEND` fd keeps writing to the same inode after `: >`, so a run in flight needs no guard. Renaming would strand its output on an orphaned file.
- **Containers** — the hourly loop containers exit by themselves after their last frame and are recycled by name each hour; `container prune -f` sweeps the leftovers daily (it removes only STOPPED containers, so the hour currently being computed is never touched).
- **Images** — `--pull=newer` fetches a new `:latest` on every CI push, which moves the tag and leaves the previous image as `<none>`. CI passes `CACHEBUST=$(date +%s)`, so every build is a fresh ~1 GB image that never stops accumulating (≈25 GB after four weeks). `prune -f` drops only untagged, unreferenced images: never your tagged `:latest`, never anything a container is using.

## Configuration

| Variable | Default | Description |
|---|---|---|
| `NAAULU_COUNTRY` | `est` | Country code |
| `NAAULU_NETWORK` | `est` | Gauge network(s) for plot overlay, space-separated (e.g. `bel bel_spw bel_vmm`) |
| `NAAULU_PRODUCT` | `dove` | Estimation method |
| `NAAULU_RESOLUTION_BASE` | `1km` | 5-min resolution |
| `NAAULU_RESOLUTION_COMBINED` | `2km` | Hourly/daily resolution |
| `FRAME_WAIT_SECONDS` | `300` | Seconds a tick waits for the background estimate's 5-minute frame before skipping the plot (the radar delay itself is naaulu's `estimate --delay`, default 100 s) |
| `KNMI_API_KEY` | (empty) | KNMI Open Data API key for the `nld` gauges; empty = the shared anonymous key |
| `SFTP_TARGETS` | (required) | SFTP targets as `user:host:password:path[:port[:retention_files]]` (space-separated for multiple; port defaults to 22, retention to `RETENTION_FILES`) |
| `SFTP_TARGETS_DATA` | (empty) | Like `SFTP_TARGETS`, but receives the NetCDF tiles. Empty = skip. See [Precip data deploy](#precip-data-deploy-netcdf) |
| `RETENTION_FILES` | `36` | Files to keep **per duration** when staging and delivering: the last 36 five-minute files (3 h), the last 36 hourly files (36 h) and the last 36 daily files (36 d). Per-target override = 6th target field (e.g. 7 days of 5-minute files: `…:22:2016`) |
| `RETENTION_DOWNLOAD_MINUTES` | `15` | Minutes to keep raw downloaded radar files |

> **Note:** `RETENTION_*` values live in `config.sh` (assigned after it sources `.env`), so `.env` cannot override them.

## Precip data deploy (NetCDF)

Every run stages the gridded precipitation tiles (NetCDF) held in `archive/precip` and, if `SFTP_TARGETS_DATA` is set, publishes them to their own SFTP targets. **Off by default** — existing deployments are unaffected until you set the variable.

### Enabling it

Add `-e SFTP_TARGETS_DATA="<sftp-username>:<sftp-host>:<sftp-password>:<data-remote-path>[:<port>]"` to the `podman run` command and cron line above. Same `user:host:password:path[:port[:retention_files]]` format as `SFTP_TARGETS` (empty password = SSH keys, port defaults to 22, retention to `RETENTION_FILES`), space-separated for multiple targets.

The two deploys are independent: leaving `SFTP_TARGETS_DATA` unset skips only the data half.

### What gets uploaded

Everything under `$HOME/.cache/naaulu/archive/precip` matching `*.<duration>.<resolution>.<product>.nc` inside the retention window:

```
20260923160500.E004_E005.N052_N053.pt5m.1km.eider.nc
└── time ─────┘ └── lon ──┘ └── lat ──┘ └dur┘ └res┘ └─ product
```

- **Flat layout** — tiles land directly in `<data-remote-path>`, no subdirectories.
- **Retention** reuses the `RETENTION_*` values: `pt5m` → 2 h, `pt1h` → 20 h, `p1d` → 20 d. Tiles past their window are deleted from the remote on every run.
- **Incremental uploads** — files are size-compared against the remote listing, so only new or changed tiles transfer (~20 per run). The first run backfills the whole window.
- **No JSON index** — unlike the figure target, nothing writes `<country>.json`; consumers list the directory directly.

### Caveats

- A missing remote path is created automatically, one level at a time; if that fails the target aborts without uploading.
- Remote cleanup only touches `.nc` files matching a known duration (`pt5m`, `pt1h`, `p1d`), so unrelated files are left alone.

## Troubleshooting

```bash
tail -50 ~/.local/share/naaulu-live.log
```

**No log file?** `~/.local/share` is missing — `mkdir -p ~/.local/share`.

Deploy lines to look for:

| Message | Meaning |
|---|---|
| `SFTP_TARGETS_DATA not set - skipping precip tiles` | data deploy disabled — expected until you set the variable |
| `Precip tiles staged: N` | tiles found within the retention window, before upload |
| `Deployed: N new, M unchanged` | `N` transferred, `M` already matched the remote |
| `Cleanup <duration>: N old files` | remote tiles past retention, removed this run |
| `Some deployments FAILED!` | size mismatch after retries — check the `FAILED:` lines above |

Other symptoms:

- **Figures arriving every 10 minutes instead of every 5** — `grep "Pipeline done" <log>` and check the gaps: ~600 s means a run is overrunning the 5-minute tick. Look at the phase timings above it — the wait for the background frame (`FRAME_WAIT_SECONDS`) plus plot/deploy dominate the budget.
- **Log full of "WARNING: no 5-min frame"** — the background loop isn't producing: `podman ps | grep naaulu-5min` (nothing running = the cron line or `loop.sh` is gone; also grep the log for `unrecognized arguments` — an image older than `estimate --delay` refuses to start). The tick keeps deploying whatever the archive still holds while it waits.
- **A container still running hours later** — overlap of a second or two right after a tick is normal; still up *hours* later means a wedged transfer. `podman top <id>` to confirm, then `podman rm -f <id>`. The 20 m `timeout` should have reaped it first, so check the cron line still has it.
- **Log filling the disk, or `/` filling up** — covered by the two daily jobs in [Housekeeping](#housekeeping); `podman system df` reports how much image space is reclaimable.

## Data sources

The figures and tiles published here are derived works: radar from EUMETNET
OPERA, FMI, NOAA and the Bureau of Meteorology, rain gauges from the national
services, boundaries from OpenStreetMap (© OpenStreetMap contributors, ODbL,
fetched through Geofabrik Postpass into a local cache) and Natural Earth.
Keep the
attribution when republishing them — the per-provider licences are listed in
[the naaulu documentation](https://git.naaulu.org/naaulu/naaulu/-/blob/main/docs/data-sources.md).

## License

This project is licensed under the GNU Affero General Public License v3.0 (AGPL-3.0).
