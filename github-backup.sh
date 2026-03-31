#!/usr/bin/env bash
# =============================================================================
# ForkOff — GitHub Mirror Backup
# =============================================================================
# Auto-discovers all repos (public + private) for a GitHub user, mirrors them
# locally, and maintains a verifiable audit log of every backup run.
# https://github.com/SkyzFallin/ForkOff
#
# Configuration: /etc/github-backup/github-backup.conf
# Token: loaded via systemd EnvironmentFile (GITHUB_TOKEN env var)
#
# Usage:
#   github-backup              # Run backup
#   github-backup --status     # Show last backup report
#   github-backup --verify     # Verify all mirror integrity
# =============================================================================

set -euo pipefail

# --- Load Configuration ------------------------------------------------------
CONFIG_FILE="${GITHUB_BACKUP_CONF:-/etc/github-backup/github-backup.conf}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found: $CONFIG_FILE"
    echo "Run install.sh or copy github-backup.conf.example to $CONFIG_FILE"
    exit 1
fi

# Validate config file ownership before sourcing (must be root-owned)
if [[ "$(stat -c '%u' "$CONFIG_FILE" 2>/dev/null)" != "0" ]]; then
    echo "ERROR: Config file must be owned by root: $CONFIG_FILE"
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Convert space-separated exclude list to array
read -ra EXCLUDE_REPOS_ARRAY <<< "${EXCLUDE_REPOS:-}"

# --- Functions ---------------------------------------------------------------

log() {
    local level="$1"; shift
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [${level}] $*" | tee -a "$LOG_FILE"
}

desktop_error() {
    [[ -n "${ERROR_FILE:-}" ]] || return 0
    local msg="$1"
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local parent_dir
    parent_dir=$(dirname "$ERROR_FILE")
    [[ -d "$parent_dir" ]] || return 0
    if [[ -f "$ERROR_FILE" ]]; then
        echo "" >> "$ERROR_FILE"
        echo "--- ${timestamp} ---" >> "$ERROR_FILE"
        echo -e "$msg" >> "$ERROR_FILE"
    else
        cat > "$ERROR_FILE" << ERREOF
=== GitHub Backup Error ===
There was a backup error. Details below.

--- ${timestamp} ---
$(echo -e "$msg")
ERREOF
    fi
    # Set ownership to match parent directory
    local owner
    owner=$(stat -c '%U:%G' "$parent_dir" 2>/dev/null) || true
    [[ -n "$owner" ]] && chown "$owner" "$ERROR_FILE" 2>/dev/null || true
}

cleanup() {
    cleanup_git_askpass
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

check_dependencies() {
    local missing=()
    for cmd in git curl jq shuf; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing required tools: ${missing[*]}"
        exit 1
    fi
}

setup_git_askpass() {
    # Create a temporary script that prints the token for git authentication.
    # This avoids embedding the token in clone/fetch URLs where it would be
    # visible in /proc/*/cmdline to other local users.
    GIT_ASKPASS_SCRIPT=$(mktemp "${TMPDIR:-/tmp}/git-askpass-XXXXXX")
    chmod 700 "$GIT_ASKPASS_SCRIPT"
    printf '#!/usr/bin/env bash\necho "${GITHUB_TOKEN}"\n' > "$GIT_ASKPASS_SCRIPT"
    export GIT_ASKPASS="$GIT_ASKPASS_SCRIPT"
    export GIT_TERMINAL_PROMPT=0
}

cleanup_git_askpass() {
    [[ -n "${GIT_ASKPASS_SCRIPT:-}" ]] && rm -f "$GIT_ASKPASS_SCRIPT"
}

get_token() {
    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
        log "ERROR" "GITHUB_TOKEN environment variable is not set."
        log "ERROR" "Ensure the systemd EnvironmentFile is configured."
        exit 1
    fi
    echo "$GITHUB_TOKEN"
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
        local response http_code header_file
        header_file=$(mktemp)
        response=$(curl -sf -D "$header_file" \
            -H "Authorization: token ${token}" \
            -H "Accept: application/vnd.github.v3+json" \
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
            local now_epoch
            now_epoch=$(date +%s)
            local wait_secs=$(( reset_epoch - now_epoch + 2 ))
            if [[ "$wait_secs" -gt 0 && "$wait_secs" -lt 3700 ]]; then
                log "WARN" "API rate limit nearly exhausted. Sleeping ${wait_secs}s until reset..."
                sleep "$wait_secs"
            fi
        fi
        rm -f "$header_file"

        local count
        count=$(echo "$response" | jq 'length')
        [[ "$count" -eq 0 ]] && break

        while IFS='|' read -r name clone_url private; do
            all_repos+=("${name}|${clone_url}|${private}")
        done < <(echo "$response" | jq -r '.[] | "\(.name)|\(.clone_url)|\(.private)"')

        ((page++)) || true
    done

    printf '%s\n' "${all_repos[@]}"
}

mirror_repo() {
    local name="$1"
    local clone_url="$2"
    local token="$3"
    local repo_dir="${BACKUP_DIR}/${name}.git"

    if [[ -d "$repo_dir" ]]; then
        log "INFO" "Updating mirror: ${name}"
        # GIT_ASKPASS handles authentication — no token in URLs or process args
        if (cd "$repo_dir" && git remote update --prune) &>> "$LOG_FILE" 2>&1; then
            log "INFO" "Updated: ${name}"
            return 0
        else
            log "WARN" "Update failed for ${name}, re-cloning..."
            rm -rf "$repo_dir"
        fi
    fi

    log "INFO" "Cloning mirror: ${name}"
    # GIT_ASKPASS provides credentials — clone URL stays clean
    if git clone --mirror "$clone_url" "$repo_dir" &>> "$LOG_FILE" 2>&1; then
        log "INFO" "Cloned: ${name}"
        return 0
    else
        log "ERROR" "Failed to clone: ${name}"
        return 1
    fi
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

generate_report() {
    local start_time="$1"
    local total="$2"
    local succeeded="$3"
    local failed="$4"
    local new_repos="$5"
    local end_time
    end_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local report_file="${REPORT_DIR}/backup-report-$(date '+%Y%m%d-%H%M%S').json"

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
        branch_count=$(git -C "$dir" branch -a 2>/dev/null | wc -l)

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
    echo "$report_file"
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
    --status)  show_status; exit 0 ;;
    --verify)  verify_all; exit 0 ;;
esac

# Pre-flight
check_dependencies

# Setup directories with secure permissions
mkdir -p "$BACKUP_DIR" "$LOG_DIR" "$REPORT_DIR"
chmod 700 "$BACKUP_DIR" "$LOG_DIR" "$REPORT_DIR"

# Disk space pre-check (require at least 1 GB free)
AVAIL_KB=$(df -Pk "$BACKUP_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
if [[ -n "$AVAIL_KB" && "$AVAIL_KB" -lt 1048576 ]]; then
    log "ERROR" "Low disk space on ${BACKUP_DIR}: $(( AVAIL_KB / 1024 )) MB free (need >= 1 GB)"
    desktop_error "Backup aborted — low disk space on ${BACKUP_DIR}: $(( AVAIL_KB / 1024 )) MB free."
    exit 1
fi

# Log file for this run
LOG_FILE="${LOG_DIR}/backup-$(date '+%Y%m%d-%H%M%S').log"

# Lock directory (atomic via mkdir — prevents race conditions and symlink attacks)
LOCK_DIR="${BACKUP_DIR}/.backup.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [ERROR] Another backup is already running (lock: $LOCK_DIR)" | tee -a "$LOG_FILE"
    exit 1
fi
trap cleanup EXIT

START_TIME=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
log "INFO" "========== GitHub Backup Starting =========="
log "INFO" "User: ${GITHUB_USER}"
log "INFO" "Backup dir: ${BACKUP_DIR}"

# Get token
TOKEN=$(get_token)

# Set up GIT_ASKPASS so tokens never appear in process arguments
setup_git_askpass

# Discover repos
log "INFO" "Fetching repo list from GitHub API..."
REPOS=$(fetch_all_repos "$TOKEN") || {
    log "ERROR" "Failed to fetch repo list from GitHub API"
    desktop_error "API fetch failed — could not retrieve repo list from GitHub. Check token and network."
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
SUCCEEDED=0
FAILED=0
SKIPPED=0
FAILED_LIST=""

# Mirror each repo
while IFS='|' read -r name clone_url private; do
    [[ -z "$name" ]] && continue

    # Skip excluded repos
    if is_excluded "$name"; then
        log "INFO" "Skipping excluded repo: ${name}"
        ((SKIPPED++)) || true
        continue
    fi

    # Check if this is a new repo
    if ! echo "$EXISTING_MIRRORS" | grep -qx "$name"; then
        log "INFO" "New repo discovered: ${name}"
        ((NEW_REPOS++)) || true
    fi

    visibility="public"
    [[ "$private" == "true" ]] && visibility="private"
    log "INFO" "Processing: ${name} (${visibility})"

    if mirror_repo "$name" "$clone_url" "$TOKEN"; then
        ((SUCCEEDED++)) || true
    else
        ((FAILED++)) || true
        FAILED_LIST+=" ${name}"
    fi
done <<< "$REPOS"

TOTAL=$((SUCCEEDED + FAILED))

# Post-backup integrity spot-check (random 3 repos)
log "INFO" "Running integrity spot-check..."
for dir in $(find "$BACKUP_DIR" -maxdepth 1 -name '*.git' -type d 2>/dev/null | shuf | head -3); do
    verify_mirror "$dir" || log "WARN" "Spot-check failed: $(basename "$dir" .git)"
done

# Generate report
REPORT_FILE=$(generate_report "$START_TIME" "$TOTAL" "$SUCCEEDED" "$FAILED" "$NEW_REPOS")

# Rotate old logs
find "$LOG_DIR" -name "backup-*.log" -mtime +${MAX_LOG_DAYS} -delete 2>/dev/null
find "$REPORT_DIR" -name "backup-report-*.json" -mtime +${MAX_LOG_DAYS} -delete 2>/dev/null

# Summary
log "INFO" "========== Backup Complete =========="
log "INFO" "Total: ${TOTAL} | Success: ${SUCCEEDED} | Failed: ${FAILED} | Skipped: ${SKIPPED} | New: ${NEW_REPOS}"
[[ -n "$FAILED_LIST" ]] && {
    log "ERROR" "Failed repos:${FAILED_LIST}"
    desktop_error "Backup completed with failures.\nFailed repos:${FAILED_LIST}\nSucceeded: ${SUCCEEDED}/${TOTAL}"
}

# Exit with error if any failures
[[ "$FAILED" -eq 0 ]] && exit 0 || exit 1
