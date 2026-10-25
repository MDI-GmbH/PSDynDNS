# AGENTS.md — PSDynDNS

## Project

PSDynDNS is a lightweight DynDNS2 client for Windows Server 2016+ and Windows 10/11.

- Windows PowerShell 5.1 compatibility is mandatory; maintain PowerShell 7 support.
- Keep the runtime dependency-free. Prefer built-in PowerShell and .NET APIs.
- Prioritize security, reliability, backward compatibility, and simplicity.
- Read `README.md` and relevant source/tests before modifying code. Avoid unnecessary abstractions and unrelated refactoring.

## Development

- Develop on `dev` or a feature branch based on `dev`. Never push directly to `main`.
- Check branch state before editing. Never force-push or rewrite shared history.
- Change code only when requested. Create PRs when requested; never merge, tag, or publish releases without explicit authorization.
- Preserve existing behavior and public interfaces unless changes are intentional.
- Keep source comments, documentation, and commit messages in English.

## Security

- Preserve `LOCAL SERVICE`, task-specific NTFS permissions, and DPAPI secret protection.
- Never expose credentials, customer data, or real customer IP addresses.
- DNS verification must fail safely: configured resolvers first, Windows DNS fallback only on lookup failures. Resolver disagreement must abort immediately; never mix resolver sources.
- Preserve download integrity checks, safe replacement, backups, and rollback behavior.
- Never silently alter configuration or secrets during client updates.
- Preserve scheduled-task repetition, delayed startup execution, and overlap protection.

## Testing & CI

- Add meaningful Pester tests for new behavior, bug fixes, and relevant failure paths.
- Test Windows PowerShell 5.1 and PowerShell 7; maintain at least 75% coverage in both.
- Never weaken tests or coverage requirements to obtain a passing build.
- Use synthetic data and mocked network responses. Run destructive integration tests only on disposable Windows runners.
- Keep `.github/workflows/ci.yml` as the shared CI definition, including release validation.
- Investigate actual CI logs and verify all required jobs before claiming success or creating a requested PR.

## Delivery

Update `README.md` for user-visible changes. Summarize changes, test results, coverage impact, and remaining limitations. Clearly distinguish verified results from assumptions.
