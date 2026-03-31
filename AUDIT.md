# AUDIT.md — ForkOff

Last reviewed: 2026-03-31

---

## Code Quality

- [x] ShellCheck clean (`github-backup.sh`, `install.sh`)
- [x] `set -euo pipefail` enforced
- [x] `umask 077` set at script start
- [x] Lock directory prevents overlapping runs (atomic `mkdir`, no `/tmp` symlink risk)
- [x] Stale lock detection via PID file (recovers from SIGKILL)
- [x] Log rotation implemented (366-day default)
- [x] JSON audit reports generated per run (UTC-timestamped to avoid same-day overwrites)
- [x] `shuf` dependency checked at startup
- [x] Disk space pre-check before backup (configurable via `MIN_FREE_MB`)
- [x] API rate limit handling with automatic backoff (capped at 900s)
- [x] Parallel cloning with FIFO semaphore (configurable via `MAX_PARALLEL`)
- [x] Per-job log isolation prevents interleaving during parallel runs
- [x] Subshell semaphore release via EXIT trap (prevents token leak on crash)
- [x] Post-clone ref validation (detects empty or corrupted mirrors)
- [x] Partial clone cleanup on failure (rm -rf before returning)
- [x] Restore test automation (`--test-restore` flag and `RESTORE_TEST` config)
- [x] `--help` flag with usage info; unknown flags rejected with error
- [x] `--test-notify` flag for notification channel testing
- [x] Elapsed time shown in backup summary
- [x] Git network timeouts (`GIT_HTTP_LOW_SPEED_LIMIT/TIME`) prevent hung clones
- [x] `MAX_PARALLEL` and `MIN_FREE_MB` validated as positive integers
- [x] `gh api --paginate` output merged via `jq -s 'add'` for valid JSON
- [x] Metadata export bounded by `timeout 300`
- [x] API calls retry on transient failure (`--retry 3 --retry-delay 5`)
- [x] `gh auth status` validated before metadata export
- [ ] Unit tests for fetch/mirror/verify functions
- [ ] CI lint via GitHub Actions

## Security

- [x] PAT stored in systemd env file (`chmod 600`, root-only)
- [x] Token never appears in process arguments (`GIT_ASKPASS` for git, `-K` config file for curl)
- [x] No secrets in repo or backup directory
- [x] Token injected at runtime only via `EnvironmentFile`
- [x] Config file validated as root-owned AND mode 600 before sourcing
- [x] Backup directory permissions hardened (`chmod 700`)
- [x] Lock uses atomic `mkdir` under backup dir (no `/tmp` symlink risk)
- [x] No `eval` with user input (`printf -v` used instead)
- [x] Installer validates schedule input format (strict HH:MM, retry loop)
- [x] Config values escaped with `printf %q` during generation (prevents shell injection)
- [x] Installer sources token.env via `grep` extraction (no `source` code execution)
- [x] Installer validates config ownership before sourcing
- [x] Parallel temp dir and askpass script created under BACKUP_DIR (mode 700, not `/tmp`)
- [x] JSON payloads built with `jq -nc` (no string interpolation)
- [x] Webhook/ntfy/healthcheck failures logged but never abort backup
- [x] Desktop error file feature removed (eliminated writes to user-controlled paths)
- [x] Repo names validated against `^[a-zA-Z0-9._-]+$` (path traversal prevention)
- [x] Clone URLs validated to require `https://github.com/` prefix (blocks `ext::` RCE)
- [x] Fixed-string grep (`grep -qxF`) for repo name matching (no regex metachar issues)
- [x] Systemd service hardened (ProtectSystem, PrivateTmp, NoNewPrivileges, etc.)
- [x] Signal handling: cleanup trap on EXIT, TERM, INT with child process kill
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
