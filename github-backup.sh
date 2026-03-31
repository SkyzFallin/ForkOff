#!/usr/bin/env bash
# =============================================================================
# ForkOff — GitHub Mirror Backup
# =============================================================================
# Auto-discovers all repos (public + private) for a GitHub user, mirrors them
# locally, and maintains a verifiable audit log of every backup run.
# https://github.com/SkyzFallin/ForkOff
#
# Configuration: /etc/github-backup/github-backup.conf
# Token: loaded via systemd LoadCredential (falls back to GITHUB_TOKEN env var)
#
# Usage:
#   github-backup                # Run backup
#   github-backup --status       # Show last backup report
#   github-backup --verify       # Verify all mirror integrity
#   github-backup --test-restore # Clone a random mirror and verify HEAD
#   github-backup --test-notify  # Send test notification to all channels
#   github-backup --help         # Show this help
#
# Environment:
#   GITHUB_BACKUP_CONF=/path/to/alt.conf   Override config file location
#   GITHUB_TOKEN=ghp_...                   Token (normally from systemd)
# =============================================================================

set -euo pipefail
umask 077

# --- Load Configuration ------------------------------------------------------
CONFIG_FILE="${GITHUB_BACKUP_CONF:-/etc/github-backup/github-backup.conf}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found: $CONFIG_FILE"
    echo "Run install.sh or copy github-backup.conf.example to $CONFIG_FILE"
    exit 1
fi

# Validate config file ownership and permissions before sourcing
if [[ "$(stat -c '%u' "$CONFIG_FILE" 2>/dev/null)" != "0" ]]; then
    echo "ERROR: Config file must be owned by root: $CONFIG_FILE"
    echo "Fix with: sudo chown root:root $CONFIG_FILE"
    exit 1
fi

config_perms=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null)
if [[ "$config_perms" != "600" ]]; then
    echo "ERROR: Config file must have mode 600: $CONFIG_FILE (found ${config_perms})"
    echo "Fix with: sudo chmod 600 $CONFIG_FILE"
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Convert space-separated exclude list to array
read -ra EXCLUDE_REPOS_ARRAY <<< "${EXCLUDE_REPOS:-}"

# Defaults for optional config keys (backward compat with old configs)
WEBHOOK_URL="${WEBHOOK_URL:-}"
WEBHOOK_ON_SUCCESS="${WEBHOOK_ON_SUCCESS:-false}"
NTFY_TOPIC="${NTFY_TOPIC:-}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"
BACKUP_METADATA="${BACKUP_METADATA:-false}"
MAX_PARALLEL="${MAX_PARALLEL:-4}"
MIN_FREE_MB="${MIN_FREE_MB:-1024}"
RESTORE_TEST="${RESTORE_TEST:-false}"

# Validate numeric config values
[[ "$MAX_PARALLEL" =~ ^[1-9][0-9]*$ ]] || MAX_PARALLEL=4
[[ "$MIN_FREE_MB" =~ ^[0-9]+$ ]]    || MIN_FREE_MB=1024
[[ "$MAX_LOG_DAYS" =~ ^[1-9][0-9]*$ ]] || MAX_LOG_DAYS=366

# Git network timeouts — prevent hung clones from blocking semaphore slots
export GIT_HTTP_LOW_SPEED_LIMIT=1000   # bytes/sec
export GIT_HTTP_LOW_SPEED_TIME=60      # abort if below limit for this many seconds

# --- Functions ---------------------------------------------------------------

log() {
    local level="$1"; shift
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [${level}] $*" | tee -a "$LOG_FILE"
}

# --- Notification functions ---
# Each guards on its own config key and never aborts the backup on failure.
# curl headers are passed via a temp config file to avoid leaking values in /proc/cmdline.

send_webhook() {
    [[ -n "$WEBHOOK_URL" ]] || return 0
    local status="$1" total="$2" succeeded="$3" failed="$4" failed_list="$5"
    local payload
    payload=$(jq -nc \
        --arg status "$status" \
        --argjson total "$total" \
        --argjson succeeded "$succeeded" \
        --argjson failed "$failed" \
        --arg failed_repos "$failed_list" \
        --arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg hostname "$(hostname)" \
        --arg user "${GITHUB_USER}" \
        '{
            event: "backup_complete",
            status: $status,
            user: $user,
            hostname: $hostname,
            timestamp: $timestamp,
            total: $total,
            succeeded: $succeeded,
            failed: $failed,
            failed_repos: $failed_repos
        }')
    if ! curl -sf -m 10 -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$WEBHOOK_URL" >/dev/null 2>&1; then
        log "WARN" "Webhook notification failed (URL: ${WEBHOOK_URL})"
    fi
}

send_ntfy() {
    [[ -n "$NTFY_TOPIC" ]] || return 0
    local status="$1" message="$2"
    local priority title tags
    if [[ "$status" == "SUCCESS" ]]; then
        priority="2"
        title="ForkOff — Backup OK"
        tags="white_check_mark"
    else
        priority="5"
        title="ForkOff — Backup FAILED"
        tags="warning"
    fi
    if ! curl -sf -m 10 -X POST \
        -H "Title: ${title}" \
        -H "Priority: ${priority}" \
        -H "Tags: ${tags}" \
        -d "$message" \
        "$NTFY_TOPIC" >/dev/null 2>&1; then
        log "WARN" "ntfy notification failed (topic: ${NTFY_TOPIC})"
    fi
}

ping_healthcheck() {
    [[ -n "$HEALTHCHECK_URL" ]] || return 0
    if ! curl -sf -m 10 "$HEALTHCHECK_URL" >/dev/null 2>&1; then
        log "WARN" "Healthcheck ping failed (URL: ${HEALTHCHECK_URL})"
    fi
}

# --- Notification helper: sends both webhook and ntfy ---
notify() {
    local status="$1" total="$2" succeeded="$3" failed="$4" failed_list="$5" message="$6"
    if [[ "$status" == "SUCCESS" ]]; then
        [[ "$WEBHOOK_ON_SUCCESS" == "true" ]] && send_webhook "$status" "$total" "$succeeded" "$failed" "$failed_list"
        send_ntfy "$status" "$message"
        ping_healthcheck
    else
        send_webhook "$status" "$total" "$succeeded" "$failed" "$failed_list"
        send_ntfy "$status" "$message"
    fi
}

cleanup() {
    cleanup_git_askpass
    if [[ -n "${PARALLEL_TMPDIR:-}" ]]; then
        rm -rf "$PARALLEL_TMPDIR" 2>/dev/null || true
    fi
    if [[ -n "${LOCK_DIR:-}" ]]; then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
    # Kill any remaining child processes from parallel jobs
    kill 0 2>/dev/null || true
}

check_dependencies() {
    local missing=()
    for cmd in git curl jq shuf; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ "$BACKUP_METADATA" == "true" ]]; then
        if ! command -v gh &>/dev/null; then
            missing+=("gh (required for BACKUP_METADATA)")
        elif ! gh auth status &>/dev/null; then
            echo "ERROR: gh CLI is installed but not authenticated."
            echo "Run: gh auth login"
            exit 1
        fi
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing required tools: ${missing[*]}"
        echo "Install with: sudo apt-get install <package>"
        exit 1
    fi
}

setup_git_askpass() {
    local token="$1"
    # Create a temporary script that prints the token for git authentication.
    # This avoids embedding the token in clone/fetch URLs where it would be
    # visible in /proc/*/cmdline to other local users.
    # Created under BACKUP_DIR (mode 700) rather than /tmp for defense in depth.
    GIT_ASKPASS_SCRIPT=$(mktemp "${BACKUP_DIR}/.git-askpass-XXXXXX")
    chmod 700 "$GIT_ASKPASS_SCRIPT"
    printf '#!/usr/bin/env bash\necho %q\n' "$token" > "$GIT_ASKPASS_SCRIPT" || {
        echo "ERROR: Failed to write git askpass script" >&2
        exit 1
    }
    export GIT_ASKPASS="$GIT_ASKPASS_SCRIPT"
    export GIT_TERMINAL_PROMPT=0
}

cleanup_git_askpass() {
    [[ -n "${GIT_ASKPASS_SCRIPT:-}" ]] && rm -f "$GIT_ASKPASS_SCRIPT"
}

get_token() {
    local cred_file="${CREDENTIALS_DIRECTORY:-}/github-token"
    if [[ -n "${CREDENTIALS_DIRECTORY:-}" && -f "$cred_file" ]]; then
        cat "$cred_file"
    elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
        echo "$GITHUB_TOKEN"
    else
        log "ERROR" "No GitHub token found."
        log "ERROR" "Expected systemd credential 'github-token' or GITHUB_TOKEN env var."
        exit 1
    fi
}

# Authenticate curl to the GitHub API without exposing the token in process args.
# Writes a curl config file with the auth header and passes it via -K.
gh_curl() {
    local token="$1"; shift
    local curl_cfg
    curl_cfg=$(mktemp "${BACKUP_DIR}/.curl-cfg-XXXXXX")
    chmod 600 "$curl_cfg"
    printf -- '-H "Authorization: token %s"\n' "$token" > "$curl_cfg"
    curl -sf -K "$curl_cfg" "$@"
    local rc=$?
    rm -f "$curl_cfg"
    return $rc
}

is_excluded() {
    local name="$1"
    for excluded in "${EXCLUDE_REPOS_ARRAY[@]}"; do
        [[ "$name" == "$excluded" ]] && return 0
    done
    return 1
}

fetch_all_repos() {
    local token="$1"
    local page=1
    local all_repos=()

    while true; do
        local response header_file
        header_file=$(mktemp)
        response=$(gh_curl "$token" -D "$header_file" \
            -H "Accept: application/vnd.github.v3+json" \
            --retry 3 --retry-delay 5 \
            "https://api.github.com/user/repos?per_page=100&page=${page}&affiliation=owner" 2>&1) || {
            log "ERROR" "GitHub API request failed (page ${page}): ${response}"
            rm -f "$header_file"
            return 1
        }

        # Respect GitHub API rate limits
        local remaining
        remaining=$(grep -i '^x-ratelimit-remaining:' "$header_file" | tr -d '\r' | awk '{print $2}')
        if [[ -n "$remaining" && "$remaining" -le 1 ]]; then
            local reset_epoch
            reset_epoch=$(grep -i '^x-ratelimit-reset:' "$header_file" | tr -d '\r' | awk '{print $2}')
            # Fallback if reset header is missing
            [[ -n "$reset_epoch" ]] || reset_epoch=$(( $(date +%s) + 3600 ))
            local now_epoch
            now_epoch=$(date +%s)
            local wait_secs=$(( reset_epoch - now_epoch + 2 ))
            if [[ "$wait_secs" -gt 0 && "$wait_secs" -lt 900 ]]; then
                log "WARN" "API rate limit nearly exhausted. Sleeping ${wait_secs}s until reset..."
                sleep "$wait_secs"
            fi
        fi
        rm -f "$header_file"

        local count
        count=$(echo "$response" | jq 'length' 2>/dev/null) || {
            log "ERROR" "Malformed API response on page ${page}"
            return 1
        }
        [[ "$count" -eq 0 ]] && break

        while IFS='|' read -r name clone_url private; do
            # Validate repo name — reject anything that could cause path traversal
            if [[ ! "$name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
                log "ERROR" "Invalid repo name rejected: ${name}"
                continue
            fi
            # Validate clone URL — must be HTTPS GitHub
            if [[ ! "$clone_url" =~ ^https://github\.com/ ]]; then
                log "ERROR" "Rejected non-GitHub clone URL for ${name}: ${clone_url}"
                continue
            fi
            all_repos+=("${name}|${clone_url}|${private}")
        done < <(echo "$response" | jq -r '.[] | "\(.name)|\(.clone_url)|\(.private)"')

        ((page++)) || true
    done

    printf '%s\n' "${all_repos[@]}"
}

mirror_repo() {
    local name="$1"
    local clone_url="$2"
    local repo_dir="${BACKUP_DIR}/${name}.git"

    if [[ -d "$repo_dir" ]]; then
        log "INFO" "Updating mirror: ${name}"
        # GIT_ASKPASS handles authentication — no token in URLs or process args
        if (cd "$repo_dir" && git remote update --prune) &>> "$LOG_FILE"; then
            log "INFO" "Updated: ${name}"
            return 0
        else
            log "WARN" "Update failed for ${name}, re-cloning..."
            rm -rf "$repo_dir"
        fi
    fi

    log "INFO" "Cloning mirror: ${name}"
    # GIT_ASKPASS provides credentials — clone URL stays clean
    if git clone --mirror "$clone_url" "$repo_dir" &>> "$LOG_FILE"; then
        log "INFO" "Cloned: ${name}"
        return 0
    else
        log "ERROR" "Failed to clone: ${name}"
        # Clean up partial clone
        rm -rf "$repo_dir"
        return 1
    fi
}

validate_refs() {
    local repo_dir="$1"
    local name
    name=$(basename "$repo_dir" .git)
    if ! git -C "$repo_dir" show-ref --head -q 2>/dev/null; then
        log "WARN" "No refs found in mirror: ${name} (empty or corrupted)"
        return 1
    fi
    return 0
}

verify_mirror() {
    local repo_dir="$1"
    local name
    name=$(basename "$repo_dir" .git)

    if ! git -C "$repo_dir" fsck --no-dangling --quiet &>/dev/null; then
        log "WARN" "Integrity check failed: ${name}"
        return 1
    fi
    return 0
}

export_metadata() {
    local name="$1"
    local meta_dir="${BACKUP_DIR}/../metadata/${name}"
    mkdir -p "$meta_dir"
    chmod 700 "$meta_dir"

    local issues=0 pulls=0 releases=0

    # Issues (includes both open and closed)
    # gh api --paginate outputs one JSON array per page — merge with jq -s 'add'
    if timeout 300 gh api --paginate "repos/${GITHUB_USER}/${name}/issues?state=all&per_page=100" \
        2>/dev/null | jq -s 'add // []' > "${meta_dir}/issues.json"; then
        issues=$(jq 'length' "${meta_dir}/issues.json" 2>/dev/null || echo 0)
    else
        echo '[]' > "${meta_dir}/issues.json"
        log "WARN" "Metadata: failed to export issues for ${name}"
    fi

    # Pull requests (includes both open and closed)
    if timeout 300 gh api --paginate "repos/${GITHUB_USER}/${name}/pulls?state=all&per_page=100" \
        2>/dev/null | jq -s 'add // []' > "${meta_dir}/pulls.json"; then
        pulls=$(jq 'length' "${meta_dir}/pulls.json" 2>/dev/null || echo 0)
    else
        echo '[]' > "${meta_dir}/pulls.json"
        log "WARN" "Metadata: failed to export pulls for ${name}"
    fi

    # Releases
    if timeout 300 gh api --paginate "repos/${GITHUB_USER}/${name}/releases?per_page=100" \
        2>/dev/null | jq -s 'add // []' > "${meta_dir}/releases.json"; then
        releases=$(jq 'length' "${meta_dir}/releases.json" 2>/dev/null || echo 0)
    else
        echo '[]' > "${meta_dir}/releases.json"
        log "WARN" "Metadata: failed to export releases for ${name}"
    fi

    echo "${issues}|${pulls}|${releases}"
}

test_restore() {
    local mirrors=()
    while IFS= read -r d; do
        mirrors+=("$d")
    done < <(find "$BACKUP_DIR" -maxdepth 1 -name '*.git' -type d 2>/dev/null)

    if [[ ${#mirrors[@]} -eq 0 ]]; then
        echo "  No mirrors found to test."
        return 1
    fi

    local idx=$(( RANDOM % ${#mirrors[@]} ))
    local mirror="${mirrors[$idx]}"
    local name
    name=$(basename "$mirror" .git)
    local tmpdir
    tmpdir=$(mktemp -d)

    echo "  Testing restore: ${name}"
    if git clone "$mirror" "${tmpdir}/${name}" --quiet 2>/dev/null; then
        if git -C "${tmpdir}/${name}" rev-parse HEAD >/dev/null 2>&1; then
            echo "  [PASS] ${name} — clone OK, HEAD valid"
            rm -rf "$tmpdir"
            return 0
        else
            echo "  [FAIL] ${name} — clone OK, but HEAD missing"
            rm -rf "$tmpdir"
            return 1
        fi
    else
        echo "  [FAIL] ${name} — clone failed"
        rm -rf "$tmpdir"
        return 1
    fi
}

test_notify() {
    echo "Sending test notifications to all configured channels..."
    send_webhook "TEST" 0 0 0 ""
    send_ntfy "SUCCESS" "ForkOff test notification — if you see this, notifications are working."
    ping_healthcheck
    echo "Done. Check your webhook, ntfy, and healthcheck endpoints."
}

generate_report() {
    local start_time="$1"
    local total="$2"
    local succeeded="$3"
    local failed="$4"
    local new_repos="$5"
    local end_time
    end_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local report_file
    report_file="${REPORT_DIR}/backup-report-$(date -u '+%Y%m%d-%H%M%SZ').json"

    local total_size
    total_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)

    local repo_details="["
    local first=true
    for dir in "$BACKUP_DIR"/*.git; do
        [[ -d "$dir" ]] || continue
        local rname
        rname=$(basename "$dir" .git)
        local rsize
        rsize=$(du -sh "$dir" 2>/dev/null | cut -f1)
        local last_commit
        last_commit=$(git -C "$dir" log -1 --format='%ci' 2>/dev/null || echo "unknown")
        local branch_count
        branch_count=$(git -C "$dir" branch -a 2>/dev/null | wc -l) || branch_count=0

        [[ "$first" == "true" ]] && first=false || repo_details+=","
        repo_details+=$(jq -nc \
            --arg name "$rname" \
            --arg size "$rsize" \
            --arg last_commit "$last_commit" \
            --argjson branches "$branch_count" \
            '{name:$name, size:$size, last_commit:$last_commit, branches:$branches}')
    done
    repo_details+="]"

    jq -nc \
        --arg start "$start_time" \
        --arg end "$end_time" \
        --argjson total "$total" \
        --argjson succeeded "$succeeded" \
        --argjson failed "$failed" \
        --argjson new_repos "$new_repos" \
        --arg total_size "$total_size" \
        --arg hostname "$(hostname)" \
        --argjson repos "$repo_details" \
        '{
            backup_run: {
                start_time: $start,
                end_time: $end,
                hostname: $hostname,
                status: (if $failed == 0 then "SUCCESS" else "PARTIAL_FAILURE" end)
            },
            summary: {
                total_repos: $total,
                succeeded: $succeeded,
                failed: $failed,
                new_repos_discovered: $new_repos,
                total_backup_size: $total_size
            },
            repos: $repos
        }' > "$report_file"

    log "INFO" "Report saved: ${report_file}"
}

show_status() {
    local latest
    latest=$(ls -t "$REPORT_DIR"/backup-report-*.json 2>/dev/null | head -1)
    if [[ -z "$latest" ]]; then
        echo "No backup reports found."
        exit 1
    fi
    echo "=== Latest Backup Report ==="
    jq '.' "$latest"
}

show_help() {
    echo "ForkOff — GitHub Mirror Backup"
    echo ""
    echo "Usage: github-backup [OPTION]"
    echo ""
    echo "Options:"
    echo "  (none)           Run backup"
    echo "  --status         Show last backup report"
    echo "  --verify         Verify all mirror integrity"
    echo "  --test-restore   Clone a random mirror and verify HEAD"
    echo "  --test-notify    Send test notification to all channels"
    echo "  --help, -h       Show this help"
    echo ""
    echo "Configuration: ${CONFIG_FILE}"
    echo "Override with: GITHUB_BACKUP_CONF=/path/to/alt.conf github-backup"
}

verify_all() {
    echo "=== Verifying All Mirrors ==="
    local ok=0 bad=0
    for dir in "$BACKUP_DIR"/*.git; do
        [[ -d "$dir" ]] || continue
        local name
        name=$(basename "$dir" .git)
        if verify_mirror "$dir"; then
            echo "  [OK] ${name}"
            ((ok++)) || true
        else
            echo "  [FAIL] ${name} — INTEGRITY ERROR"
            ((bad++)) || true
        fi
    done
    echo ""
    echo "Results: ${ok} OK, ${bad} failed"
    [[ "$bad" -eq 0 ]] && exit 0 || exit 1
}

# --- Main --------------------------------------------------------------------

# Handle flags
case "${1:-}" in
    --status)       show_status; exit 0 ;;
    --verify)       verify_all; exit 0 ;;
    --test-restore) test_restore; exit $? ;;
    --test-notify)  test_notify; exit 0 ;;
    --help|-h)      show_help; exit 0 ;;
    --*)            echo "Unknown option: $1"; echo "Run: github-backup --help"; exit 1 ;;
esac

# Pre-flight
check_dependencies

# Setup directories with secure permissions
mkdir -p "$BACKUP_DIR" "$LOG_DIR" "$REPORT_DIR"
chmod 700 "$BACKUP_DIR" "$LOG_DIR" "$REPORT_DIR"

# Metadata directory (alongside mirrors)
if [[ "$BACKUP_METADATA" == "true" ]]; then
    mkdir -p "${BACKUP_DIR}/../metadata"
    chmod 700 "${BACKUP_DIR}/../metadata"
fi

# Log file for this run (UTC timestamp for consistency)
LOG_FILE="${LOG_DIR}/backup-$(date -u '+%Y%m%d-%H%M%SZ').log"

# Disk space pre-check
MIN_FREE_KB=$(( MIN_FREE_MB * 1024 ))
AVAIL_KB=$(df -Pk "$BACKUP_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
if [[ -n "$AVAIL_KB" && "$AVAIL_KB" -lt "$MIN_FREE_KB" ]]; then
    log "ERROR" "Low disk space on ${BACKUP_DIR}: $(( AVAIL_KB / 1024 )) MB free (need >= ${MIN_FREE_MB} MB)"
    notify "FAILURE" 0 0 0 "disk-space-abort" \
        "Backup aborted — low disk space: $(( AVAIL_KB / 1024 )) MB free (need >= ${MIN_FREE_MB} MB)"
    exit 1
fi

# Lock directory (atomic via mkdir — prevents race conditions and symlink attacks)
# PID recorded inside for stale lock detection
LOCK_DIR="${BACKUP_DIR}/.backup.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    # Check for stale lock
    if [[ -f "$LOCK_DIR/pid" ]]; then
        old_pid=$(cat "$LOCK_DIR/pid")
        if ! kill -0 "$old_pid" 2>/dev/null; then
            log "WARN" "Removing stale lock (PID $old_pid is gone)"
            rm -rf "$LOCK_DIR"
            mkdir "$LOCK_DIR" 2>/dev/null || {
                log "ERROR" "Could not acquire lock after stale removal: $LOCK_DIR"
                exit 1
            }
        else
            log "ERROR" "Another backup is already running (PID $old_pid, lock: $LOCK_DIR)"
            exit 1
        fi
    else
        log "ERROR" "Another backup is already running (lock: $LOCK_DIR)"
        echo "If no backup is running, remove the stale lock: rm -rf $LOCK_DIR"
        exit 1
    fi
fi
echo $$ > "$LOCK_DIR/pid"
trap cleanup EXIT TERM INT

START_TIME=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
log "INFO" "========== GitHub Backup Starting =========="
log "INFO" "User: ${GITHUB_USER}"
log "INFO" "Backup dir: ${BACKUP_DIR}"

# Get token
TOKEN=$(get_token)

# Set up GIT_ASKPASS so tokens never appear in process arguments
setup_git_askpass "$TOKEN"

# Discover repos
log "INFO" "Fetching repo list from GitHub API..."
REPOS=$(fetch_all_repos "$TOKEN") || {
    log "ERROR" "Failed to fetch repo list from GitHub API"
    notify "FAILURE" 0 0 0 "api-fetch-failed" \
        "Backup aborted — could not retrieve repo list from GitHub. Check token and network."
    exit 1
}
if [[ -z "$REPOS" ]]; then
    TOTAL_FETCHED=0
else
    TOTAL_FETCHED=$(echo "$REPOS" | grep -c . || true)
fi
log "INFO" "Found ${TOTAL_FETCHED} repositories from API"

# Track existing mirrors for new repo detection
EXISTING_MIRRORS=$(find "$BACKUP_DIR" -maxdepth 1 -name '*.git' -type d -printf '%f\n' 2>/dev/null | sed 's/\.git$//' | sort || true)
NEW_REPOS=0
SKIPPED=0

# --- Build job list (serial: exclusion checks, new-repo detection) ---
declare -a JOB_NAMES=()
declare -a JOB_URLS=()

while IFS='|' read -r name clone_url private; do
    [[ -z "$name" ]] && continue

    if is_excluded "$name"; then
        log "INFO" "Skipping excluded repo: ${name}"
        ((SKIPPED++)) || true
        continue
    fi

    # Fixed-string match to avoid regex metacharacter issues in repo names
    if ! echo "$EXISTING_MIRRORS" | grep -qxF "$name"; then
        log "INFO" "New repo discovered: ${name}"
        ((NEW_REPOS++)) || true
    fi

    visibility="public"
    [[ "$private" == "true" ]] && visibility="private"
    log "INFO" "Queued: ${name} (${visibility})"

    JOB_NAMES+=("$name")
    JOB_URLS+=("$clone_url")
done <<< "$REPOS"

JOB_COUNT=${#JOB_NAMES[@]}
log "INFO" "Jobs queued: ${JOB_COUNT} (parallel: ${MAX_PARALLEL})"

# --- Execute jobs in parallel via FIFO semaphore ---
PARALLEL_TMPDIR=$(mktemp -d "${BACKUP_DIR}/.parallel-XXXXXX")
chmod 700 "$PARALLEL_TMPDIR"
FIFO="${PARALLEL_TMPDIR}/sem"
mkfifo "$FIFO" || {
    log "ERROR" "Failed to create semaphore FIFO: ${FIFO}"
    exit 1
}
exec 3<>"$FIFO"
for ((i = 0; i < MAX_PARALLEL; i++)); do echo >&3; done

for ((j = 0; j < JOB_COUNT; j++)); do
    read -ru 3  # acquire semaphore slot
    (
        # Ensure semaphore token is always returned, even on crash
        trap 'echo >&3' EXIT

        job_log="${PARALLEL_TMPDIR}/job-${j}.log"
        result_file="${PARALLEL_TMPDIR}/result-${j}"

        # Override LOG_FILE for this subshell to prevent interleaving
        LOG_FILE="$job_log"

        name="${JOB_NAMES[$j]}"
        clone_url="${JOB_URLS[$j]}"

        log "INFO" "Processing: ${name}"

        if mirror_repo "$name" "$clone_url"; then
            if validate_refs "${BACKUP_DIR}/${name}.git"; then
                echo "OK" > "$result_file"
            else
                echo "FAIL ${name}" > "$result_file"
            fi
        else
            echo "FAIL ${name}" > "$result_file"
        fi

        # Metadata export (only on success)
        if [[ "${BACKUP_METADATA}" == "true" ]] && grep -q "^OK" "$result_file" 2>/dev/null; then
            meta_counts=$(export_metadata "$name" 2>>"$job_log")
            echo "META ${meta_counts}" >> "$result_file"
        fi
    ) &
done

wait
exec 3>&-

# --- Aggregate results ---
SUCCEEDED=0
FAILED=0
FAILED_LIST=""
META_ISSUES=0
META_PULLS=0
META_RELEASES=0

for ((j = 0; j < JOB_COUNT; j++)); do
    # Append per-job log to main log (preserves job order)
    [[ -f "${PARALLEL_TMPDIR}/job-${j}.log" ]] && cat "${PARALLEL_TMPDIR}/job-${j}.log" >> "$LOG_FILE"

    result_file="${PARALLEL_TMPDIR}/result-${j}"
    if [[ -f "$result_file" ]]; then
        first_line=$(head -1 "$result_file")
        if [[ "$first_line" == "OK" ]]; then
            ((SUCCEEDED++)) || true
        else
            ((FAILED++)) || true
            # Trim leading space from accumulated list
            local_name="${first_line#FAIL }"
            FAILED_LIST="${FAILED_LIST:+${FAILED_LIST}, }${local_name}"
        fi
        # Aggregate metadata counts
        meta_line=$(grep "^META " "$result_file" 2>/dev/null || true)
        if [[ -n "$meta_line" ]]; then
            IFS='|' read -r mi mp mr <<< "${meta_line#META }"
            META_ISSUES=$(( META_ISSUES + mi ))
            META_PULLS=$(( META_PULLS + mp ))
            META_RELEASES=$(( META_RELEASES + mr ))
        fi
    else
        # No result file = something went very wrong in the subshell
        ((FAILED++)) || true
        FAILED_LIST="${FAILED_LIST:+${FAILED_LIST}, }${JOB_NAMES[$j]}"
    fi
done

rm -rf "$PARALLEL_TMPDIR"
PARALLEL_TMPDIR=""

TOTAL=$((SUCCEEDED + FAILED))

# Post-backup integrity spot-check (random 3 repos)
log "INFO" "Running integrity spot-check..."
for dir in $(find "$BACKUP_DIR" -maxdepth 1 -name '*.git' -type d 2>/dev/null | shuf | head -3); do
    verify_mirror "$dir" || log "WARN" "Spot-check failed: $(basename "$dir" .git)"
done

# Generate report
generate_report "$START_TIME" "$TOTAL" "$SUCCEEDED" "$FAILED" "$NEW_REPOS"

# Metadata summary
if [[ "$BACKUP_METADATA" == "true" ]]; then
    log "INFO" "Metadata: ${META_ISSUES} issues, ${META_PULLS} PRs, ${META_RELEASES} releases"
fi

# Optional restore test
if [[ "$RESTORE_TEST" == "true" ]]; then
    log "INFO" "Running post-backup restore test..."
    if test_restore >> "$LOG_FILE" 2>&1; then
        log "INFO" "Restore test: PASS"
    else
        log "WARN" "Restore test: FAIL"
    fi
fi

# Rotate old logs (UTC filenames)
find "$LOG_DIR" -name "backup-*.log" -mtime +"${MAX_LOG_DAYS}" -delete 2>/dev/null
find "$REPORT_DIR" -name "backup-report-*.json" -mtime +"${MAX_LOG_DAYS}" -delete 2>/dev/null

# Summary
ELAPSED=$(( $(date +%s) - $(date -d "$START_TIME" +%s 2>/dev/null || echo 0) ))
log "INFO" "========== Backup Complete (${ELAPSED}s) =========="
log "INFO" "Total: ${TOTAL} | Success: ${SUCCEEDED} | Failed: ${FAILED} | Skipped: ${SKIPPED} | New: ${NEW_REPOS}"

if [[ -n "$FAILED_LIST" ]]; then
    log "ERROR" "Failed repos: ${FAILED_LIST}"
    notify "PARTIAL_FAILURE" "$TOTAL" "$SUCCEEDED" "$FAILED" "$FAILED_LIST" \
        "Backup completed with failures. Failed: ${FAILED_LIST} (${SUCCEEDED}/${TOTAL} succeeded)"
else
    notify "SUCCESS" "$TOTAL" "$SUCCEEDED" "$FAILED" "" \
        "Backup complete. ${SUCCEEDED}/${TOTAL} repos mirrored successfully."
fi

# Exit with error if any failures
[[ "$FAILED" -eq 0 ]] && exit 0 || exit 1
