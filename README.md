# PSDynDNS

[![CI](https://github.com/MDI-GmbH/PSDynDNS/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/MDI-GmbH/PSDynDNS/actions/workflows/ci.yml)
[![Coverage (main)](https://codecov.io/gh/MDI-GmbH/PSDynDNS/branch/main/graph/badge.svg)](https://app.codecov.io/gh/MDI-GmbH/PSDynDNS/tree/main)
[![Release](https://img.shields.io/github/v/release/MDI-GmbH/PSDynDNS?include_prereleases&label=release)](https://github.com/MDI-GmbH/PSDynDNS/releases)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Lightweight DynDNS2 client for Windows PowerShell 5.1 and PowerShell 7.** Updates IPv4 and IPv6 DNS records when your public IP changes, using a Windows Scheduled Task without extra runtime modules.

## Features

- DynDNS2 providers (default: [nsupdate.info](https://nsupdate.info/)), with independent IPv4/IPv6 configuration.
- Public-IP discovery and reconciliation with DNS A/AAAA records.
- Runs as `LOCAL SERVICE` with task-specific NTFS permissions and machine-scoped DPAPI credentials.
- Optional automatic updates from `stable`, `beta`, or `main`.
- Bootstrap installer runs once; the client stays installed.

## Requirements

| Requirement | Details |
| --- | --- |
| Windows | Windows 10/11 or Windows Server 2016+ (full version-specific validation pending) |
| PowerShell | Windows PowerShell 5.1 or PowerShell 7 |
| Administrator | Required for all installer operations; the scheduled client runs as `LOCAL SERVICE` |
| Network | HTTPS to the DynDNS provider and public-IP endpoints; GitHub access for release downloads and updates |
| Extra modules | None required by the runtime client |

## Quick start

Download or clone the repository and open **Windows PowerShell 5.1 or PowerShell 7 as Administrator**:

~~~powershell
.\Install-PSDynDNS.ps1 -Install -Hostname host.example.org
~~~

The installer downloads the latest stable client and prompts securely for the DynDNS secret. Do not put secrets directly into shell commands or commit them to the repository.

### Install directly from GitHub Releases

Open an **elevated** PowerShell terminal. These commands download the bootstrap installer locally before executing it.

**Latest stable release:**

~~~powershell
$p="$env:TEMP\Install-PSDynDNS.ps1"; Invoke-WebRequest 'https://github.com/MDI-GmbH/PSDynDNS/releases/latest/download/Install-PSDynDNS.ps1' -OutFile $p -UseBasicParsing -ErrorAction Stop; & $p -Install -Hostname host.example.org
~~~

**Beta channel:**

~~~powershell
$p="$env:TEMP\Install-PSDynDNS.ps1"; Invoke-WebRequest 'https://github.com/MDI-GmbH/PSDynDNS/releases/latest/download/Install-PSDynDNS.ps1' -OutFile $p -UseBasicParsing -ErrorAction Stop; & $p -Install -Hostname host.example.org -UpdateChannel beta
~~~

The bootstrap installer selects the client according to the requested channel. Release assets include `SHA256SUMS.txt` for optional manual integrity checks.

## Configuration & maintenance

The task repeats every **10 minutes** by default and runs **60 seconds after Windows startup**. The interval is stored in the Scheduled Task, not `config.json`. Windows PowerShell 5.1 is the default runtime.

~~~powershell
# Enable both address families (IPv4 is enabled by default)
.\Install-PSDynDNS.ps1 -IPv4Enabled $true -IPv6Enabled $true

# Change hostname, DynDNS endpoint and interval
.\Install-PSDynDNS.ps1 -Hostname host.example.org -UpdateUrl 'https://nsupdate.info/nic/update' -IntervalMinutes 15

# Rotate the encrypted secret (interactive prompt)
.\Install-PSDynDNS.ps1 -SetKey
~~~

The default provider is `https://nsupdate.info/nic/update`. DNS resolvers default to `8.8.8.8` and `8.8.4.4`. Unavailable preferred resolvers trigger Windows DNS fallback; conflicting DNS answers prevent automatic updates.

`AllowAutomaticConfigUpdates` is reserved for future functionality and currently has no effect. New installations default to `true`; existing configurations without this option remain opted out.

| Command | Result |
| --- | --- |
| `.\Install-PSDynDNS.ps1 -Repair` | Restore scheduled task and permissions |
| `.\Install-PSDynDNS.ps1 -UpdateClient -UpdateChannel beta` | Manually install the latest client selected by the beta channel |
| `.\Install-PSDynDNS.ps1 -UpdateClient -LocalClientPath .\PSDynDNS.ps1` | Manually install any chosen local client file |
| `.\Install-PSDynDNS.ps1 -ResetState` | Reset cached addresses and provider blocks |
| `.\Install-PSDynDNS.ps1 -Uninstall` | Remove client and task; retain configuration, DPAPI secret, and runtime data |
| `.\Install-PSDynDNS.ps1 -Uninstall -Purge` | Remove installation including configuration and secret |

Manual `-UpdateClient` verifies the replacement, creates a timestamped backup, and preserves configuration, credentials, and task settings.

Automatic updates retain at most one regular `PSDynDNS.ps1.bak` and one temporary `PSDynDNS.ps1.new` while an update is pending. On installations affected by protected leftover update files, run `Install-PSDynDNS.ps1 -Repair` from an elevated console to refresh the task-specific file permissions before retrying. Do not delete backups if the installed client is missing.

## Update channels

Automatic software updates are **disabled by default**. Enable them with:

~~~powershell
.\Install-PSDynDNS.ps1 -AutoUpdate $true -UpdateChannel beta -UpdateCheckHours 24
~~~

| Channel | Source | Intended use |
| --- | --- | --- |
| `stable` (default) | Latest published stable GitHub Release | Production |
| `beta` | Newest published release, including pre-releases | Testing |
| `main` | Current Git `main` commit | Development only |

Downloads are validated before installation. Manual `-UpdateClient` works independently of `AutoUpdate`.

## Command-line reference

Installer (`Install-PSDynDNS.ps1`; requires Administrator rights). Existing installations can be reconfigured without `-Configure`.

| Parameter | Purpose |
| --- | --- |
| `-Install -Hostname <FQDN>` | Install client |
| `-Hostname`, `-Username`, `-UpdateUrl` | DNS name, optional username, and DynDNS2 endpoint |
| `-IPv4Enabled`, `-IPv6Enabled` | Enable address families |
| `-IPv4CheckUrl`, `-IPv6CheckUrl` | Public-IP discovery endpoints |
| `-DnsServers` | DNS resolver IP addresses |
| `-Runtime` | `WindowsPowerShell` or `PowerShell7` |
| `-IntervalMinutes` | Task interval (default: 10; not in JSON) |
| `-AutoUpdate`, `-UpdateChannel`, `-UpdateCheckHours` | Software update settings |
| `-AllowAutomaticConfigUpdates` | Opt in/out of future automatic config changes |
| `-SetKey` | Replace DPAPI-protected secret |
| `-Repair`, `-ResetState` | Repair installation or reset runtime state |
| `-UpdateClient [-UpdateChannel beta] [-LocalClientPath <path>]` | Manually update installed client |
| `-Uninstall [-Purge]` | Uninstall; optionally remove all data |
| `-LocalClientPath` | Install a chosen local client script (development/debugging) |
| `-CredentialSecret` | SecureString for unattended installation or key rotation |

Client (`PSDynDNS.ps1`):

| Parameter | Purpose |
| --- | --- |
| `-ConfigPath` | Override configuration path |
| `-ForceDnsUpdate` | Update provider regardless of DNS match |
| `-ForceUpgrade` | Install selected channel's current client version |
| `-UpgradeChannel stable\|beta\|main` | Override channel for `-ForceUpgrade` only |

~~~powershell
& 'C:\ProgramData\PSDynDNS\app\PSDynDNS.ps1' -ForceUpgrade -UpgradeChannel beta
~~~

## Installation layout

~~~text
C:\ProgramData\PSDynDNS\
  app\
    PSDynDNS.ps1
  runtime\
    state.json
    client.log
  config.json
  secret.dpapi
~~~

The task may write to `app` and `runtime`, but only read `config.json` and `secret.dpapi`. DPAPI complements restrictive NTFS permissions.

## Troubleshooting

**Open PowerShell or your log viewer as Administrator** to access the protected log file:

~~~powershell
Get-ScheduledTaskInfo -TaskName PSDynDNS
Get-Content "$env:ProgramData\PSDynDNS\runtime\client.log" -Tail 30
~~~

The log rotates at approximately 1 MiB (`client.log.1`). `state.json` stores retry and software-update status.

## Development & releases

- [PowerShell CI](.github/workflows/ci.yml) runs Pester and Windows integration tests in parallel under PowerShell 5.1 and 7, requires **75% coverage** in both, then verifies a test release package without publishing it.
- [Publish Release](.github/workflows/release.yml) runs manually on `main`, repeats CI, and publishes verified assets and release notes.
- Create short-lived feature/fix branches from `main` and merge through pull requests. Real-provider and version-specific Windows Server compatibility require field validation.

Downloads and release notes: [GitHub Releases](https://github.com/MDI-GmbH/PSDynDNS/releases).

## License

[MIT](LICENSE).
