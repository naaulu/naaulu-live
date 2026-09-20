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
podman volume create naaulu-archive-bel
podman volume create naaulu-data-bel
podman pull git.naaulu.org/naaulu/naaulu-live:latest
```

> **Note:** `loginctl enable-linger` is required so Podman can access the container runtime directory from cron jobs. Without it, cron runs without your user session and the storage paths are not available.

## Run

Test a one-off run:

```bash
podman run --rm --name naaulu-bel \
  -v naaulu-archive-bel:/root/.cache/naaulu \
  -v naaulu-data-bel:/root/.local/share/naaulu \
  -e SFTP_TARGETS="<sftp-username>:<sftp-host>:<sftp-password>:<remote-path>" \
  -e NAAULU_COUNTRY=bel \
  -e NAAULU_NETWORK=bel \
  git.naaulu.org/naaulu/naaulu-live:latest /opt/naaulu-live/run.sh
```

Add a cron job (`crontab -e`):

```cron
*/5 * * * * podman run --rm --pull=newer --name naaulu-bel -v naaulu-archive-bel:/root/.cache/naaulu -v naaulu-data-bel:/root/.local/share/naaulu -e SFTP_TARGETS="<sftp-username>:<sftp-host>:<sftp-password>:<remote-path>" -e NAAULU_COUNTRY=bel -e NAAULU_NETWORK=bel git.naaulu.org/naaulu/naaulu-live:latest /opt/naaulu-live/run.sh >> ~/.local/share/naaulu-live.log 2>&1
```

## Configuration

| Variable | Default | Description |
|---|---|---|
| `NAAULU_COUNTRY` | `est` | Country code |
| `NAAULU_NETWORK` | `est` | Gauge network for plot overlay |
| `NAAULU_PRODUCT` | `dove` | Estimation method |
| `NAAULU_RESOLUTION_BASE` | `1km` | 5-min resolution |
| `NAAULU_RESOLUTION_COMBINED` | `2km` | Hourly/daily resolution |
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

Deploy lines to look for:

| Message | Meaning |
|---|---|
| `SFTP_TARGETS_DATA not set - skipping precip tiles` | data deploy disabled — expected until you set the variable |
| `Precip tiles staged: N` | tiles found within the retention window, before upload |
| `Deployed: N new, M unchanged` | `N` transferred, `M` already matched the remote |
| `Cleanup <duration>: N old files` | remote tiles past retention, removed this run |
| `Some deployments FAILED!` | size mismatch after retries — check the `FAILED:` lines above |

## License

This project is licensed under the GNU Affero General Public License v3.0 (AGPL-3.0).
