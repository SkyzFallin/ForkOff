# AUDIT.md — ForkOff

Last reviewed: 2026-03-31

---

## Code Quality

- [x] ShellCheck clean (`github-backup.sh`, `install.sh`)
- [x] `set -euo pipefail` enforced
- [x] Lock directory prevents overlapping runs (atomic `mkdir`, no `/tmp` symlink risk)
- [x] Log rotation implemented (366-day default)
- [x] JSON audit reports generated per run (timestamped to avoid same-day overwrites)
- [x] `shuf` dependency checked at startup
- [x] Disk space pre-check before backup (configurable via `MIN_FREE_MB`)
- [x] API rate limit handling with automatic backoff
- [x] Parallel cloning with FIFO semaphore (configurable via `MAX_PARALLEL`)
- [x] Per-job log isolation prevents interleaving during parallel runs
- [x] Post-clone ref validation (detects empty or corrupted mirrors)
- [x] Restore test automation (`--test-restore` flag and `RESTORE_TEST` config)
- [ ] Unit tests for fetch/mirror/verify functions
- [ ] CI lint via GitHub Actions

## Security

- [x] PAT stored in systemd env file (`chmod 600`, root-only)
- [x] Token never appears in process arguments (`GIT_ASKPASS` pattern)
- [x] No secrets in repo or backup directory
- [x] Token injected at runtime only via `EnvironmentFile`
- [x] Config file validated as root-owned before sourcing
- [x] Config file permissions hardened (`chmod 600`, `root:root`)
- [x] Backup directory permissions hardened (`chmod 700`)
- [x] Lock uses atomic `mkdir` under backup dir (no `/tmp` symlink risk)
- [x] No `eval` with user input (`printf -v` used instead)
- [x] Home directory detection uses `getent` (no `eval echo ~`)
- [x] Installer validates schedule input format (strict HH:MM)
- [x] Parallel temp dir created via `mktemp -d` with mode 700
- [x] JSON payloads built with `jq -nc` (no string interpolation)
- [x] Webhook/ntfy/healthcheck failures logged but never abort backup
- [x] Desktop error file feature removed (eliminated writes to user-controlled paths)
- [ ] PAT scoped as fine-grained (read-only, owner-only)

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
- [x] Webhook/ntfy notification on backup failure
- [ ] Support for GitHub orgs (not just user repos)
- [x] Backup GitHub Issues/PRs/Releases via `gh api` export
- [ ] Configurable backup frequency (not just daily)
- [ ] Summary dashboard (HTML report from JSON reports)
- [ ] Support for GitLab/Bitbucket mirrors
- [ ] Dry-run mode (`--dry-run`)
- [ ] Restore helper script (`--restore RepoName`)
