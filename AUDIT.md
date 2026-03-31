# AUDIT.md — ForkOff

Last reviewed: 2026-03-30

---

## Code Quality

- [x] ShellCheck clean (`github-backup.sh`, `install.sh`)
- [x] `set -euo pipefail` enforced
- [x] Lock file prevents overlapping runs
- [x] Log rotation implemented (90-day default)
- [x] JSON audit reports generated per run
- [ ] Unit tests for fetch/mirror/verify functions
- [ ] CI lint via GitHub Actions

## Security

- [x] PAT stored in systemd env file (`chmod 600`, root-only)
- [x] Token stripped from stored remote URLs after clone
- [x] No secrets in repo or backup directory
- [x] Token injected at runtime only via `EnvironmentFile`
- [ ] PAT scoped as fine-grained (read-only, owner-only)
- [ ] Backup directory permissions hardened (`chmod 700`)

## GitHub Repo

- [x] SVG banner
- [x] README with Quick Start, Operations, Restore, Uninstall
- [x] AUDIT.md
- [x] .gitignore
- [x] LICENSE (MIT)
- [x] Example config file included
- [ ] Tagged release (v1.0)
- [ ] GPG-signed commits

## Feature Backlog

- [ ] Fix systemd service execution (curl failing under systemd — debug in progress)
- [ ] Email/webhook notification on backup failure
- [ ] Support for GitHub orgs (not just user repos)
- [ ] Backup GitHub Issues/PRs/Releases via `gh api` export
- [ ] Configurable backup frequency (not just daily)
- [ ] Disk space check before cloning large repos
- [ ] Summary dashboard (HTML report from JSON reports)
- [ ] Support for GitLab/Bitbucket mirrors
- [ ] Dry-run mode (`--dry-run`)
- [ ] Restore helper script (`--restore RepoName`)
