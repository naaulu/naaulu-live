# Naaulu Live

Real-time rainfall estimation pipeline for countries. Runs in a Podman container, generates 5-minute, hourly, and daily rainfall plots, and deploys them to a web server.

## Architecture

```
Host cron → hourly background container (one per hour, 12 frames each)
  └── estimate  (hourly) → 5-min rainfall; naaulu waits T+100 s per frame
Host cron → podman run (ephemeral */5 min container, waits for the frame)
  ├── combine   (hourly/daily) → hourly/daily accumulations
  ├── plot      (after the frame arrives + hourly/daily) → PNG maps
  └── deploy    (every run) → SFTP figures               → SFTP_TARGETS
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

> **Note:** `loginctl enable-linger` gives cron jobs access to the container runtime directory.

> **Note:** `~/.local/share` holds the cron log.

### Testing image (`next`)

Pushes to the `next` branch build `git.naaulu.org/naaulu/naaulu-live:next`. The build passes `NAAULU_BRANCH=next`, so the image clones `naaulu`'s `next` branch:

```bash
podman pull git.naaulu.org/naaulu/naaulu-live:next
```

Run it like the commands below with the `:next` tag. Publishing = merge `next` into `main` in both `naaulu` and `naaulu-live`, which rebuilds `:latest`.

### Baked boundary data

Province lines and city labels come from a cached OpenStreetMap extract (Geofabrik Postpass), prefetched at image build time. Runtime reads it from disk.

- `--build-arg NAAULU_BOUNDARIES=EST,BEL` selects the countries (comma-separated ISO3 codes). Default: every European country naaulu supports (46) — ≈ 460 MB unpacked, ~133 MB compressed per pull, ~15 minutes of Postpass queries at build.
- The build runs `prefetch_boundaries.py` and fails if a tier cannot be filled.
- The pristine copy sits at `/opt/naaulu-boundaries`, outside the volume path `/root/.local/share/naaulu`.
- On every container start `entrypoint.sh` seeds `/root/.local/share/naaulu/boundaries` from that copy with `cp -u`: no-op when the volume matches the image, upgrade when it does not.
- A tier still missing at runtime (country added without a rebuild, deleted file) is filled by naaulu on demand, or drawn as a gap when `NAAULU_BOUNDARIES_OFFLINE=1` is exported.
- `run.sh prefetch-boundaries` warms a country manually at any time.

## Run

One-off run:

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

Cron (`crontab -e`) — two lines, one per concern: compute and transfer.

```cron
# background estimate: hourly, one container, 12 frames, each waits T+100 s
0 * * * * "$HOME/naaulu-live-loop.sh"

# compute: plots + housekeeping (download pruning, the daily archive clean).
# No SFTP credentials, no transfer.
*/5 * * * * timeout --kill-after=30 20m podman run --rm --pull=newer -v naaulu-archive-bel:/root/.cache/naaulu -v naaulu-data-bel:/root/.local/share/naaulu -e NAAULU_COUNTRY=bel -e NAAULU_NETWORK="bel bel_spw bel_vmm" git.naaulu.org/naaulu/naaulu-live:latest /opt/naaulu-live/run.sh compute >> ~/.local/share/naaulu-live.log 2>&1

# transfer: SFTP only, 3 minutes after the compute tick. Own timeout, own
# exit status.
3/5 * * * * timeout --kill-after=30 20m podman run --rm --pull=newer -v naaulu-archive-bel:/root/.cache/naaulu -e SFTP_TARGETS="<sftp-username>:<sftp-host>:<sftp-password>:<remote-path>" -e NAAULU_COUNTRY=bel git.naaulu.org/naaulu/naaulu-live:latest /opt/naaulu-live/run.sh deploy >> ~/.local/share/naaulu-live.log 2>&1
```

| Invocation | Steps |
|---|---|
| `run.sh` | compute, transfer, housekeeping |
| `run.sh compute` | compute, housekeeping |
| `run.sh deploy` | transfer |

The transfer line needs only the archive volume and `NAAULU_COUNTRY` / `NAAULU_PRODUCT`. `config.sh` requires `SFTP_TARGETS` only for `run.sh` and `run.sh deploy`.

Staging is newest-timestamp-only: a transfer that runs before a plot finishes finds nothing new, and the next tick sends that frame.

> **Install once:** `install -m 755 loop.sh "$HOME/naaulu-live-loop.sh"`. It holds the container name, volumes and flags; `NAAULU_COUNTRY`, `NAAULU_LIVE_LOG` and others can be overridden in the cron line's environment. It passes `--delay 100`; an image predating that flag exits instead of starting.

> **Note:** The tick container is unnamed — do not add `--name`. A run waits up to `FRAME_WAIT_SECONDS` (300 s) for the frame and can outlast the 5-minute tick; an unnamed run overlaps the next instead of being skipped. The hourly loop container is named `naaulu-5min-<HH>`; its cron line's `rm -f` removes that hour's leftover from the previous day.

> **Note:** The `timeout` wrapper caps a run at 20 m. `deploy.sh` sets `ServerAliveInterval` and `ConnectTimeout` per session; `timeout` is the outer ceiling.

### Housekeeping

Two daily jobs. Add them alongside the cron lines above:

```cron
7  4 * * * : > "$HOME/.local/share/naaulu-live.log"
17 4 * * * podman image prune -f && podman container prune -f
```

- **Log** — truncated daily, last 24 h retained. Truncated, not renamed: the container holds it open with `>>`.
- **Containers** — hourly loop containers exit after their last frame and are recycled by name each hour. `container prune -f` removes STOPPED containers.
- **Images** — CI passes `CACHEBUST`, so each build is a new ~1 GB image and the previous one becomes `<none>`. `prune -f` drops untagged, unreferenced images only: never `:latest`, never an image in use.

## Configuration

| Variable | Default | Description |
|---|---|---|
| `NAAULU_COUNTRY` | `est` | Country code |
| `NAAULU_NETWORK` | `est` | Gauge network(s) for plot overlay, space-separated (e.g. `bel bel_spw bel_vmm`) |
| `NAAULU_PRODUCT` | `dove` | Estimation method |
| `NAAULU_RESOLUTION_BASE` | `1km` | 5-min resolution |
| `NAAULU_RESOLUTION_COMBINED` | `2km` | Hourly/daily resolution |
| `FRAME_WAIT_SECONDS` | `300` | Seconds a tick waits for the background estimate's 5-minute frame before skipping the plot |
| `KNMI_API_KEY` | (empty) | KNMI Open Data API key for the `nld` gauges; empty = the shared anonymous key |
| `SFTP_TARGETS` | (required) | SFTP targets as `user:host:password:path[:port[:options]]` (space-separated for multiple; port defaults to 22; options: `optional` = a failed target never fails the run — see [Delivery](#delivery)) |
| `SFTP_TARGETS_DATA` | (empty) | Like `SFTP_TARGETS`, but receives the NetCDF tiles. Empty = skip. See [Precip data deploy](#precip-data-deploy-netcdf) |
| `RETENTION_DOWNLOAD_MINUTES` | `15` | Minutes to keep raw downloaded radar files |
| `DEPLOY_PARALLEL` | `16` | SFTP targets deployed concurrently per run. Set via environment or `.env`. |

> **Note:** `RETENTION_DOWNLOAD_MINUTES` lives in `config.sh` (assigned after it sources `.env`), so `.env` cannot override it.

## Delivery

Every target is deployed with **two SFTP connections** (a retry adds one):

1. one `cd` + `ls -l` of the remote directory — parsed once into a name → size map;
2. one batch carrying the changed uploads plus a trailing `ls -l` that verifies them.

**No index file is written.** The target's own web server lists its directory: `autoindex on; autoindex_format json` (nginx), `Options +Indexes` (Apache). A target whose web server cannot list itself has nothing for a viewer to read.

**A target can be marked `optional`** — `user:host:password:path:22:optional`. The run exits 0 when an optional target fails; the failure is still reported as `OPTIONAL target failed - ignored, the run continues`, after its `ERROR:` lines. A non-optional target failing makes the run exit 1.

**Deployment only ever adds to a target.** Only the newest timestamp the archive holds is staged; nothing already delivered is deleted. Pruning a target is the customer's task. A legacy 6th field in the target spec is accepted and ignored.

**No cross-run backfill.** A file a target missed is retried inside the run that produced it, up to twice; later ticks stage only their own frame. A target unreachable for an hour shows that hour as a gap.

What this means as a consumer:

- **Files appear atomically.** Data is uploaded as `<name>.part` and renamed into place: a final name in the target directory is always a complete file.
- **No changes, no second connection.** When nothing is new, the run logs `Nothing to deliver` and skips the batch.
- **Targets run in parallel** (`DEPLOY_PARALLEL`, default 16). Each target's transcript is replayed as soon as that target finishes, in completion order.
- Interrupted uploads (`<name>.part`) are swept in the next batch by any run that is not about to rewrite them.
- The listing uses `cd` + `ls -l`, never `ls -l <dir>/`: OpenSSH's sftp prefixes path arguments with the directory (`www/x.png`).

### Benchmarking

`./bench.sh [-n targets] [-p parallel] [-k]` runs `deploy.sh` against a throwaway local SFTP server (rootless `sshd` on `127.0.0.1:2290`) through five phases — cold delivery, one steady tick, a no-change run, a debris sweep and a failure pair — asserting the exact upload, local-staging and `.part` counts after each. It reads your `~/.ssh/*.pub` keys and removes any `known_hosts` entry it created. `DEPLOY=/path/to/other/deploy.sh` points it at another version.

## Precip data deploy (NetCDF)

Every run stages the gridded precipitation tiles (NetCDF) held in `archive/precip` and, if `SFTP_TARGETS_DATA` is set, publishes them to their own SFTP targets. **Off by default.**

### Enabling it

Add `-e SFTP_TARGETS_DATA="<sftp-username>:<sftp-host>:<sftp-password>:<data-remote-path>[:<port>[:<options>]]"` to the `podman run` command and cron line above. Same `user:host:password:path[:port[:options]]` format as `SFTP_TARGETS` (empty password = SSH keys, port defaults to 22), space-separated for multiple targets.

The two deploys are independent: leaving `SFTP_TARGETS_DATA` unset skips only the data half.

### What gets uploaded

Everything under `$HOME/.cache/naaulu/archive/precip` matching `*.<duration>.<resolution>.<product>.nc` — only the newest timestamp of each duration:

```
20260923160500.E004_E005.N052_N053.pt5m.1km.eider.nc
└── time ─────┘ └── lon ──┘ └── lat ──┘ └dur┘ └res┘ └─ product
```

- **Flat layout** — tiles land directly in `<data-remote-path>`, no subdirectories.
- **Last timestamp only** — the newest tile of each duration is staged; older tiles are not re-sent. Nothing is deleted from the data target.
- **Incremental uploads** — files are size-compared against the remote listing, so only tiles a target does not already have transfer.
- **No index file** — nothing writes `<country>.json`; the target's web server lists its own directory (see [Delivery](#delivery)).

### Caveats

- A missing remote path is created one level at a time; if that fails the target aborts without uploading.
- Nothing is deleted from the target. The only `rm` a data run issues is against an interrupted `<name>.nc.part` of its own.

## Troubleshooting

```bash
tail -50 ~/.local/share/naaulu-live.log
```

**No log file?** `~/.local/share` is missing — `mkdir -p ~/.local/share`.

Deploy lines:

| Message | Meaning |
|---|---|
| `SFTP_TARGETS_DATA not set - skipping precip tiles` | data deploy disabled — expected until you set the variable |
| `Precip tiles staged: N` | tiles staged for the newest timestamp of each duration, before upload |
| `Deployed: N new, M unchanged` | `N` transferred, `M` already matched the remote |
| `Sweeping N interrupted upload(s)` | stale `<name>.part` from a previous run was removed (never a delivered file) |
| `NOTE: N target(s) carry a legacy retention field` | the retired per-target retention value was found and ignored |
| `Some deployments FAILED!` | size mismatch after retries — check the `FAILED:` lines above |
| `Nothing to deliver: no new files, no stale .part.` | second connection skipped — expected whenever nothing changed |
| `OPTIONAL target failed - ignored, the run continues` | a target marked `optional` failed — read the `ERROR:` lines above it; the run itself still succeeded |

Other symptoms:

- **Figures every 10 minutes instead of every 5** — `grep "Pipeline done" <log>` and check the gaps: ~600 s means a run overrunning the 5-minute tick.
- **`WARNING: no 5-min frame` throughout** — the background loop is not producing: `podman ps | grep naaulu-5min`. Nothing running = the cron line or `loop.sh` is missing; `unrecognized arguments` in the log = an image older than `estimate --delay`.
- **A container still running hours later** — a wedged transfer. `podman top <id>` confirms it, `podman rm -f <id>` removes it; check the cron line still carries `timeout`.
- **Log or `/` filling up** — the two daily jobs in [Housekeeping](#housekeeping); `podman system df` reports reclaimable image space.

## Data sources

The figures and tiles published here are derived works: radar from EUMETNET
OPERA, FMI, NOAA and the Bureau of Meteorology, rain gauges from the national
services, boundaries from OpenStreetMap (© OpenStreetMap contributors, ODbL,
fetched through Geofabrik Postpass into a local cache) and Natural Earth.
Keep the **© naaulu** credit when republishing them — the per-provider
licences are listed in naaulu's
[Data sources](https://git.naaulu.org/naaulu/naaulu/-/blob/main/README.md#data-sources).

## License

This project is licensed under the GNU Affero General Public License v3.0 (AGPL-3.0).
