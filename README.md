# Naaulu Live

Real-time rainfall estimation pipeline for countries. Runs in a Podman container, generates 5-minute, hourly, and daily rainfall plots, and deploys them to a web server.

## Architecture

```
Host cron → podman run (ephemeral container)
  ├── estimate  (*/5 min)  → 5-min rainfall from radar
  ├── combine   (hourly/daily) → hourly/daily accumulations
  ├── plot      (*/5 min + hourly + daily) → PNG maps
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
podman run --rm --name naaulu-bel \
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
*/5 * * * * timeout --kill-after=30 20m podman run --rm --pull=newer --name naaulu-bel -v naaulu-archive-bel:/root/.cache/naaulu -v naaulu-data-bel:/root/.local/share/naaulu -e SFTP_TARGETS="<sftp-username>:<sftp-host>:<sftp-password>:<remote-path>" -e NAAULU_COUNTRY=bel -e NAAULU_NETWORK="bel bel_spw bel_vmm" git.naaulu.org/naaulu/naaulu-live:latest /opt/naaulu-live/run.sh >> ~/.local/share/naaulu-live.log 2>&1
```

> **Note:** The `timeout` wrapper is load-bearing, not decoration. `ssh` sends no keepalives by default, so an SFTP server that goes silent mid-transfer leaves the container blocked in `read()` forever. Because `--rm` only cleans up on exit, that container never releases its name, and every later cron tick dies with `container name ... is already in use` instead of running the pipeline — silently, since the run it would have started produces no output at all. `deploy.sh` sets `ServerAliveInterval`/`ConnectTimeout` per session; this cap is the outer backstop. Rotate the log too — it is appended to forever.

## Configuration

| Variable | Default | Description |
|---|---|---|
| `NAAULU_COUNTRY` | `est` | Country code |
| `NAAULU_NETWORK` | `est` | Gauge network(s) for plot overlay, space-separated (e.g. `bel bel_spw bel_vmm`) |
| `NAAULU_PRODUCT` | `dove` | Estimation method |
| `NAAULU_RESOLUTION_BASE` | `1km` | 5-min resolution |
| `NAAULU_RESOLUTION_COMBINED` | `2km` | Hourly/daily resolution |
| `RADAR_WAIT_SECONDS` | `100` | Seconds after the 5-minute mark to wait for radar data before starting the estimation |
| `KNMI_API_KEY` | (empty) | KNMI Open Data API key for the `nld` gauges; empty = the shared anonymous key |
| `SFTP_TARGETS` | (required) | SFTP targets as `user:host:password:path` (space-separated for multiple) |
| `SFTP_TARGETS_DATA` | (empty) | Like `SFTP_TARGETS`, but receives the NetCDF tiles. Empty = skip. See [Precip data deploy](#precip-data-deploy-netcdf) |
| `RETENTION_5MIN_HOURS` | `2` | Hours to keep 5-min images |
| `RETENTION_HOURLY_HOURS` | `20` | Hours to keep hourly images |
| `RETENTION_DAILY_DAYS` | `20` | Days to keep daily images |
| `RETENTION_DOWNLOAD_MINUTES` | `15` | Minutes to keep raw downloaded radar files |

> **Note:** `RETENTION_*` values live in `config.sh` (assigned after it sources `.env`), so `.env` cannot override them.

## Precip data deploy (NetCDF)

Every run stages the gridded precipitation tiles (NetCDF) held in `archive/precip` and, if `SFTP_TARGETS_DATA` is set, publishes them to their own SFTP targets. **Off by default** — existing deployments are unaffected until you set the variable.

### Enabling it

Add `-e SFTP_TARGETS_DATA="<sftp-username>:<sftp-host>:<sftp-password>:<data-remote-path>"` to the `podman run` command and cron line above. Same `user:host:password:path` format as `SFTP_TARGETS`, space-separated for multiple targets.

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
| `Error: creating container storage: the container name ... is already in use` | a previous run never exited, so `--rm` never fired — `podman rm -f <name>`. A stuck SFTP upload is the usual cause; check `podman top <name>` for a `sftp` process with tens of hours of elapsed time |

**Log growing without bound?** The cron line appends forever. Rotate when it exceeds a size and no run is in flight:

```cron
*/30 * * * * L="$HOME/.local/share/naaulu-live.log"; if [ -s "$L" ] && [ "$(stat -c%s "$L")" -gt 26214400 ] && ! podman container exists naaulu-bel 2>/dev/null; then gzip -c "$L" > "$L.1.gz" && : > "$L"; fi >/dev/null 2>&1
```

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
