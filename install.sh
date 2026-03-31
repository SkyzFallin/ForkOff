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
TOKEN_DIR="${SYSTEMD_DIR}/github-backup.service.d"

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
EXISTING_ERROR_FILE=""
EXISTING_EXCLUDE=""
EXISTING_SCHEDULE=""

if [[ -f "${CONFIG_DIR}/github-backup.conf" ]]; then
    RECONFIG=true
    # shellcheck source=/dev/null
    source "${CONFIG_DIR}/github-backup.conf"
    EXISTING_USER="$GITHUB_USER"
    # Derive base from mirrors path (strip /mirrors suffix)
    EXISTING_BACKUP_BASE="${BACKUP_DIR%/mirrors}"
    EXISTING_ERROR_FILE="${ERROR_FILE:-}"
    EXISTING_EXCLUDE="${EXCLUDE_REPOS:-}"
    # Read schedule from existing timer
    if [[ -f "${SYSTEMD_DIR}/github-backup.timer" ]]; then
        EXISTING_SCHEDULE=$(grep -oP 'OnCalendar=\*-\*-\* \K[0-9]{2}:[0-9]{2}' "${SYSTEMD_DIR}/github-backup.timer" 2>/dev/null || echo "03:00")
    fi
    # Read existing token
    if [[ -f "${TOKEN_DIR}/token.env" ]]; then
        # shellcheck source=/dev/null
        source "${TOKEN_DIR}/token.env"
        EXISTING_TOKEN="${GITHUB_TOKEN:-}"
    fi
    # Clear sourced vars so they don't leak into prompts
    unset GITHUB_USER BACKUP_DIR LOG_DIR REPORT_DIR MAX_LOG_DAYS ERROR_FILE EXCLUDE_REPOS GITHUB_TOKEN

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
TEST_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    "https://api.github.com/user") || true

if [[ "$TEST_RESPONSE" != "200" ]]; then
    echo "ERROR: Token test failed (HTTP ${TEST_RESPONSE})."
    echo "Check your token and try again."
    exit 1
fi

VERIFIED_USER=$(curl -sf \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    "https://api.github.com/user" | jq -r '.login')
echo "  Authenticated as: ${VERIFIED_USER}"
echo ""

# --- Fetch repos and show selector ---
echo "Fetching repository list..."
ALL_REPO_DATA=$(curl -sf \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/user/repos?per_page=100&page=1&affiliation=owner" 2>/dev/null) || {
    echo "ERROR: Failed to fetch repos from GitHub API."
    exit 1
}

# Handle pagination
PAGE=2
while true; do
    NEXT_PAGE=$(curl -sf \
        -H "Authorization: token ${GITHUB_TOKEN}" \
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

# --- Prompt for desktop error file (optional) ---
# Detect the real user's home (not root) for a sensible default
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)
REAL_HOME="${REAL_HOME:-$HOME}"
if [[ "$RECONFIG" == true && -n "$EXISTING_ERROR_FILE" ]]; then
    DEFAULT_ERROR_FILE="$EXISTING_ERROR_FILE"
elif [[ -d "${REAL_HOME}/Desktop" ]]; then
    DEFAULT_ERROR_FILE="${REAL_HOME}/Desktop/BACKUP_ERROR.txt"
else
    DEFAULT_ERROR_FILE=""
fi

echo "Desktop error notification"
echo "  Drops a file on your desktop when backup errors occur."
echo ""
echo "  1) ${DEFAULT_ERROR_FILE:-[no desktop detected]}"
echo "  2) Custom path"
echo "  3) Disabled"
echo ""
read -rp "  Choose [1]: " ERROR_CHOICE
ERROR_CHOICE="${ERROR_CHOICE:-1}"
case "$ERROR_CHOICE" in
    1)
        if [[ -n "$DEFAULT_ERROR_FILE" ]]; then
            ERROR_FILE="$DEFAULT_ERROR_FILE"
        else
            echo "  No desktop directory found. Enter a custom path:"
            read -rp "  Path: " ERROR_FILE
        fi
        ;;
    2)
        read -rp "  Enter path: " ERROR_FILE
        ;;
    3)
        ERROR_FILE=""
        ;;
    *)
        echo "  Invalid choice, disabling."
        ERROR_FILE=""
        ;;
esac
echo ""

# --- Prompt for schedule ---
SCHEDULE_DEFAULT="${EXISTING_SCHEDULE:-03:00}"
prompt_default "Daily backup time (UTC, 24h format)" "$SCHEDULE_DEFAULT" SCHEDULE_TIME
if ! [[ "$SCHEDULE_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "ERROR: Invalid time format. Use HH:MM in 24-hour UTC format (example: 03:00)."
    exit 1
fi
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
echo "  Error file:      ${ERROR_FILE:-disabled}"
echo ""
read -rp "Proceed with installation? (y/N): " CONFIRM
[[ "$CONFIRM" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
echo ""

# --- Deploy ---

echo "[1/7] Creating directories..."
mkdir -p "$BACKUP_DIR" "$LOG_DIR" "$REPORT_DIR" "$CONFIG_DIR"

echo "[2/7] Writing configuration..."
cat > "${CONFIG_DIR}/github-backup.conf" << CONFEOF
# ForkOff — Configuration
# Generated by install.sh on $(date -u '+%Y-%m-%d %H:%M:%S UTC')

GITHUB_USER="${GITHUB_USER}"
BACKUP_DIR="${BACKUP_DIR}"
LOG_DIR="${LOG_DIR}"
REPORT_DIR="${REPORT_DIR}"
MAX_LOG_DAYS=366
ERROR_FILE="${ERROR_FILE}"
EXCLUDE_REPOS="${EXCLUDE_REPOS}"
CONFEOF
chmod 600 "${CONFIG_DIR}/github-backup.conf"
chown root:root "${CONFIG_DIR}/github-backup.conf"

echo "[3/7] Installing backup script to ${INSTALL_PATH}..."
cp "${SCRIPT_DIR}/github-backup.sh" "$INSTALL_PATH"
chmod 755 "$INSTALL_PATH"

echo "[4/7] Storing token..."
mkdir -p "$TOKEN_DIR"
echo "GITHUB_TOKEN=${GITHUB_TOKEN}" > "${TOKEN_DIR}/token.env"
chmod 600 "${TOKEN_DIR}/token.env"

echo "[5/7] Installing systemd units..."
sed "s|@@INSTALL_PATH@@|${INSTALL_PATH}|g" \
    "${SCRIPT_DIR}/github-backup.service" > "${SYSTEMD_DIR}/github-backup.service"
sed "s|@@SCHEDULE@@|${SCHEDULE}|g" \
    "${SCRIPT_DIR}/github-backup.timer" > "${SYSTEMD_DIR}/github-backup.timer"
systemctl daemon-reload

echo "[6/7] Enabling daily timer..."
systemctl enable github-backup.timer
systemctl start github-backup.timer

if [[ "$RECONFIG" == true ]]; then
    echo "[7/7] Running backup with updated config..."
    systemctl start github-backup.service
    echo "  Backup complete."
else
    echo "[7/7] Running initial backup (two passes)..."
    echo ""
    echo "  Pass 1: Cloning all mirrors..."
    systemctl start github-backup.service
    echo "  Pass 1 complete."
    echo ""
    echo "  Pass 2: Updating private repos (re-authenticates stored mirrors)..."
    systemctl start github-backup.service
    echo "  Pass 2 complete."
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
echo ""
echo "  To change excluded repos or other settings:"
echo "    sudo nano ${CONFIG_DIR}/github-backup.conf"
echo ""
echo "  Audit trail:"
echo "    Logs and JSON reports in ${LOG_DIR}/ and ${REPORT_DIR}/"
echo "    serve as timestamped proof that backups are running daily."
echo "    Retain these for compliance, client SLAs, or audits."
echo ""
echo "  ForkOff by SkyzFallin — github.com/SkyzFallin/ForkOff"
echo ""
