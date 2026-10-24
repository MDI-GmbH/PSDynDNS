# PSDynDNS

[![CI](https://github.com/MDI-GmbH/PSDynDNS/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/MDI-GmbH/PSDynDNS/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/MDI-GmbH/PSDynDNS?include_prereleases&label=release)](https://github.com/MDI-GmbH/PSDynDNS/releases)
[![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![PowerShell 5.1](https://img.shields.io/badge/Windows%20PowerShell-5.1-5391FE)

**Lightweight DynDNS2 client for Windows PowerShell 5.1.** Updates IPv4 and IPv6 DNS records when your public IP changes, using a Windows Scheduled Task and no external runtime modules.

> [!WARNING]
> **Development preview.** The code on `dev` is not approved for production. Windows integration tests and updater rollback validation are required before a stable release. Keep automatic updates disabled until then.

## Features

- Supports DynDNS2 providers (default: [nsupdate.info](https://nsupdate.info/)).
- Independent IPv4 and IPv6 configuration with public-IP discovery.
- Scheduled updates under `LOCAL SERVICE` using task-specific NTFS access.
- Machine-scoped DPAPI for the update secret, plus restrictive NTFS ACLs.
- Change detection, provider response handling, logging and retry behavior.
- Optional `stable`, `beta` and `main` self-update channels.
- Temporary bootstrap installer: only the client stays installed.

## Requirements

| Requirement | Details |
| --- | --- |
| Windows | Windows 10/11 or Windows Server 2016+ (full compatibility testing pending) |
| PowerShell | **Windows PowerShell 5.1** |
| Administrator | Only for installation, configuration, repair and removal |
| Network | HTTPS to the DynDNS provider and IP-discovery endpoints |
| Extra modules | None for the runtime client |

## Quick start

> [!IMPORTANT]
> The repository is private. GitHub downloads require authentication until publication. Use the following source-based installation **only on an isolated test machine**.

Clone the repository and open **Windows PowerShell 5.1 as Administrator**.

~~~powershell
.\Install-PSDynDNS.ps1 -Install -Hostname host.example.org -LocalClientPath .\PSDynDNS.ps1
~~~

The installer asks for the DynDNS secret interactively. Never include the secret in a command line or commit it to the repository. The default provider is `https://nsupdate.info/nic/update`; the scheduled interval defaults to 10 minutes.

### Configuration

~~~powershell
# Enable dual-stack updates
.\Install-PSDynDNS.ps1 -Configure -IPv4Enabled $true -IPv6Enabled $true

# Change hostname, provider URL and retry interval
.\Install-PSDynDNS.ps1 -Configure -Hostname host.example.org -UpdateUrl 'https://nsupdate.info/nic/update' -IntervalMinutes 15

# Rotate the encrypted secret (interactive prompt)
.\Install-PSDynDNS.ps1 -SetKey
~~~

### Maintenance

| Command | Result |
| --- | --- |
| `.\Install-PSDynDNS.ps1 -Repair` | Restore the task and configured permissions |
| `.\Install-PSDynDNS.ps1 -ResetState` | Reset cached address and blocked state |
| `.\Install-PSDynDNS.ps1 -Uninstall` | Remove executable and task, retain configuration |
| `.\Install-PSDynDNS.ps1 -Uninstall -Purge` | Remove installation including configuration and secret |

The scheduled task runs the client automatically. For troubleshooting, the client accepts `-ConfigPath` and `-ForceDnsUpdate`; never run the task-writable installed script with administrator privileges.

## Update channels

Configure the updater using the installer:

~~~powershell
.\Install-PSDynDNS.ps1 -Configure -AutoUpdate $true -UpdateChannel beta -UpdateCheckHours 24
~~~

| Channel | Source | Intended use |
| --- | --- | --- |
| `stable` (default) | Latest published stable GitHub Release | Production after validation |
| `beta` | Newest published release, including pre-releases | Pre-production testing |
| `main` | Current Git `main` commit | Development only |

The updater validates downloads and verifies PowerShell syntax before staging a replacement. **Self-update and rollback are not yet approved for production.** Clients cannot anonymously update from the private repository; do not distribute personal access tokens to clients.

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

The task identity may write to `app` and `runtime`, but should only read `config.json` and `secret.dpapi`. Machine-scope DPAPI is not a substitute for correct NTFS access controls.

## Development and releases

- **Development:** `dev` branch; merge into `main` via reviewed pull requests.
- **CI:** [PowerShell CI](.github/workflows/ci.yml) runs syntax checks, Pester tests and real Windows installation integration tests. New PR commits cancel older in-progress CI runs for the same PR.
- **Build:** Successful tests on `main` produce a ZIP and checksums.
- **Publishing:** Manually start [Publish Release](.github/workflows/release.yml) on `main`, specify e.g. `0.2.0` (stable) or `0.3.0-beta.1` (pre-release). The release workflow runs tests and prepares assets and automatically generated notes before publication.

Find downloads and release notes on [GitHub Releases](https://github.com/MDI-GmbH/PSDynDNS/releases).

### Security / validation

The Windows integration job exercises installation, config updates, DPAPI, LOCAL SERVICE task identity, scoped NTFS ACLs, repair, state reset and removal on an ephemeral GitHub runner. It uses synthetic secrets and a nonfunctional HTTPS endpoint, not actual DynDNS credentials. Separate system tests are required for real provider behavior and self-update rollback.

## License

[MIT](LICENSE).
