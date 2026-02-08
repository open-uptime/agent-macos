# OpenUptime macOS Server Monitoring Agent

Forked from [HetrixTools macOS Agent v2.0.0](https://github.com/hetrixtools/agent-macos).

A lightweight Bash monitoring agent for macOS that collects system metrics and reports them to your self-hosted OpenUptime platform.

## Features

- CPU usage (overall, user, system) via `top -l 2`
- CPU info (model, sockets, cores, threads, clock speed)
- Load averages (1, 5, 15 minute)
- RAM usage via `vm_stat` (active + wired + compressed)
- Swap usage via `sysctl vm.swapusage`
- Per-mount disk usage via `df`
- Disk inodes via `df -i`
- Disk IOPS via `ioreg` (per physical disk)
- Per-NIC network throughput via `netstat -ibI`
- Per-NIC IPv4/IPv6 addresses via `ifconfig`
- Temperature monitoring via `powermetrics` (Intel) or `smartctl` (Apple Silicon)
- Drive health via `smartctl` (S.M.A.R.T.)
- Service monitoring (up to 10 services)
- Port connection tracking via `lsof`
- Running processes capture
- Custom variables (JSON file)
- Outgoing ping tests (packet loss, RTT)
- Exponential backoff retry (5s, 15s, 45s)
- Bash 3.2 compatible (ships with macOS)

### macOS-Specific Notes

- IO wait and steal time are always reported as `0` (not available on macOS)
- RAM buffers and cache are always `0` (macOS manages memory differently)
- Requires-reboot is always `false` (not available on macOS)
- Software RAID monitoring is a placeholder (AppleRAID not yet implemented)

## Requirements

- macOS 10.15 (Catalina) or later
- Bash 3.2+ (included with macOS)
- `curl` (included with macOS)
- Root privileges for installation and temperature monitoring
- Optional: `smartmontools` for drive health (`brew install smartmontools`)

## Installation

### Automated (via platform)

When you create a server in the OpenUptime dashboard, you'll receive a one-line installer command. Run it as root:

```bash
sudo bash -c "$(curl -sSL https://your-platform.example.com/install.sh)" -- \
  --uuid YOUR_SERVER_UUID \
  --api-key YOUR_API_KEY \
  --url https://your-platform.example.com
```

### Manual

1. Clone this repository:
   ```bash
   git clone https://github.com/openuptime/agent-macos.git
   cd agent-macos
   ```

2. Run the install script as root:
   ```bash
   sudo bash openuptime_install.sh \
     YOUR_SERVER_UUID \
     YOUR_API_KEY \
     https://your-platform.example.com \
     0  # 0 = run as _openuptime user, 1 = run as root
   ```

   Additional optional parameters (positional):
   - `$5` — Services to monitor (comma-separated, e.g., `"sshd,nginx"`)
   - `$6` — Enable software RAID monitoring (`1` to enable)
   - `$7` — Enable drive health monitoring (`1` to enable)
   - `$8` — Enable running processes capture (`1` to enable)
   - `$9` — Ports to monitor (comma-separated, e.g., `"80,443"`)

## Configuration

The configuration file is located at `/opt/openuptime/openuptime.cfg`.

| Parameter | Default | Description |
|---|---|---|
| `OPENUPTIME_SERVER_UUID` | `""` | Server UUID (set during installation) |
| `OPENUPTIME_REPORTING_URL` | `""` | Platform API base URL |
| `OPENUPTIME_API_KEY` | `""` | Per-server authentication token |
| `NetworkInterfaces` | `""` | NICs to monitor (auto-detect if empty) |
| `CheckServices` | `""` | Services to monitor (comma-separated, max 10) |
| `CheckSoftRAID` | `0` | Enable software RAID monitoring |
| `CheckDriveHealth` | `0` | Enable S.M.A.R.T. drive health |
| `RunningProcesses` | `0` | Capture running processes |
| `ConnectionPorts` | `""` | Ports to track (auto-detect if empty) |
| `CustomVars` | `"custom_variables.json"` | Path to custom variables JSON |
| `SecuredConnection` | `1` | Verify SSL on metrics POST |
| `CollectEveryXSeconds` | `3` | Sampling interval within each minute |
| `DEBUG` | `0` | Enable debug logging |
| `OutgoingPings` | `""` | Ping targets (`Name,IP\|Name,IP`) |
| `OutgoingPingsCount` | `20` | Packets per ping test (10-40) |

## File Locations

| File | Path |
|---|---|
| Agent script | `/opt/openuptime/openuptime_agent.sh` |
| Configuration | `/opt/openuptime/openuptime.cfg` |
| Wrapper script | `/opt/openuptime/run_agent.sh` |
| Launchd plist | `/Library/LaunchDaemons/com.openuptime.agent.plist` |
| Debug log | `/opt/openuptime/debug.log` |
| Agent log | `/opt/openuptime/openuptime_agent.log` |
| Service user | `_openuptime` (UID 400+) |

## Updating

```bash
sudo bash openuptime_update.sh [branch]
```

The update script preserves your existing configuration while fetching the latest agent and config template.

## Uninstalling

```bash
sudo bash openuptime_uninstall.sh
```

This removes the agent, launchd job, service user, and all associated files.

## Scheduling

The agent uses macOS **launchd** for scheduling:

- Plist: `/Library/LaunchDaemons/com.openuptime.agent.plist`
- Runs every minute at second 0 via `StartCalendarInterval`
- Starts on boot via `RunAtLoad`
- The wrapper script (`run_agent.sh`) launches the agent in the background

## Metrics Payload

The agent sends a plain JSON POST to `{REPORTING_URL}/api/metrics` with:
- `Content-Type: application/json`
- `Authorization: Bearer {API_KEY}`

No gzip compression or base64 encoding — structured JSON arrays for per-mount disk, per-NIC network, and all optional metrics.

## Changelog

### Version 2.0.0 (OpenUptime Fork)
- Replaced all HetrixTools branding with OpenUptime
- Replaced hardcoded API URL with configurable `OPENUPTIME_REPORTING_URL`
- Added `OPENUPTIME_SERVER_UUID` and `OPENUPTIME_API_KEY` config parameters
- Converted payload from gzip+base64 compressed form data to plain JSON POST
- Added `Authorization: Bearer` header for API key authentication
- Removed base64 encoding of string fields (os, kernel, hostname, cpumodel)
- Restructured JSON payload field names to match OpenUptime schema
- Implemented exponential backoff retry (5s, 15s, 45s)
- Removed install/uninstall notification callbacks
- Renamed launchd plist to `com.openuptime.agent.plist`
- Renamed service user from `_hetrixtools` to `_openuptime`
- Renamed install directory from `/opt/hetrixtools/` to `/opt/openuptime/`
- Renamed all script files to `openuptime_*.sh`
