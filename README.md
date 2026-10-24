# PSDynDNS

Lightweight Windows DynDNS2 client for Windows PowerShell 5.1.

> **Development status:** Early preview. The code in `dev` is not production-ready. Do not deploy onto production systems. The bootstrap installer, task-SID ACL model and the new self-update implementation still require end-to-end validation on Windows Server 2016 before production use.

## Design

- Generic DynDNS2; defaults to nsupdate.info.
- IPv4, IPv6, or dual-stack via a single `myip` argument.
- Machine-bound DPAPI secret, protected by NTFS ACLs.
- One recurring task under LOCAL SERVICE, with a dedicated task SID.
- Bootstrap administrator script is **not** installed permanently.
- `PSDynDNS.ps1` contains no privileged installation methods.
- Runtime `-ConfigPath` is optional; it points at the configuration file, while `secret.dpapi` and `state.json` live in its directory.
- No runtime PowerShell modules.

## Planned local layout

```text
C:\ProgramData\PSDynDNS\
  app\PSDynDNS.ps1
  config.json
  secret.dpapi
  runtime\\state.json
  runtime\\client.log
```

`app` is writable by the task's own SID for future unprivileged updates. Configuration and secret files are read-only to the task. The task may write state and logs (the installer must explicitly provision their file permissions). Administrators and SYSTEM retain full access.

## Bootstrap modes

All administrative actions require an elevated Windows PowerShell 5.1 console.

```powershell
# Developer test from a checked-out local source
.\Install-PSDynDNS.ps1 -Install -Hostname host.example.org -LocalClientPath .\PSDynDNS.ps1

# Configure without changing permissions or the scheduled task
.\Install-PSDynDNS.ps1 -Configure -Hostname host.example.org -IPv4Enabled $true -IPv6Enabled $true

# Update the DynDNS secret interactively
.\Install-PSDynDNS.ps1 -SetKey

# Repair the task and ACLs
.\Install-PSDynDNS.ps1 -Repair

# Reset blocked state after configuration or credential repair
.\\Install-PSDynDNS.ps1 -ResetState

# Remove application/task; retain config and secret
.\Install-PSDynDNS.ps1 -Uninstall

# Remove everything
.\Install-PSDynDNS.ps1 -Uninstall -Purge
```

Installation from GitHub will use a stable Release asset and digest. While the repository is private and no public Release exists, use `-LocalClientPath` on test systems.

## Runtime

```powershell
.\PSDynDNS.ps1 [-ConfigPath C:\path\config.json] [-ForceDnsUpdate]
```

No command-line credentials. One config per process. Multiple configurations can eventually use separate task names and storage, but the installer currently targets exactly one task.

## Security considerations

- A script writable by LOCAL SERVICE must **never** be manually executed with admin privileges.
- Restrict the installation directory itself: write access to executable paths must not be granted to ordinary users or to the general LOCAL SERVICE identity.
- LocalMachine DPAPI is **not** a user isolation boundary: ACLs remain essential.
- The release SHA-256 reported by GitHub detects transfer corruption but does not independently authenticate the release publisher.
- Configuration can change the Basic Auth destination; protect it accordingly.
- A first self-updater implementation exists, but it is not yet validated on target Windows systems. Keep `AutoUpdate` false until hash validation, cross-process replacement and recovery tests have passed.
- The initial ACL/SID implementation requires verification on real Windows, including state/log creation and delete/rename behavior.

## CI

`.github/workflows/ci.yml` runs syntax checking, Pester tests and produces a versioned ZIP artifact on Windows. Release publishing is deliberately manual and **not** enabled in early development.

## License

MIT.

## Release checklist

Do **not** merge to main or publish an installable release until the Windows PowerShell 5.1 workflow is green and the administrator has tested LOCAL SERVICE ACLs, DPAPI, task scheduling, DNS requests, state recovery and cross-process self-update on an isolated Windows VM. A passing parser-only CI check is not sufficient for Windows security behavior.
