<p align="center">
  <img src="banner.svg" alt="ForkOff Banner" width="100%"/>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Bash-4EAA25?style=flat-square&logo=gnubash&logoColor=white" alt="Bash"/>
  <img src="https://img.shields.io/badge/systemd-494949?style=flat-square&logo=linux&logoColor=white" alt="systemd"/>
  <img src="https://img.shields.io/badge/Git-F05032?style=flat-square&logo=git&logoColor=white" alt="Git"/>
  <img src="https://img.shields.io/badge/GitHub_API-181717?style=flat-square&logo=github&logoColor=white" alt="GitHub API"/>
  <img src="https://img.shields.io/badge/Platform-Linux-FCC624?style=flat-square&logo=linux&logoColor=black" alt="Platform"/>
  <img src="https://img.shields.io/badge/Schedule-Daily-58a6ff?style=flat-square&logo=clockify&logoColor=white" alt="Schedule"/>
  <img src="https://img.shields.io/badge/Retention-366_days-8b5cf6?style=flat-square" alt="Retention"/>
  <img src="https://img.shields.io/badge/License-MIT-blue?style=flat-square" alt="License"/>
  <img src="https://img.shields.io/badge/Author-SkyzFallin-ce9178?style=flat-square&logo=github&logoColor=white" alt="Author"/>
</p>

# ForkOff — GitHub Mirror Backup

By [SkyzFallin](https://github.com/SkyzFallin) | [GitHub Repo](https://github.com/SkyzFallin/ForkOff)

Automated daily mirror backup of all your GitHub repositories.

Under GitHub's [Terms of Service](https://docs.github.com/en/site-policy/github-terms/github-terms-of-service), they hold a broad license to your content and can suspend or terminate your account at any time, for any reason, with or without notice. If that happens, every repo, commit, branch, and tag you've ever pushed is gone — unless you have an independent backup. ForkOff runs daily, keeps a full mirror of everything, and produces timestamped audit logs so you can prove it.

## Features

- Auto-discovers all repos (public + private) via the GitHub API
- New repos picked up automatically — no manual config needed
- `git clone --mirror` for full history, branches, tags, and refs
- Interactive installer with TUI repo selector to exclude forks or repos you don't want
- JSON audit reports per run (timestamps, pass/fail, repo count, sizes) — proof of backup for SLAs, compliance, and audits
- Integrity spot-checks via `git fsck` on random mirrors each run
- Timestamped logs retained for 366 days — over a full year of verifiable backup history
- Optional desktop error notification file for visible alerting
- Runs as a systemd timer — set it and forget it

## Quick Start

```bash
git clone https://github.com/YourUser/ForkOff.git
cd ForkOff
sudo bash install.sh
```

The installer will walk you through:

1. GitHub username
2. Personal Access Token (tested before proceeding)
3. Interactive repo selector — arrow keys to navigate, space to toggle exclusions, enter to confirm
4. Backup directory (default: `/opt/github-backups`)
5. Desktop error file path (optional)
6. Daily backup time (default: 3:00 AM UTC)

Press enter at any prompt to accept the default value.

## Requirements

- Linux with systemd
- `git`, `curl`, `jq` (installer will install these via apt if missing)
- GitHub Personal Access Token (classic) with `repo` scope — [create one here](https://github.com/settings/tokens):
  1. Click **Generate new token** → **Generate new token (classic)**
  2. Give it a name (e.g. `forkoff-backup`)
  3. Check the **`repo`** checkbox (full control of private repositories) — no other scopes needed
  4. Click **Generate token** and copy it — you won't see it again

## Directory Structure

```
/opt/github-backups/           # (or your chosen path)
├── mirrors/                   # Bare git mirrors (RepoName.git/)
├── logs/                      # Per-run logs (90-day retention)
│   └── backup-YYYYMMDD-HHMMSS.log
└── reports/                   # JSON audit reports (90-day retention)
    └── backup-report-YYYYMMDD.json

/etc/github-backup/
└── github-backup.conf         # Configuration (no secrets)

/etc/systemd/system/
├── github-backup.service      # Service unit
├── github-backup.timer        # Daily timer
└── github-backup.service.d/
    └── token.env              # PAT (chmod 600, root-only)
```

## Operations

| Action | Command |
|---|---|
| Run backup now | `sudo systemctl start github-backup.service` |
| Watch logs live | `sudo journalctl -u github-backup -f` |
| Check timer | `systemctl list-timers github-backup.timer` |
| Last backup report | `sudo github-backup --status` |
| Verify all mirrors | `sudo github-backup --verify` |
| Restore a repo locally | `git clone /opt/github-backups/mirrors/RepoName.git` |

## Configuration

To change any setting, just run the installer again — it will detect the existing installation and let you update your config. You can also edit the config file directly:

```ini
GITHUB_USER="your-username"
BACKUP_DIR="/opt/github-backups/mirrors"
LOG_DIR="/opt/github-backups/logs"
REPORT_DIR="/opt/github-backups/reports"
LOCK_FILE="/tmp/github-backup.lock"
MAX_LOG_DAYS=366
ERROR_FILE=""                    # Optional: /home/user/Desktop/BACKUP_ERROR.txt
EXCLUDE_REPOS="some-fork another-repo"  # Space-separated repo names to skip
```

## Audit Trail / Proof of Backups

Every backup run produces two timestamped artifacts:

- **Log file** (`logs/backup-YYYYMMDD-HHMMSS.log`) — full output of every clone/update operation
- **JSON report** (`reports/backup-report-YYYYMMDD.json`) — structured summary with start/end times, hostname, pass/fail per repo, sizes, and branch counts

These serve as verifiable proof that backups are running daily. Use them for compliance, client SLAs, or audits. Reports are retained for 366 days by default (configurable via `MAX_LOG_DAYS`).

Quick check:
```bash
# Show the latest report
sudo github-backup --status

# List all report dates
ls /opt/github-backups/reports/
```

## Restore Procedure

Push a mirror to a new remote:

```bash
cd /opt/github-backups/mirrors/RepoName.git
git remote set-url origin git@new-host.com:user/RepoName.git
git push --mirror
```

Clone locally for development:

```bash
git clone /opt/github-backups/mirrors/RepoName.git RepoName
cd RepoName
git remote set-url origin git@github.com:YourUser/RepoName.git
```

## Token Management

The PAT is stored in a systemd environment file (`chmod 600`, root-only). It is only loaded into memory when the backup service runs.

**Rotate token:**
```bash
echo 'GITHUB_TOKEN=ghp_newtoken' | sudo tee /etc/systemd/system/github-backup.service.d/token.env > /dev/null
sudo chmod 600 /etc/systemd/system/github-backup.service.d/token.env
sudo systemctl daemon-reload
```

## No Encryption

Backed-up mirrors are stored as plain git repos on disk — nothing is encrypted. This tool is meant to be simple and stay simple. If you have sensitive files in your repos, encrypt them yourself before pushing or use full-disk encryption on the backup volume.

## What Does NOT Get Backed Up

Git mirrors cover all code, branches, tags, and history. These GitHub-only items require a separate export:

- Issues, Pull Requests, Discussions
- GitHub Actions run history
- Releases (binary assets)
- Repo settings, webhooks, deploy keys

GitHub's built-in account export covers these: **Settings > Archives > Export account data**.

## Uninstall

```bash
sudo systemctl stop github-backup.timer
sudo systemctl disable github-backup.timer
sudo rm /etc/systemd/system/github-backup.service
sudo rm /etc/systemd/system/github-backup.timer
sudo rm -rf /etc/systemd/system/github-backup.service.d
sudo rm -rf /etc/github-backup
sudo rm /usr/local/bin/github-backup
sudo systemctl daemon-reload
# Optionally remove backup data:
# sudo rm -rf /opt/github-backups
```

## License

MIT — Made by [SkyzFallin](https://github.com/SkyzFallin)
