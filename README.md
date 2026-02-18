# Conduit Manager - macOS Edition

```
  ██████╗ ██████╗ ███╗   ██╗██████╗ ██╗   ██╗██╗████████╗
 ██╔════╝██╔═══██╗████╗  ██║██╔══██╗██║   ██║██║╚══██╔══╝
 ██║     ██║   ██║██╔██╗ ██║██║  ██║██║   ██║██║   ██║
 ██║     ██║   ██║██║╚██╗██║██║  ██║██║   ██║██║   ██║
 ╚██████╗╚██████╔╝██║ ╚████║██████╔╝╚██████╔╝██║   ██║
  ╚═════╝ ╚═════╝ ╚═╝  ╚═══╝╚═════╝  ╚═════╝ ╚═╝   ╚═╝
                      M A N A G E R
                       macOS Edition
```

![Version](https://img.shields.io/badge/version-1.1.0-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Platform](https://img.shields.io/badge/platform-macOS-black?logo=apple)
![Docker](https://img.shields.io/badge/Docker_Desktop-Required-2496ED?logo=docker&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-M1_|_M2_|_M3_|_M4-555555?logo=apple)

A management tool for running Psiphon Conduit nodes on macOS (Apple Silicon). Help users access the open internet during network restrictions.

> **Note:** For Linux servers, use the [main branch](https://github.com/SamNet-dev/conduit-manager/tree/main).

## Quick Install

```bash
curl -sL https://raw.githubusercontent.com/SamNet-dev/conduit-manager/macos-edition/conduit.sh | bash
```

Or download and run manually:

```bash
curl -sL https://raw.githubusercontent.com/SamNet-dev/conduit-manager/macos-edition/conduit.sh -o conduit.sh
bash conduit.sh
```

## Requirements

- macOS with Apple Silicon (M1/M2/M3/M4)
- Homebrew (installed automatically if missing)
- Internet connection

## What Gets Installed

- **Docker Desktop** (via Homebrew cask, if not present)
- **Conduit containers** (scalable: 1-32 based on your hardware)
- **Background tracker** (network statistics with GeoIP)
- **Telegram bot service** (optional notifications and remote management)
- **`conduit` CLI** command for management

## Features

- **Multi-Container Support** — Run up to 32 containers based on your Mac's capacity
- **Live Dashboard** — Real-time stats showing CPU, RAM, connections, and upload/download with per-country breakdown
- **Per-Container Status** — Individual monitoring for each container with detailed metrics
- **Background Tracker** — Captures network traffic every 60 seconds with country-level GeoIP statistics (no sudo required)
- **Live Peers by Country** — Full-screen display showing TOP 10 countries by traffic volume and active clients (no sudo required)
- **Telegram Notifications** — Automated reports, alerts (CPU/RAM/down), and bot commands
- **Bot Commands** — Remote management via Telegram: `/status`, `/peers`, `/uptime`, `/containers`, `/restart_N`, `/stop_N`, `/start_N`
- **Per-Container Settings** — Configure max-clients, bandwidth, CPU, and memory per container
- **Resource Limits** — Set CPU cores and memory limits for individual containers
- **Easy Management** — Powerful CLI commands or interactive menu
- **Backup & Restore** — Backup and restore your node identity keys
- **Health Checks** — Comprehensive diagnostics for troubleshooting
- **Complete Uninstall** — Clean removal of all components

## What's New in v1.1

- **Multi-Container Support** — Scale from 1 to 32 containers based on your hardware
- **Background Tracker Service** — 24/7 network monitoring with country-level statistics (no sudo required)
- **Telegram Bot Integration** — Automated reports, alerts, and remote container management
- **Per-Container Configuration** — Individual settings for max-clients, bandwidth, CPU, memory
- **Live Connection Stats** — Real-time monitoring with 5-second refresh and per-country breakdown
- **macOS-Specific Optimizations** — Docker `/proc/net/tcp` inspection eliminates tcpdump/sudo requirement
- **Improved Reliability** — Fixed Docker logs parsing, removed timeout dependency, proper file ownership handling

## CLI Commands

```bash
conduit status       # Show current status
conduit stats        # Live statistics
conduit logs         # View Docker logs
conduit health       # Run diagnostics
conduit peers        # Live peer traffic by country (no sudo required)

conduit start        # Start container
conduit stop         # Stop container
conduit restart      # Restart container
conduit update       # Update to latest image

conduit settings     # Change max-clients and bandwidth
conduit menu         # Interactive menu

conduit backup       # Backup node identity key
conduit restore      # Restore from backup
conduit uninstall    # Remove everything
```

## Configuration

| Option | Default | Range | Description |
|--------|---------|-------|-------------|
| `max-clients` | 200 | 1-1000 | Maximum concurrent proxy clients per container |
| `bandwidth` | 5 | 1-40, -1 | Bandwidth limit per peer (Mbps). -1 = unlimited |
| `containers` | 1 | 1-32 | Number of Conduit containers to run |
| `cpu-limit` | — | 0.5+ | CPU cores per container (optional) |
| `memory-limit` | — | 64m+ | Memory limit per container (optional) |

## Telegram Bot

Setup via menu option `t. 📲 Telegram Notifications`:

**Available Commands:**
- `/status` — Full status report on demand
- `/peers` — Show connected & connecting clients
- `/uptime` — Per-container uptime and 24h availability
- `/containers` — List all containers with status and stats
- `/restart_N` — Restart container N (e.g., `/restart_1`)
- `/stop_N` — Stop container N
- `/start_N` — Start container N

**Features:**
- Automated periodic reports (configurable: 1h, 3h, 6h, 12h, 24h)
- Real-time alerts (high CPU >90%, high RAM >90%, container down)
- Daily and weekly summaries (optional)
- Custom server labels for multi-server setups

## macOS-Specific Notes

### Platform Differences
- **Docker Desktop** — Uses Docker Desktop (via Homebrew) instead of Docker Engine
- **Port Publishing** — Uses `-p 443:443/tcp -p 443:443/udp` instead of `--network=host`
- **No Auto-Start** — launchd integration not implemented yet (manual start after reboot)
- **Nohup Services** — Tracker and Telegram run via nohup (not systemd)

### Feature Adaptations
- **Live Map (`conduit peers`)** — Uses Docker `/proc/net/tcp` inspection (no sudo required)
- **Background Tracker** — Extracts IPs directly from container networking without tcpdump
- **GeoIP Database** — Uses free DB-IP Lite (no account needed)
- **Status Dashboard** — Displays active clients and top upload countries side-by-side like Linux

### Technical Implementation
- Modern bash (via Homebrew) for associative array support in tracker
- Direct Docker container inspection eliminates need for packet capture tools
- File ownership management prevents permission issues when running with sudo
- Removed `timeout` command dependency (not available by default on macOS)

## Uninstall

```bash
conduit uninstall
```

Or manually:
```bash
# Stop and remove all containers
docker stop $(docker ps -q --filter "name=conduit") 2>/dev/null
docker rm $(docker ps -aq --filter "name=conduit") 2>/dev/null

# Remove volumes and data
docker volume rm conduit-data conduit-2-data conduit-3-data 2>/dev/null

# Remove management script and config
rm -rf ~/.conduit
rm /usr/local/bin/conduit

# Stop background services
pkill -f telegram_notify.sh
pkill -f conduit-tracker.sh
```

---

## License

MIT License

## Links

- [Psiphon](https://psiphon.ca/)
- [Psiphon Conduit](https://github.com/Psiphon-Inc/conduit)
- [Linux Version (main branch)](https://github.com/SamNet-dev/conduit-manager/tree/main)
