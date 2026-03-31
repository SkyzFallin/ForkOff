#!/usr/bin/env bash
# =============================================================================
# ForkOff — GitHub Mirror Backup Installer
# =============================================================================
# Interactive installer that sets up automated daily git mirror backups.
# Run as root: sudo bash install.sh
# https://github.com/SkyzFallin/ForkOff
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYSTEMD_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/github-backup"
CREDSTORE_DIR="/etc/credstore"

# --- Helper Functions --------------------------------------------------------

print_header() {
    clear
    echo "============================================="
    echo "  ForkOff — GitHub Mirror Backup"
    echo "  github.com/SkyzFallin/ForkOff"
    echo "============================================="
    echo ""
}

prompt_default() {
    local prompt="$1"
    local default="$2"
    local varname="$3"
    local input
    read -rp "${prompt} [${default}]: " input
    printf -v "$varname" '%s' "${input:-$default}"
}

prompt_bool() {
    local prompt="$1"
    local default="$2"
    local varname="$3"
    local input
    read -rp "${prompt} (true/false) [${default}]: " input
    local val="${input:-$default}"
    # Normalize to true/false
    if [[ "$val" == "true" || "$val" == "yes" || "$val" == "y" ]]; then
        printf -v "$varname" '%s' "true"
    else
        printf -v "$varname" '%s' "false"
    fi
}

# Authenticate curl without exposing the token in process args.
# Writes a curl config file with the auth header and passes it via -K.
gh_curl() {
    local token="$1"; shift
    local curl_cfg
    curl_cfg=$(mktemp)
    chmod 600 "$curl_cfg"
    printf -- '--header "Authorization: token %s"\n' "$token" > "$curl_cfg"
    curl -K "$curl_cfg" "$@"
    local rc=$?
    rm -f "$curl_cfg"
    return $rc
}

# --- TUI Repo Selector -------------------------------------------------------
# Pure bash interactive checkbox list. Arrow keys navigate, space toggles,
# enter confirms. Returns space-separated list of selected (excluded) repos.

repo_selector() {
    local -n _repos=$1      # array of repo names (input)
    local -n _selected=$2   # array of 0/1 values (output, 1 = excluded)
    local count=${#_repos[@]}

    [[ "$count" -eq 0 ]] && return

    # Initialize unset entries to 0 (preserve any pre-selections)
    for ((i = 0; i < count; i++)); do
        _selected[$i]="${_selected[$i]:-0}"
    done

    local cursor=0
    local scroll=0
    local max_visible
    max_visible=$(( $(tput lines 2>/dev/null || echo 20) - 8 ))
    [[ "$max_visible" -lt 5 ]] && max_visible=5
    [[ "$max_visible" -gt "$count" ]] && max_visible=$count

    # Save terminal state and enter raw mode
    local saved_stty
    saved_stty=$(stty -g)
    trap 'stty "$saved_stty"; tput cnorm 2>/dev/null' EXIT INT TERM
    stty -echo raw
    tput civis 2>/dev/null  # hide cursor

    while true; do
        # --- Render ---
        # Move to top-left and clear
        printf '\e[H\e[2J'
        printf '\e[1m  Select repos to EXCLUDE from backup\e[0m\r\n'
        printf '  (up/down = navigate, space = toggle, enter = confirm)\r\n\r\n'

        # Adjust scroll window
        if ((cursor < scroll)); then
            scroll=$cursor
        elif ((cursor >= scroll + max_visible)); then
            scroll=$((cursor - max_visible + 1))
        fi

        # Show scroll indicator at top
        if ((scroll > 0)); then
            printf '    \e[2m... %d more above ...\e[0m\r\n' "$scroll"
        fi

        for ((i = scroll; i < scroll + max_visible && i < count; i++)); do
            local marker="  "
            [[ "${_selected[$i]}" -eq 1 ]] && marker="\e[31mX\e[0m "

            if ((i == cursor)); then
                # Highlighted line
                printf '  \e[7m [%b] %s \e[0m\r\n' "$marker" "${_repos[$i]}"
            else
                printf '   [%b] %s\r\n' "$marker" "${_repos[$i]}"
            fi
        done

        # Show scroll indicator at bottom
        local remaining=$((count - scroll - max_visible))
        if ((remaining > 0)); then
            printf '    \e[2m... %d more below ...\e[0m\r\n' "$remaining"
        fi

        local excluded_count=0
        for ((i = 0; i < count; i++)); do
            ((${_selected[$i]})) && ((excluded_count++)) || true
        done
        printf '\r\n  \e[2m%d of %d repos will be excluded\e[0m\r\n' "$excluded_count" "$count"

        # --- Input ---
        local key
        IFS= read -rsn1 key

        case "$key" in
            $'\e')
                # Escape sequence — read the rest
                local seq
                IFS= read -rsn2 -t 0.1 seq || true
                case "$seq" in
                    '[A') ((cursor > 0)) && ((cursor--)) || true ;;         # Up
                    '[B') ((cursor < count - 1)) && ((cursor++)) || true ;; # Down
                esac
                ;;
            ' ')
                # Space — toggle
                if [[ "${_selected[$cursor]}" -eq 0 ]]; then
                    _selected[$cursor]=1
                else
                    _selected[$cursor]=0
                fi
                ;;
            ''|$'\n')
                # Enter — confirm
                break
                ;;
            'k')
                ((cursor > 0)) && ((cursor--)) || true ;;
            'j')
                ((cursor < count - 1)) && ((cursor++)) || true ;;
            'q')
                break ;;
        esac
    done

    # Restore terminal
    stty "$saved_stty"
    tput cnorm 2>/dev/null
    trap - EXIT INT TERM
    printf '\e[H\e[2J'
}

# --- Main Installation -------------------------------------------------------

print_header

# Check root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root (sudo bash install.sh)"
    exit 1
fi

# --- Detect existing installation ---
RECONFIG=false
EXISTING_USER=""
EXISTING_BACKUP_BASE=""
EXISTING_EXCLUDE=""
EXISTING_SCHEDULE=""
EXISTING_WEBHOOK_URL=""
EXISTING_WEBHOOK_ON_SUCCESS="false"
EXISTING_NTFY_TOPIC=""
EXISTING_HEALTHCHECK_URL=""
EXISTING_BACKUP_METADATA="false"
EXISTING_MAX_PARALLEL="4"
EXISTING_MIN_FREE_MB="1024"
EXISTING_RESTORE_TEST="false"

if [[ -f "${CONFIG_DIR}/github-backup.conf" ]]; then
    RECONFIG=true
    # Validate config ownership and permissions before sourcing (mirrors runtime script checks)
    if [[ "$(stat -c '%u' "${CONFIG_DIR}/github-backup.conf" 2>/dev/null)" != "0" ]]; then
        echo "ERROR: Existing config must be owned by root."
        echo "Fix with: sudo chown root:root ${CONFIG_DIR}/github-backup.conf"
        exit 1
    fi
    config_perms=$(stat -c '%a' "${CONFIG_DIR}/github-backup.conf" 2>/dev/null)
    if [[ "$config_perms" != "600" ]]; then
        echo "ERROR: Existing config file must have mode 600: ${CONFIG_DIR}/github-backup.conf (found ${config_perms})"
        echo "Fix with: sudo chmod 600 ${CONFIG_DIR}/github-backup.conf"
        exit 1
    fi
    # shellcheck source=/dev/null
    source "${CONFIG_DIR}/github-backup.conf"
    EXISTING_USER="$GITHUB_USER"
    # Derive base from mirrors path (strip /mirrors suffix)
    EXISTING_BACKUP_BASE="${BACKUP_DIR%/mirrors}"
    EXISTING_EXCLUDE="${EXCLUDE_REPOS:-}"
    EXISTING_WEBHOOK_URL="${WEBHOOK_URL:-}"
    EXISTING_WEBHOOK_ON_SUCCESS="${WEBHOOK_ON_SUCCESS:-false}"
    EXISTING_NTFY_TOPIC="${NTFY_TOPIC:-}"
    EXISTING_HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"
    EXISTING_BACKUP_METADATA="${BACKUP_METADATA:-false}"
    EXISTING_MAX_PARALLEL="${MAX_PARALLEL:-4}"
    EXISTING_MIN_FREE_MB="${MIN_FREE_MB:-1024}"
    EXISTING_RESTORE_TEST="${RESTORE_TEST:-false}"
    # Read schedule from existing timer
    if [[ -f "${SYSTEMD_DIR}/github-backup.timer" ]]; then
        EXISTING_SCHEDULE=$(grep -oP 'OnCalendar=\*-\*-\* \K[0-9]{2}:[0-9]{2}' "${SYSTEMD_DIR}/github-backup.timer" 2>/dev/null || echo "03:00")
    fi
    # Read existing token
    if [[ -f "${CREDSTORE_DIR}/github-backup.github-token" ]]; then
        EXISTING_TOKEN=$(systemd-creds decrypt --name=github-token \
            "${CREDSTORE_DIR}/github-backup.github-token" - 2>/dev/null || echo "")
    fi
    # Clear sourced vars so they don't leak into prompts
    unset GITHUB_USER BACKUP_DIR LOG_DIR REPORT_DIR MAX_LOG_DAYS EXCLUDE_REPOS GITHUB_TOKEN \
        WEBHOOK_URL WEBHOOK_ON_SUCCESS NTFY_TOPIC HEALTHCHECK_URL BACKUP_METADATA \
        MAX_PARALLEL MIN_FREE_MB RESTORE_TEST ERROR_FILE

    echo "  Existing installation detected — entering reconfigure mode."
    echo "  Press enter at any prompt to keep the current value."
    echo ""
fi

# Install dependencies
echo "Checking dependencies..."
for cmd in git curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "  Installing ${cmd}..."
        apt-get install -y "$cmd" > /dev/null 2>&1
    else
        echo "  ${cmd} — OK"
    fi
done
echo ""

# --- Prompt for GitHub username ---
if [[ "$RECONFIG" == true ]]; then
    prompt_default "GitHub username" "$EXISTING_USER" GITHUB_USER
else
    read -rp "GitHub username: " GITHUB_USER
fi
[[ -z "$GITHUB_USER" ]] && { echo "ERROR: Username required."; exit 1; }
echo ""

# --- Prompt for PAT ---
if [[ "$RECONFIG" == true && -n "${EXISTING_TOKEN:-}" ]]; then
    echo "GitHub PAT"
    echo "  Current token: ${EXISTING_TOKEN:0:4}...${EXISTING_TOKEN: -4}"
    echo "  Press enter to keep it, or paste a new one."
    echo ""
    read -rsp "  GitHub PAT: " NEW_TOKEN
    echo ""
    GITHUB_TOKEN="${NEW_TOKEN:-$EXISTING_TOKEN}"
else
    echo "GitHub PAT Setup"
    echo "  Create one at: https://github.com/settings/tokens"
    echo "  Required scope: 'repo' (full control of private repositories)"
    echo ""
    read -rsp "  Paste your GitHub PAT: " GITHUB_TOKEN
    echo ""
fi
echo ""

# --- Test the token ---
echo "Testing token against GitHub API..."
TEST_RESPONSE=$(gh_curl "$GITHUB_TOKEN" -s -o /dev/null -w "%{http_code}" \
    "https://api.github.com/user") || true

if [[ "$TEST_RESPONSE" != "200" ]]; then
    case "$TEST_RESPONSE" in
        401) echo "ERROR: Token is invalid or expired (HTTP 401)." ;;
        403) echo "ERROR: Token lacks permissions or SSO enforcement is blocking access (HTTP 403)." ;;
        000|"") echo "ERROR: Could not reach api.github.com. Check your network connection." ;;
        *)   echo "ERROR: Token test failed (HTTP ${TEST_RESPONSE})." ;;
    esac
    echo "Check your token and try again."
    exit 1
fi

VERIFIED_USER=$(gh_curl "$GITHUB_TOKEN" -sf \
    "https://api.github.com/user" | jq -r '.login')
echo "  Authenticated as: ${VERIFIED_USER}"
echo ""

# --- Fetch repos and show selector ---
echo "Fetching repository list..."
ALL_REPO_DATA=$(gh_curl "$GITHUB_TOKEN" -sf \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/user/repos?per_page=100&page=1&affiliation=owner" 2>/dev/null) || {
    echo "ERROR: Failed to fetch repos from GitHub API."
    exit 1
}

# Handle pagination
PAGE=2
while true; do
    NEXT_PAGE=$(gh_curl "$GITHUB_TOKEN" -sf \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/user/repos?per_page=100&page=${PAGE}&affiliation=owner" 2>/dev/null) || break
    NEXT_COUNT=$(echo "$NEXT_PAGE" | jq 'length')
    [[ "$NEXT_COUNT" -eq 0 ]] && break
    ALL_REPO_DATA=$(printf '%s\n%s' "$ALL_REPO_DATA" "$NEXT_PAGE" | jq -s 'add')
    ((PAGE++)) || true
done

# Parse repo names and info
REPO_NAMES=()
REPO_FORKS=()
while IFS='|' read -r name fork; do
    REPO_NAMES+=("$name")
    REPO_FORKS+=("$fork")
done < <(echo "$ALL_REPO_DATA" | jq -r '.[] | "\(.name)|\(.fork)"')

REPO_COUNT=${#REPO_NAMES[@]}
echo "  Found ${REPO_COUNT} repositories."
echo ""

if [[ "$REPO_COUNT" -eq 0 ]]; then
    echo "WARNING: No repos found. The backup will have nothing to do."
    echo "Continuing with setup anyway..."
    EXCLUDE_REPOS=""
else
    # Build display names (mark forks)
    DISPLAY_NAMES=()
    for ((i = 0; i < REPO_COUNT; i++)); do
        if [[ "${REPO_FORKS[$i]}" == "true" ]]; then
            DISPLAY_NAMES+=("${REPO_NAMES[$i]}  (fork)")
        else
            DISPLAY_NAMES+=("${REPO_NAMES[$i]}")
        fi
    done

    echo "Select which repos to EXCLUDE from backup."
    echo "Forks are labeled — you probably want to exclude those."
    if [[ "$RECONFIG" == true && -n "$EXISTING_EXCLUDE" ]]; then
        echo "  Previously excluded repos are pre-selected."
    fi
    echo ""
    read -rp "Press enter to open the selector... " _

    # Pre-select previously excluded repos on reconfig
    SELECTED=()
    if [[ "$RECONFIG" == true && -n "$EXISTING_EXCLUDE" ]]; then
        for ((i = 0; i < REPO_COUNT; i++)); do
            SELECTED[$i]=0
            for ex_name in $EXISTING_EXCLUDE; do
                if [[ "${REPO_NAMES[$i]}" == "$ex_name" ]]; then
                    SELECTED[$i]=1
                    break
                fi
            done
        done
    fi
    repo_selector DISPLAY_NAMES SELECTED

    # Build exclude list from selections
    EXCLUDE_LIST=()
    for ((i = 0; i < REPO_COUNT; i++)); do
        if [[ "${SELECTED[$i]:-0}" -eq 1 ]]; then
            EXCLUDE_LIST+=("${REPO_NAMES[$i]}")
        fi
    done

    EXCLUDE_REPOS="${EXCLUDE_LIST[*]:-}"

    if [[ -n "$EXCLUDE_REPOS" ]]; then
        echo "Excluded repos: ${EXCLUDE_REPOS}"
    else
        echo "No repos excluded — all will be backed up."
    fi
    echo ""
fi

# --- Prompt for backup directory ---
BACKUP_BASE_DEFAULT="${EXISTING_BACKUP_BASE:-/opt/github-backups}"
prompt_default "Backup directory" "$BACKUP_BASE_DEFAULT" BACKUP_BASE
BACKUP_DIR="${BACKUP_BASE}/mirrors"
LOG_DIR="${BACKUP_BASE}/logs"
REPORT_DIR="${BACKUP_BASE}/reports"
echo ""

# --- Prompt for notifications ---
echo "--- Notifications ---"
echo ""

echo "Webhook (POST JSON on failure — Discord, Slack, Make, Zapier, etc.)"
prompt_default "  Webhook URL (empty to disable)" "${EXISTING_WEBHOOK_URL:-}" WEBHOOK_URL
if [[ -n "$WEBHOOK_URL" ]]; then
    prompt_bool "  Also send webhook on success?" "$EXISTING_WEBHOOK_ON_SUCCESS" WEBHOOK_ON_SUCCESS
else
    WEBHOOK_ON_SUCCESS="false"
fi
echo ""

echo "ntfy.sh push notifications"
prompt_default "  ntfy topic URL (empty to disable)" "${EXISTING_NTFY_TOPIC:-}" NTFY_TOPIC
echo ""

echo "Healthcheck (dead-man's-switch — Healthchecks.io, UptimeRobot, etc.)"
prompt_default "  Healthcheck URL (empty to disable)" "${EXISTING_HEALTHCHECK_URL:-}" HEALTHCHECK_URL
echo ""

# --- Prompt for metadata export ---
echo "--- Metadata Export ---"
echo ""
echo "Export GitHub issues, PRs, and releases as JSON alongside mirrors."
if [[ "$RECONFIG" == true ]]; then
    prompt_bool "  Enable metadata export?" "$EXISTING_BACKUP_METADATA" BACKUP_METADATA
else
    prompt_bool "  Enable metadata export?" "false" BACKUP_METADATA
fi
if [[ "$BACKUP_METADATA" == "true" ]]; then
    if ! command -v gh &>/dev/null; then
        echo "  WARNING: gh CLI not found. Install it before running backups."
        echo "           https://cli.github.com/"
    else
        echo "  gh CLI: OK"
    fi
fi
echo ""

# --- Prompt for performance/safety ---
echo "--- Performance & Safety ---"
echo ""
prompt_default "  Max parallel jobs" "${EXISTING_MAX_PARALLEL:-4}" MAX_PARALLEL
[[ "$MAX_PARALLEL" =~ ^[1-9][0-9]*$ ]] || { echo "  Invalid value, using default: 4"; MAX_PARALLEL=4; }
prompt_default "  Min free disk space (MB)" "${EXISTING_MIN_FREE_MB:-1024}" MIN_FREE_MB
[[ "$MIN_FREE_MB" =~ ^[0-9]+$ ]] || { echo "  Invalid value, using default: 1024"; MIN_FREE_MB=1024; }
prompt_bool "  Run restore test after each backup?" "${EXISTING_RESTORE_TEST:-false}" RESTORE_TEST
echo ""

# --- Prompt for schedule ---
SCHEDULE_DEFAULT="${EXISTING_SCHEDULE:-03:00}"
while true; do
    prompt_default "Daily backup time (UTC, 24h format)" "$SCHEDULE_DEFAULT" SCHEDULE_TIME
    if [[ "$SCHEDULE_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        break
    fi
    echo "  Invalid format. Use HH:MM in 24-hour UTC (example: 03:00). Try again."
done
SCHEDULE="*-*-* ${SCHEDULE_TIME}:00"
echo ""

# --- Install path ---
INSTALL_PATH="/usr/local/bin/github-backup"

# --- Summary ---
echo "============================================="
echo "  Installation Summary"
echo "============================================="
echo ""
echo "  GitHub user:     ${GITHUB_USER}"
echo "  Backup dir:      ${BACKUP_BASE}/"
echo "  Install path:    ${INSTALL_PATH}"
echo "  Schedule:        ${SCHEDULE} UTC (+ up to 15min jitter)"
echo "  Excluded repos:  ${EXCLUDE_REPOS:-none}"
echo "  Webhook:         ${WEBHOOK_URL:-disabled}"
echo "  ntfy topic:      ${NTFY_TOPIC:-disabled}"
echo "  Healthcheck:     ${HEALTHCHECK_URL:-disabled}"
echo "  Metadata export: ${BACKUP_METADATA}"
echo "  Parallel jobs:   ${MAX_PARALLEL}"
echo "  Min free space:  ${MIN_FREE_MB} MB"
echo "  Restore test:    ${RESTORE_TEST}"
echo ""
read -rp "Proceed with installation? (y/N): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
echo ""

# --- Deploy ---

echo "[1/7] Creating directories..."
mkdir -p "$BACKUP_DIR" "$LOG_DIR" "$REPORT_DIR" "$CONFIG_DIR"
chmod 700 "$BACKUP_DIR" "$LOG_DIR" "$REPORT_DIR"
if [[ "$BACKUP_METADATA" == "true" ]]; then
    mkdir -p "${BACKUP_BASE}/metadata"
    chmod 700 "${BACKUP_BASE}/metadata"
fi

echo "[2/7] Writing configuration..."
{
    echo "# ForkOff — Configuration"
    echo "# Generated by install.sh on $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo ""
    # Use printf %q to safely escape all values (prevents shell injection via config)
    printf 'GITHUB_USER=%q\n' "$GITHUB_USER"
    printf 'BACKUP_DIR=%q\n' "$BACKUP_DIR"
    printf 'LOG_DIR=%q\n' "$LOG_DIR"
    printf 'REPORT_DIR=%q\n' "$REPORT_DIR"
    echo "MAX_LOG_DAYS=366"
    printf 'EXCLUDE_REPOS=%q\n' "$EXCLUDE_REPOS"
    echo ""
    echo "# Notifications"
    printf 'WEBHOOK_URL=%q\n' "$WEBHOOK_URL"
    printf 'WEBHOOK_ON_SUCCESS=%q\n' "$WEBHOOK_ON_SUCCESS"
    printf 'NTFY_TOPIC=%q\n' "$NTFY_TOPIC"
    printf 'HEALTHCHECK_URL=%q\n' "$HEALTHCHECK_URL"
    echo ""
    echo "# Metadata"
    printf 'BACKUP_METADATA=%q\n' "$BACKUP_METADATA"
    echo ""
    echo "# Performance & Safety"
    printf 'MAX_PARALLEL=%q\n' "$MAX_PARALLEL"
    printf 'MIN_FREE_MB=%q\n' "$MIN_FREE_MB"
    printf 'RESTORE_TEST=%q\n' "$RESTORE_TEST"
} > "${CONFIG_DIR}/github-backup.conf"
chmod 600 "${CONFIG_DIR}/github-backup.conf"
chown root:root "${CONFIG_DIR}/github-backup.conf"

echo "[3/7] Installing backup script to ${INSTALL_PATH}..."
cp "${SCRIPT_DIR}/github-backup.sh" "$INSTALL_PATH"
chmod 755 "$INSTALL_PATH"

echo "[4/7] Storing token..."
mkdir -p "$CREDSTORE_DIR"
chmod 700 "$CREDSTORE_DIR"
echo -n "$GITHUB_TOKEN" | systemd-creds encrypt --name=github-token \
    - "${CREDSTORE_DIR}/github-backup.github-token"
chmod 600 "${CREDSTORE_DIR}/github-backup.github-token"
chown root:root "${CREDSTORE_DIR}/github-backup.github-token"

echo "[5/7] Installing systemd units..."
sed -e "s|@@INSTALL_PATH@@|${INSTALL_PATH}|g" \
    -e "s|@@BACKUP_BASE@@|${BACKUP_BASE}|g" \
    "${SCRIPT_DIR}/github-backup.service" > "${SYSTEMD_DIR}/github-backup.service"
sed "s|@@SCHEDULE@@|${SCHEDULE}|g" \
    "${SCRIPT_DIR}/github-backup.timer" > "${SYSTEMD_DIR}/github-backup.timer"
systemctl daemon-reload

echo "[6/7] Enabling daily timer..."
systemctl enable github-backup.timer
systemctl start github-backup.timer

if [[ "$RECONFIG" == true ]]; then
    echo "[7/7] Running backup with updated config..."
    if systemctl start github-backup.service; then
        echo "  Backup complete."
    else
        echo "  WARNING: Backup exited with errors. Check logs:"
        echo "    sudo journalctl -u github-backup -n 50"
    fi
else
    echo "[7/7] Running initial backup..."
    if systemctl start github-backup.service; then
        echo "  Initial backup complete."
    else
        echo "  WARNING: Initial backup exited with errors. Check logs:"
        echo "    sudo journalctl -u github-backup -n 50"
    fi
fi
echo ""

echo "============================================="
if [[ "$RECONFIG" == true ]]; then
    echo "  ForkOff — Reconfiguration Complete"
else
    echo "  ForkOff — Installation Complete"
fi
echo "============================================="
echo ""
echo "  Config:     ${CONFIG_DIR}/github-backup.conf"
echo "  Script:     ${INSTALL_PATH}"
echo "  Mirrors:    ${BACKUP_DIR}/"
echo "  Logs:       ${LOG_DIR}/"
echo "  Reports:    ${REPORT_DIR}/"
echo "  Schedule:   ${SCHEDULE} UTC"
echo ""
echo "  Commands:"
echo "    Run now:          sudo systemctl start github-backup.service"
echo "    Watch logs:       sudo journalctl -u github-backup -f"
echo "    Check timer:      systemctl list-timers github-backup.timer"
echo "    Backup status:    sudo github-backup --status"
echo "    Verify mirrors:   sudo github-backup --verify"
echo "    Restore test:     sudo github-backup --test-restore"
echo "    Test notify:      sudo github-backup --test-notify"
echo ""
echo "  To change settings, run the installer again or edit:"
echo "    sudo nano ${CONFIG_DIR}/github-backup.conf"
echo ""
echo "  Audit trail:"
echo "    Logs and JSON reports in ${LOG_DIR}/ and ${REPORT_DIR}/"
echo "    serve as timestamped proof that backups are running daily."
echo "    Retain these for compliance, client SLAs, or audits."
echo ""
echo "  ForkOff by SkyzFallin — github.com/SkyzFallin/ForkOff"
echo ""
