# Naaulu Live

Real-time rainfall estimation pipeline for countries. Runs in a Podman container, generates 5-minute, hourly, and daily rainfall plots, and deploys them to a web server.

## Architecture

```
Host cron → podman run (ephemeral container)
  ├── estimate  (*/5 min)  → 5-min rainfall from radar
  ├── combine   (hourly/daily) → hourly/daily accumulations
  ├── plot      (*/5 min + hourly + daily) → PNG maps
  └── deploy    (every run) → SFTP to naaulu-org

Web viewer (index.html)
  └── Select country/duration → view latest image → arrow key navigation
```

## Prerequisites

- A Debian 13 (Trixie) server
- SFTP credentials for the hosting server

## Install

```bash
sudo apt update
sudo apt install -y podman
podman volume create naaulu-archive-bel
podman volume create naaulu-data-bel
podman pull git.naaulu.org/naaulu/naaulu-live:latest
```

## Run

Test a one-off run:

```bash
podman run --rm --name naaulu-bel \
  -v naaulu-archive-bel:/root/.cache/naaulu \
  -v naaulu-data-bel:/root/.local/share/naaulu \
  -e WEB_USER=<sftp-username> \
  -e WEB_HOST=<sftp-host> \
  -e WEB_PASS=<sftp-password> \
  -e NAAULU_COUNTRY=bel \
  -e NAAULU_NETWORK=bel \
  git.naaulu.org/naaulu/naaulu-live:latest /opt/naaulu-live/run.sh
```

Add a cron job (`crontab -e`):

```cron
*/5 * * * * podman run --rm --name naaulu-bel -v naaulu-archive-bel:/root/.cache/naaulu -v naaulu-data-bel:/root/.local/share/naaulu -e WEB_USER=<sftp-username> -e WEB_HOST=<sftp-host> -e WEB_PASS=<sftp-password> -e NAAULU_COUNTRY=bel -e NAAULU_NETWORK=bel git.naaulu.org/naaulu/naaulu-live:latest /opt/naaulu-live/run.sh >> ~/.local/share/naaulu-live.log 2>&1
```

## Configuration

| Variable | Default | Description |
|---|---|---|
| `NAAULU_COUNTRY` | `est` | Country code |
| `NAAULU_NETWORK` | `est` | Gauge network for plot overlay |
| `NAAULU_PRODUCT` | `dove` | Estimation method |
| `NAAULU_RESOLUTION_BASE` | `1km` | 5-min resolution |
| `NAAULU_RESOLUTION_COMBINED` | `2km` | Hourly/daily resolution |
| `NAAULU_LOG_LEVEL` | `info` | Log verbosity |
| `WEB_USER` | (required) | SFTP username |
| `WEB_HOST` | (required) | SFTP host |
| `WEB_PASS` | (required) | SFTP password, passed via `-e` |
| `REMOTE_DIR` | `www` | Remote SFTP directory |
| `RETENTION_5MIN_HOURS` | `3` | Hours to keep 5-min images |
| `RETENTION_HOURLY_DAYS` | `1` | Days to keep hourly images |
| `RETENTION_DAILY_DAYS` | `20` | Days to keep daily images |

## Web Viewer

The viewer is deployed to `naaulu/live/index.html` on the server (accessible at `naaulu.org/live`). Users can:

1. Select country
2. Select duration (5 min / Hourly / Daily)
3. View the latest rainfall map
4. Navigate with left/right arrow keys

## Troubleshooting

```bash
tail -50 ~/.local/share/naaulu-live.log
```

## License

This project is licensed under the GNU Affero General Public License v3.0 (AGPL-3.0).
