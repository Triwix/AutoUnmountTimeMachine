#!/bin/bash

# Time Machine Auto-Backup Script
# Automatically backs up when Time Machine disk is mounted
# macOS-only script (uses tmutil, diskutil, launchd, BSD date/stat)
#
# Configuration:
# - Runs on disk mount and at login
# - Logs to: ~/Library/Logs/AutoTMLogs/tm-auto-backup.log
# - Safe to tune: BACKUP_THRESHOLD_HOURS, EJECT_WHEN_NO_BACKUP, SHOW_MENUBAR_ICON_DURING_BACKUP
# - Advanced tuning: WAIT_FOR_RUNNING_BACKUP_MAX_SECONDS, BACKUP_BLOCK_TIMEOUT_SECONDS, LOCK_STALE_SECONDS
#
# To disable:
# launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.user.timemachine-auto.plist"
# To enable:
# launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.user.timemachine-auto.plist"
#
# Troubleshooting:
# - Agent status: launchctl print "gui/$(id -u)/com.user.timemachine-auto"
# - Trigger once now: launchctl kickstart -k "gui/$(id -u)/com.user.timemachine-auto"
# - Manual run: "$HOME/Library/Scripts/timemachine-auto.sh"
# - Destination check: tmutil destinationinfo -X
# - If you see Full Disk Access warnings, grant FDA to the app/shell hosting this agent context.
#
# Uninstall cleanup:
# 1) launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.user.timemachine-auto.plist"
# 2) rm -f "$HOME/Library/LaunchAgents/com.user.timemachine-auto.plist"
# 3) rm -f "$HOME/Library/Scripts/timemachine-auto.sh"
# 4) rm -rf "$HOME/Library/Application Support/TimeMachineAuto" "$HOME/Library/Caches/com.user.timemachine-auto.lock" "$HOME/Library/Logs/AutoTMLogs"

# User configuration
# BACKUP_THRESHOLD_HOURS: Minimum hours between backups. Example: 24 for daily.
# DUPLICATE_WINDOW_SECONDS: Ignore repeated triggers within this many seconds.
# ALLOW_AUTOMOUNT: If true, attempt to mount the TM disk when connected but unmounted.
# EJECT_WHEN_NO_BACKUP: If false, keep disk mounted when no backup is needed.
# SHOW_MENUBAR_ICON_DURING_BACKUP: If true, temporarily show TM menu icon while this script runs a backup.
#   Note: this may restart SystemUIServer when restoring the original menu icon state.
# REQUIRE_SNAPSHOT_VERIFICATION: If true, require a new snapshot ID before ejecting after backup.
# FDA_NOTIFY_COOLDOWN_SECONDS: Minimum interval between Full Disk Access alerts.
# EJECT_RETRY_ATTEMPTS: Number of eject retries when initial attempt fails.
# RUNNING_BACKUP_POLL_SECONDS: Poll interval while waiting for an already-running backup to finish.
# WAIT_FOR_RUNNING_BACKUP_MAX_SECONDS: Max wait time for an already-running backup before leaving mounted.
# LOCK_STALE_SECONDS: If lock PID is missing/invalid and older than this, reclaim lock.
# PREFERRED_DESTINATION_ID: Optional Time Machine destination UUID to target explicitly.
# MAX_LOG_BYTES: Rotate log file when it exceeds this size in bytes.
# MAX_LOG_FILES: Number of rotated logs to keep.
# FAST_PATH_WAIT_SECONDS: Grace period for tmutil to surface a newly mounted destination.
# MAX_FALLBACK_STATE_AGE_HOURS: If fallback state is older than this, force a backup attempt.
# BACKUP_BLOCK_TIMEOUT_SECONDS: Maximum time to wait for started backup activity to complete.
# EJECT_PRECHECK_DELAY_SECONDS: Delay before eject precheck after backup/no-backup decision.
# MAX_LOCK_PID_WAIT_SECONDS: If lock has no PID and is newer than this, assume setup race and defer.
# LOG_FILE: Script log file; directory is created automatically.
# LOCK_DIR: Single-instance lock directory.
# STATE_FILE: Stores last handled mount signature/time.
# LAST_SUCCESS_FILE: Stores the epoch of the last successful backup run (destination-scoped at runtime).
# FDA_NOTICE_FILE: Stores the epoch of the last Full Disk Access notification.
# PATH: Command lookup for launchd; include system bins needed by the script.
BACKUP_THRESHOLD_HOURS=72
DUPLICATE_WINDOW_SECONDS=120
ALLOW_AUTOMOUNT=false
EJECT_WHEN_NO_BACKUP=true
SHOW_MENUBAR_ICON_DURING_BACKUP=true
REQUIRE_SNAPSHOT_VERIFICATION=false
FDA_NOTIFY_COOLDOWN_SECONDS=86400
EJECT_RETRY_ATTEMPTS=3
RUNNING_BACKUP_POLL_SECONDS=15
WAIT_FOR_RUNNING_BACKUP_MAX_SECONDS=7200
LOCK_STALE_SECONDS=1200
PREFERRED_DESTINATION_ID=""
MAX_LOG_BYTES=5242880
MAX_LOG_FILES=5
FAST_PATH_WAIT_SECONDS=15
MAX_FALLBACK_STATE_AGE_HOURS=336
BACKUP_BLOCK_TIMEOUT_SECONDS=14400
EJECT_PRECHECK_DELAY_SECONDS=3
MAX_LOCK_PID_WAIT_SECONDS=5
STATE_DIR="$HOME/Library/Application Support/TimeMachineAuto"
LOG_FILE="$HOME/Library/Logs/AutoTMLogs/tm-auto-backup.log"
LOCK_DIR="$HOME/Library/Caches/com.user.timemachine-auto.lock"
STATE_FILE="$STATE_DIR/last-processed-mount.state"
LEGACY_LAST_SUCCESS_FILE="$STATE_DIR/last-successful-backup.epoch"
LAST_SUCCESS_FILE="$LEGACY_LAST_SUCCESS_FILE"
FDA_NOTICE_FILE="$STATE_DIR/last-fda-notice.epoch"
TM_MENU_STATE_FILE="$STATE_DIR/tm-menu-icon-added.marker"
TM_MENU_PATH_NOTICE_FILE="$STATE_DIR/tm-menu-path-warning.marker"
PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
LC_ALL="C"
LANG="C"
TIME_MACHINE_MENU_EXTRA="/System/Library/CoreServices/Menu Extras/TimeMachine.menu"
TIME_MACHINE_MENU_CANDIDATES=(
    "/System/Library/CoreServices/Menu Extras/TimeMachine.menu"
    "/System/Library/CoreServices/MenuExtras/TimeMachine.menu"
    "/Applications/Utilities/Time Machine.app/Contents/Resources/TimeMachine.menu"
)
TM_MENU_ICON_ADDED_BY_SCRIPT=false
LOCK_PID_FILE="$LOCK_DIR/pid"
LOCK_CREATED_FILE="$LOCK_DIR/created_epoch"
LOCK_CMD_FILE="$LOCK_DIR/cmdline"
LOCK_START_FILE="$LOCK_DIR/start_key"

# Create log directory if it doesn't exist
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p "$(dirname "$STATE_FILE")"
mkdir -p "$(dirname "$LOCK_DIR")"
mkdir -p "$(dirname "$TM_MENU_STATE_FILE")"
export PATH LC_ALL LANG

validate_numeric_configs() {
    local had_invalid_config=false

    if ! [[ "$BACKUP_THRESHOLD_HOURS" =~ ^[0-9]+$ ]] || [ "$BACKUP_THRESHOLD_HOURS" -lt 1 ]; then
        log "WARNING: Invalid BACKUP_THRESHOLD_HOURS ($BACKUP_THRESHOLD_HOURS); using default 72"
        BACKUP_THRESHOLD_HOURS=72
        had_invalid_config=true
    fi
    if ! [[ "$DUPLICATE_WINDOW_SECONDS" =~ ^[0-9]+$ ]] || [ "$DUPLICATE_WINDOW_SECONDS" -lt 0 ]; then
        log "WARNING: Invalid DUPLICATE_WINDOW_SECONDS ($DUPLICATE_WINDOW_SECONDS); using default 120"
        DUPLICATE_WINDOW_SECONDS=120
        had_invalid_config=true
    fi
    if ! [[ "$FDA_NOTIFY_COOLDOWN_SECONDS" =~ ^[0-9]+$ ]] || [ "$FDA_NOTIFY_COOLDOWN_SECONDS" -lt 0 ]; then
        log "WARNING: Invalid FDA_NOTIFY_COOLDOWN_SECONDS ($FDA_NOTIFY_COOLDOWN_SECONDS); using default 86400"
        FDA_NOTIFY_COOLDOWN_SECONDS=86400
        had_invalid_config=true
    fi
    if ! [[ "$EJECT_RETRY_ATTEMPTS" =~ ^[0-9]+$ ]] || [ "$EJECT_RETRY_ATTEMPTS" -lt 1 ]; then
        log "WARNING: Invalid EJECT_RETRY_ATTEMPTS ($EJECT_RETRY_ATTEMPTS); using default 3"
        EJECT_RETRY_ATTEMPTS=3
        had_invalid_config=true
    fi
    if ! [[ "$RUNNING_BACKUP_POLL_SECONDS" =~ ^[0-9]+$ ]] || [ "$RUNNING_BACKUP_POLL_SECONDS" -lt 1 ]; then
        log "WARNING: Invalid RUNNING_BACKUP_POLL_SECONDS ($RUNNING_BACKUP_POLL_SECONDS); using default 15"
        RUNNING_BACKUP_POLL_SECONDS=15
        had_invalid_config=true
    fi
    if ! [[ "$WAIT_FOR_RUNNING_BACKUP_MAX_SECONDS" =~ ^[0-9]+$ ]] || [ "$WAIT_FOR_RUNNING_BACKUP_MAX_SECONDS" -lt "$RUNNING_BACKUP_POLL_SECONDS" ]; then
        log "WARNING: Invalid WAIT_FOR_RUNNING_BACKUP_MAX_SECONDS ($WAIT_FOR_RUNNING_BACKUP_MAX_SECONDS); using default 7200"
        WAIT_FOR_RUNNING_BACKUP_MAX_SECONDS=7200
        had_invalid_config=true
    fi
    if ! [[ "$LOCK_STALE_SECONDS" =~ ^[0-9]+$ ]] || [ "$LOCK_STALE_SECONDS" -lt 1 ]; then
        log "WARNING: Invalid LOCK_STALE_SECONDS ($LOCK_STALE_SECONDS); using default 1200"
        LOCK_STALE_SECONDS=1200
        had_invalid_config=true
    fi
    if ! [[ "$FAST_PATH_WAIT_SECONDS" =~ ^[0-9]+$ ]] || [ "$FAST_PATH_WAIT_SECONDS" -lt 1 ]; then
        log "WARNING: Invalid FAST_PATH_WAIT_SECONDS ($FAST_PATH_WAIT_SECONDS); using default 15"
        FAST_PATH_WAIT_SECONDS=15
        had_invalid_config=true
    fi
    if ! [[ "$MAX_FALLBACK_STATE_AGE_HOURS" =~ ^[0-9]+$ ]] || [ "$MAX_FALLBACK_STATE_AGE_HOURS" -lt 1 ]; then
        log "WARNING: Invalid MAX_FALLBACK_STATE_AGE_HOURS ($MAX_FALLBACK_STATE_AGE_HOURS); using default 336"
        MAX_FALLBACK_STATE_AGE_HOURS=336
        had_invalid_config=true
    fi
    if ! [[ "$BACKUP_BLOCK_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [ "$BACKUP_BLOCK_TIMEOUT_SECONDS" -lt 60 ]; then
        log "WARNING: Invalid BACKUP_BLOCK_TIMEOUT_SECONDS ($BACKUP_BLOCK_TIMEOUT_SECONDS); using default 14400"
        BACKUP_BLOCK_TIMEOUT_SECONDS=14400
        had_invalid_config=true
    fi
    if ! [[ "$EJECT_PRECHECK_DELAY_SECONDS" =~ ^[0-9]+$ ]] || [ "$EJECT_PRECHECK_DELAY_SECONDS" -lt 0 ]; then
        log "WARNING: Invalid EJECT_PRECHECK_DELAY_SECONDS ($EJECT_PRECHECK_DELAY_SECONDS); using default 3"
        EJECT_PRECHECK_DELAY_SECONDS=3
        had_invalid_config=true
    fi
    if ! [[ "$MAX_LOCK_PID_WAIT_SECONDS" =~ ^[0-9]+$ ]] || [ "$MAX_LOCK_PID_WAIT_SECONDS" -lt 0 ]; then
        log "WARNING: Invalid MAX_LOCK_PID_WAIT_SECONDS ($MAX_LOCK_PID_WAIT_SECONDS); using default 5"
        MAX_LOCK_PID_WAIT_SECONDS=5
        had_invalid_config=true
    fi
    if ! [[ "$MAX_LOG_BYTES" =~ ^[0-9]+$ ]] || [ "$MAX_LOG_BYTES" -lt 0 ]; then
        log "WARNING: Invalid MAX_LOG_BYTES ($MAX_LOG_BYTES); using default 5242880"
        MAX_LOG_BYTES=5242880
        had_invalid_config=true
    fi
    if ! [[ "$MAX_LOG_FILES" =~ ^[0-9]+$ ]] || [ "$MAX_LOG_FILES" -lt 0 ]; then
        log "WARNING: Invalid MAX_LOG_FILES ($MAX_LOG_FILES); using default 5"
        MAX_LOG_FILES=5
        had_invalid_config=true
    fi

    if [ "$had_invalid_config" = true ]; then
        log "One or more invalid numeric config values were corrected to defaults"
    fi
}

normalize_bool() {
    local raw normalized default_value
    raw="$1"
    default_value="$2"
    normalized=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
    case "$normalized" in
        true|1|yes|on)
            printf 'true\n'
            ;;
        false|0|no|off)
            printf 'false\n'
            ;;
        *)
            printf '%s\n' "$default_value"
            ;;
    esac
}

is_valid_bool_literal() {
    local normalized
    normalized=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$normalized" in
        true|1|yes|on|false|0|no|off)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

validate_boolean_configs() {
    local previous_value

    previous_value="$ALLOW_AUTOMOUNT"
    ALLOW_AUTOMOUNT=$(normalize_bool "$ALLOW_AUTOMOUNT" "false")
    if ! is_valid_bool_literal "$previous_value"; then
        log "WARNING: Invalid ALLOW_AUTOMOUNT value ($previous_value); using $ALLOW_AUTOMOUNT"
    fi

    previous_value="$EJECT_WHEN_NO_BACKUP"
    EJECT_WHEN_NO_BACKUP=$(normalize_bool "$EJECT_WHEN_NO_BACKUP" "true")
    if ! is_valid_bool_literal "$previous_value"; then
        log "WARNING: Invalid EJECT_WHEN_NO_BACKUP value ($previous_value); using $EJECT_WHEN_NO_BACKUP"
    fi

    previous_value="$SHOW_MENUBAR_ICON_DURING_BACKUP"
    SHOW_MENUBAR_ICON_DURING_BACKUP=$(normalize_bool "$SHOW_MENUBAR_ICON_DURING_BACKUP" "true")
    if ! is_valid_bool_literal "$previous_value"; then
        log "WARNING: Invalid SHOW_MENUBAR_ICON_DURING_BACKUP value ($previous_value); using $SHOW_MENUBAR_ICON_DURING_BACKUP"
    fi

    previous_value="$REQUIRE_SNAPSHOT_VERIFICATION"
    REQUIRE_SNAPSHOT_VERIFICATION=$(normalize_bool "$REQUIRE_SNAPSHOT_VERIFICATION" "false")
    if ! is_valid_bool_literal "$previous_value"; then
        log "WARNING: Invalid REQUIRE_SNAPSHOT_VERIFICATION value ($previous_value); using $REQUIRE_SNAPSHOT_VERIFICATION"
    fi
}

validate_destination_config() {
    if [ -n "$PREFERRED_DESTINATION_ID" ] && ! [[ "$PREFERRED_DESTINATION_ID" =~ ^[0-9A-Fa-f-]+$ ]]; then
        log "WARNING: PREFERRED_DESTINATION_ID does not look like a UUID: $PREFERRED_DESTINATION_ID"
    fi
}

validate_menu_icon_config() {
    local candidate
    local found_path=""

    if [[ "$SHOW_MENUBAR_ICON_DURING_BACKUP" != true ]]; then
        return 0
    fi

    for candidate in "${TIME_MACHINE_MENU_CANDIDATES[@]}"; do
        if [ -e "$candidate" ]; then
            found_path="$candidate"
            break
        fi
    done

    if [ -n "$found_path" ]; then
        TIME_MACHINE_MENU_EXTRA="$found_path"
        rm -f "$TM_MENU_PATH_NOTICE_FILE"
        return 0
    fi

    if [ ! -e "$TIME_MACHINE_MENU_EXTRA" ]; then
        SHOW_MENUBAR_ICON_DURING_BACKUP=false
        if [ ! -f "$TM_MENU_PATH_NOTICE_FILE" ]; then
            log "WARNING: Time Machine menu extra not found at expected path ($TIME_MACHINE_MENU_EXTRA); menu icon feature disabled"
            printf '%s\n' "$(date +%s)" > "$TM_MENU_PATH_NOTICE_FILE"
        fi
    fi
}

# Log function
log() {
    printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"
}

escape_applescript_string() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    printf '%s' "$value"
}

notify_user() {
    local message="$1"
    local title="${2:-Time Machine Auto-Backup}"
    local sound="$3"
    local message_escaped
    local title_escaped
    local sound_escaped
    local script

    message_escaped=$(escape_applescript_string "$message")
    title_escaped=$(escape_applescript_string "$title")

    if [ -n "$sound" ]; then
        sound_escaped=$(escape_applescript_string "$sound")
        script="display notification \"$message_escaped\" with title \"$title_escaped\" sound name \"$sound_escaped\""
    else
        script="display notification \"$message_escaped\" with title \"$title_escaped\""
    fi

    if ! osascript -e "$script" >/dev/null 2>&1; then
        log "WARNING: Could not display notification: $title | $message"
        return 1
    fi
    return 0
}

output_indicates_fda_issue() {
    printf '%s\n' "$1" | grep -Eq 'Full Disk Access|Operation not permitted'
}

rotate_log_file_if_needed() {
    local size max_files i

    if ! [[ "$MAX_LOG_BYTES" =~ ^[0-9]+$ ]] || [ "$MAX_LOG_BYTES" -le 0 ]; then
        return 0
    fi

    if [ ! -f "$LOG_FILE" ]; then
        return 0
    fi

    size=$(stat -f '%z' "$LOG_FILE" 2>/dev/null)
    if ! [[ "$size" =~ ^[0-9]+$ ]] || [ "$size" -lt "$MAX_LOG_BYTES" ]; then
        return 0
    fi

    max_files="$MAX_LOG_FILES"
    if ! [[ "$max_files" =~ ^[0-9]+$ ]]; then
        max_files=5
    fi

    if [ "$max_files" -le 0 ]; then
        : > "$LOG_FILE" || return 1
        return 0
    fi

    for ((i=max_files; i>=1; i--)); do
        if [ ! -f "$LOG_FILE.$i" ]; then
            continue
        fi
        if [ "$i" -eq "$max_files" ]; then
            rm -f "$LOG_FILE.$i" || return 1
        else
            mv "$LOG_FILE.$i" "$LOG_FILE.$((i + 1))" || return 1
        fi
    done

    mv "$LOG_FILE" "$LOG_FILE.1" || return 1
    return 0
}

read_menu_extras_lines() {
    local raw_output
    local line
    local item

    raw_output=$(defaults read com.apple.systemuiserver menuExtras 2>/dev/null) || return 1

    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        if [[ "$line" != \"* ]]; then
            continue
        fi
        item="${line#\"}"
        item="${item%\",}"
        item="${item%\"}"
        printf '%s\n' "$item"
    done <<< "$raw_output"
}

mark_tm_menu_icon_added() {
    printf '%s\n' "added-by-script-epoch=$(date +%s)" > "$TM_MENU_STATE_FILE"
}

menu_extra_contains_time_machine() {
    read_menu_extras_lines | grep -Fxq "$TIME_MACHINE_MENU_EXTRA"
}

remove_tm_menu_icon_if_present() {
    local item
    local current_items=()
    local filtered_items=()

    if ! menu_extra_contains_time_machine; then
        return 0
    fi

    while IFS= read -r item; do
        current_items+=("$item")
    done < <(read_menu_extras_lines)

    if [ "${#current_items[@]}" -eq 0 ]; then
        log "Could not read current menu extras while removing Time Machine menu icon"
        return 1
    fi

    for item in "${current_items[@]}"; do
        if [ "$item" != "$TIME_MACHINE_MENU_EXTRA" ]; then
            filtered_items+=("$item")
        fi
    done

    if [ "${#filtered_items[@]}" -eq "${#current_items[@]}" ]; then
        return 0
    fi

    if [ "${#filtered_items[@]}" -eq 0 ]; then
        if ! defaults write com.apple.systemuiserver menuExtras -array >/dev/null 2>&1; then
            log "Failed to write updated menu extras while removing Time Machine menu icon"
            return 1
        fi
    else
        if ! defaults write com.apple.systemuiserver menuExtras -array "${filtered_items[@]}" >/dev/null 2>&1; then
            log "Failed to write updated menu extras while removing Time Machine menu icon"
            return 1
        fi
    fi
    if ! killall SystemUIServer >/dev/null 2>&1; then
        log "Could not restart SystemUIServer after menu extras update"
    fi
    return 0
}

show_tm_menu_icon_for_backup() {
    if [[ "$SHOW_MENUBAR_ICON_DURING_BACKUP" != true ]]; then
        return 0
    fi
    if menu_extra_contains_time_machine; then
        return 0
    fi

    if open -g "$TIME_MACHINE_MENU_EXTRA" >/dev/null 2>&1; then
        sleep 1
        if menu_extra_contains_time_machine; then
            TM_MENU_ICON_ADDED_BY_SCRIPT=true
            mark_tm_menu_icon_added
            log "Enabled Time Machine menu icon for active backup run"
        else
            log "Attempted to enable Time Machine menu icon, but verification failed"
        fi
    else
        log "Failed to launch Time Machine menu extra"
    fi
}

restore_tm_menu_icon_if_needed() {
    if [[ "$TM_MENU_ICON_ADDED_BY_SCRIPT" != true ]]; then
        rm -f "$TM_MENU_STATE_FILE"
        return 0
    fi

    if remove_tm_menu_icon_if_present; then
        log "Restored Time Machine menu icon setting after backup run"
    else
        log "Could not restore Time Machine menu icon state; leaving current menu extras unchanged"
    fi

    TM_MENU_ICON_ADDED_BY_SCRIPT=false
    rm -f "$TM_MENU_STATE_FILE"
}

recover_tm_menu_icon_state_if_needed() {
    if [ ! -f "$TM_MENU_STATE_FILE" ]; then
        return 0
    fi

    log "Found stale menu icon marker from an interrupted run; leaving menu extras unchanged to preserve user preference"
    rm -f "$TM_MENU_STATE_FILE"
}

diskutil_info_plist() {
    diskutil info -plist "$1" 2>/dev/null
}

extract_plist_value() {
    local key="$1"
    plutil -extract "$key" raw -o - - 2>/dev/null
}

mount_point_for_target() {
    local target="$1"
    local disk_info
    local mount_point

    disk_info=$(diskutil_info_plist "$target")
    if [ -z "$disk_info" ]; then
        return 1
    fi

    mount_point=$(printf '%s' "$disk_info" | extract_plist_value MountPoint)
    if [ -z "$mount_point" ]; then
        return 1
    fi

    printf '%s\n' "$mount_point"
}

device_identifier_for_target() {
    local target="$1"
    local disk_info
    local device_id

    disk_info=$(diskutil_info_plist "$target")
    if [ -z "$disk_info" ]; then
        return 1
    fi

    device_id=$(printf '%s' "$disk_info" | extract_plist_value DeviceIdentifier)
    if [ -z "$device_id" ]; then
        return 1
    fi

    printf '%s\n' "$device_id"
}

is_volume_mounted() {
    local target="$1"
    local mount_point

    mount_point=$(mount_point_for_target "$target") || return 1
    if [[ "$target" == /* ]] && [ "$mount_point" != "$target" ]; then
        return 1
    fi
    return 0
}

normalize_uuid() {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

sanitize_filename_component() {
    printf '%s' "$1" | tr -cd '[:alnum:]._-'
}

last_success_file_for_destination() {
    local dest_id="$1"
    local normalized
    local safe_id

    if [ -z "$dest_id" ]; then
        printf '%s\n' "$LEGACY_LAST_SUCCESS_FILE"
        return 0
    fi

    normalized=$(normalize_uuid "$dest_id")
    safe_id=$(sanitize_filename_component "$normalized")
    if [ -z "$safe_id" ]; then
        printf '%s\n' "$LEGACY_LAST_SUCCESS_FILE"
        return 0
    fi

    printf '%s/last-successful-backup.%s.epoch\n' "$STATE_DIR" "$safe_id"
}

initialize_destination_state_files() {
    local destination_file
    destination_file=$(last_success_file_for_destination "$1")
    LAST_SUCCESS_FILE="$destination_file"
}

append_destination_record() {
    local id="$1"
    local name="$2"
    local kind="$3"
    local mount_point="$4"

    if [ -z "$id" ] && [ -z "$name" ] && [ -z "$kind" ] && [ -z "$mount_point" ]; then
        return 0
    fi

    DEST_IDS+=("$id")
    DEST_NAMES+=("$name")
    DEST_KINDS+=("$kind")
    DEST_MOUNTS+=("$mount_point")
}

parse_destinations_from_info() {
    local info="$1"
    local idx=0
    local destination_dict
    local current_id
    local current_name
    local current_kind
    local current_mount

    DEST_IDS=()
    DEST_NAMES=()
    DEST_KINDS=()
    DEST_MOUNTS=()

    while :; do
        destination_dict=$(printf '%s' "$info" | plutil -extract "Destinations.$idx" xml1 -o - - 2>/dev/null || true)
        if [ -z "$destination_dict" ]; then
            break
        fi

        current_id=$(printf '%s' "$destination_dict" | plutil -extract ID raw -o - - 2>/dev/null || true)
        current_name=$(printf '%s' "$destination_dict" | plutil -extract Name raw -o - - 2>/dev/null || true)
        current_kind=$(printf '%s' "$destination_dict" | plutil -extract Kind raw -o - - 2>/dev/null || true)
        current_mount=$(printf '%s' "$destination_dict" | plutil -extract "Mount Point" raw -o - - 2>/dev/null || true)

        append_destination_record "$current_id" "$current_name" "$current_kind" "$current_mount"
        idx=$((idx + 1))
    done
}

resolve_mounted_path_for_destination() {
    local idx="$1"
    local mount_point

    mount_point="${DEST_MOUNTS[$idx]}"
    if [ -n "$mount_point" ] && is_volume_mounted "$mount_point"; then
        printf '%s\n' "$mount_point"
        return 0
    fi

    if [ -n "${DEST_NAMES[$idx]}" ]; then
        mount_point=$(mount_point_for_target "${DEST_NAMES[$idx]}" 2>/dev/null || true)
        if [ -n "$mount_point" ] && is_volume_mounted "$mount_point"; then
            printf '%s\n' "$mount_point"
            return 0
        fi
    fi

    if [ -n "${DEST_IDS[$idx]}" ]; then
        mount_point=$(mount_point_for_target "${DEST_IDS[$idx]}" 2>/dev/null || true)
        if [ -n "$mount_point" ] && is_volume_mounted "$mount_point"; then
            printf '%s\n' "$mount_point"
            return 0
        fi
    fi

    return 1
}

any_local_destination_mounted() {
    local idx

    for idx in "${!DEST_IDS[@]}"; do
        if [ "${DEST_KINDS[$idx]}" != "Local" ]; then
            continue
        fi
        if resolve_mounted_path_for_destination "$idx" >/dev/null 2>&1; then
            return 0
        fi
    done

    return 1
}

read_destination_info() {
    tmutil destinationinfo -X 2>/dev/null
}

find_destination_index() {
    local preferred_id="$1"
    local preferred_upper=""
    local idx

    if [ "${#DEST_IDS[@]}" -eq 0 ]; then
        return 1
    fi

    if [ -n "$preferred_id" ]; then
        preferred_upper=$(normalize_uuid "$preferred_id")
        for idx in "${!DEST_IDS[@]}"; do
            if [ "$(normalize_uuid "${DEST_IDS[$idx]}")" = "$preferred_upper" ]; then
                printf '%s\n' "$idx"
                return 0
            fi
        done
        return 1
    fi

    for idx in "${!DEST_IDS[@]}"; do
        if [ "${DEST_KINDS[$idx]}" = "Local" ] && resolve_mounted_path_for_destination "$idx" >/dev/null 2>&1; then
            printf '%s\n' "$idx"
            return 0
        fi
    done

    for idx in "${!DEST_IDS[@]}"; do
        if [ "${DEST_KINDS[$idx]}" = "Local" ]; then
            printf '%s\n' "$idx"
            return 0
        fi
    done

    return 1
}

attempt_mount_destination() {
    local dest_name="$1"
    local dest_mount="$2"
    local dest_id="$3"
    local candidate
    local device_id
    local mounted_path
    local candidates=()

    if [ -n "$dest_mount" ]; then
        candidates+=("$dest_mount")
    fi
    if [ -n "$dest_name" ]; then
        candidates+=("$dest_name")
    fi
    if [ -n "$dest_id" ]; then
        candidates+=("$dest_id")
    fi

    for candidate in "${candidates[@]}"; do
        mounted_path=$(mount_point_for_target "$candidate" 2>/dev/null || true)
        if [ -n "$mounted_path" ] && is_volume_mounted "$mounted_path"; then
            printf '%s\n' "$mounted_path"
            return 0
        fi

        device_id=$(device_identifier_for_target "$candidate" 2>/dev/null || true)
        if [ -z "$device_id" ]; then
            continue
        fi

        diskutil mount "$device_id" >/dev/null 2>&1 || true
        mounted_path=$(mount_point_for_target "$device_id" 2>/dev/null || true)
        if [ -n "$mounted_path" ] && is_volume_mounted "$mounted_path"; then
            printf '%s\n' "$mounted_path"
            return 0
        fi
    done

    return 1
}

cleanup() {
    restore_tm_menu_icon_if_needed
    rm -f "$LOCK_PID_FILE" "$LOCK_CREATED_FILE" "$LOCK_CMD_FILE" "$LOCK_START_FILE" 2>/dev/null
    rmdir "$LOCK_DIR" 2>/dev/null
}

safe_remove_lock_dir() {
    case "$LOCK_DIR" in
        "$HOME/Library/Caches/com.user.timemachine-auto.lock"|"$HOME/Library/Caches/"*/com.user.timemachine-auto.lock)
            ;;
        *)
            log "Refusing unsafe lock cleanup path: $LOCK_DIR"
            return 1
            ;;
    esac

    rm -rf "$LOCK_DIR" 2>/dev/null || return 1
    return 0
}

read_ps_command() {
    ps -p "$1" -o command= 2>/dev/null | head -n 1
}

read_ps_start_key() {
    ps -p "$1" -o lstart= 2>/dev/null | awk '{$1=$1; print}'
}

write_lock_metadata() {
    local current_cmd current_start
    printf '%s\n' "$$" > "$LOCK_PID_FILE"
    printf '%s\n' "$(date +%s)" > "$LOCK_CREATED_FILE"

    current_cmd=$(read_ps_command "$$")
    if [ -n "$current_cmd" ]; then
        printf '%s\n' "$current_cmd" > "$LOCK_CMD_FILE"
    fi

    current_start=$(read_ps_start_key "$$")
    if [ -n "$current_start" ]; then
        printf '%s\n' "$current_start" > "$LOCK_START_FILE"
    fi
}

is_lock_owner_active() {
    local pid="$1"
    local stored_cmd="$2"
    local stored_start="$3"
    local current_cmd current_start

    if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
        return 1
    fi

    current_cmd=$(read_ps_command "$pid")
    if [ -z "$current_cmd" ]; then
        return 1
    fi

    if [ -n "$stored_start" ]; then
        current_start=$(read_ps_start_key "$pid")
        if [ -z "$current_start" ] || [ "$current_start" != "$stored_start" ]; then
            return 1
        fi
    fi

    if [[ "$current_cmd" == *"timemachine-auto.sh"* ]]; then
        return 0
    fi

    if [ -n "$stored_cmd" ] && [ "$current_cmd" = "$stored_cmd" ]; then
        return 0
    fi

    return 1
}

acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        write_lock_metadata
        return 0
    fi

    if [ ! -d "$LOCK_DIR" ]; then
        log "Lock directory could not be created and does not exist; exiting"
        return 1
    fi

    local existing_pid
    local created_epoch
    local now_epoch
    local lock_age
    local existing_cmd
    local existing_start
    existing_pid=""
    created_epoch=""
    lock_age=""
    existing_cmd=""
    existing_start=""
    now_epoch=$(date +%s)

    if [ -f "$LOCK_PID_FILE" ]; then
        existing_pid=$(cat "$LOCK_PID_FILE" 2>/dev/null)
    fi

    if [ -f "$LOCK_CMD_FILE" ]; then
        existing_cmd=$(cat "$LOCK_CMD_FILE" 2>/dev/null)
    fi

    if [ -f "$LOCK_START_FILE" ]; then
        existing_start=$(cat "$LOCK_START_FILE" 2>/dev/null)
    fi

    if is_lock_owner_active "$existing_pid" "$existing_cmd" "$existing_start"; then
        log "Another run is already in progress (pid: $existing_pid); exiting"
        return 1
    fi

    if [ -f "$LOCK_CREATED_FILE" ]; then
        created_epoch=$(tr -d '[:space:]' < "$LOCK_CREATED_FILE" 2>/dev/null)
        if [[ "$created_epoch" =~ ^[0-9]+$ ]]; then
            lock_age=$((now_epoch - created_epoch))
        fi
    elif created_epoch=$(stat -f '%m' "$LOCK_DIR" 2>/dev/null); then
        if [[ "$created_epoch" =~ ^[0-9]+$ ]]; then
            lock_age=$((now_epoch - created_epoch))
        fi
    fi

    if [ -z "$existing_pid" ] || ! [[ "$existing_pid" =~ ^[0-9]+$ ]]; then
        if [[ "$lock_age" =~ ^[0-9]+$ ]]; then
            if [ "$lock_age" -lt "$MAX_LOCK_PID_WAIT_SECONDS" ]; then
                log "Lock exists without a valid PID and is only ${lock_age}s old; assuming active setup race, exiting"
                return 1
            fi
            if [ "$lock_age" -lt "$LOCK_STALE_SECONDS" ]; then
                log "Lock exists without a valid PID for ${lock_age}s; reclaiming stale setup-race lock"
            fi
        fi
    fi

    log "Removing stale lock (pid: ${existing_pid:-missing}, age: ${lock_age:-unknown}s)"
    rm -f "$LOCK_PID_FILE" "$LOCK_CREATED_FILE" "$LOCK_CMD_FILE" "$LOCK_START_FILE" 2>/dev/null
    if ! rmdir "$LOCK_DIR" 2>/dev/null; then
        log "Stale lock directory is not empty; attempting safe forced cleanup"
        if ! safe_remove_lock_dir; then
            log "Failed to remove stale lock directory safely; exiting"
            return 1
        fi
    fi

    if mkdir "$LOCK_DIR" 2>/dev/null; then
        write_lock_metadata
        return 0
    fi

    log "Could not acquire lock; exiting"
    return 1
}

backup_in_progress() {
    tmutil status 2>/dev/null | grep -q "Running = 1;"
}

wait_for_running_backup_to_finish() {
    local waited=0

    if ! backup_in_progress; then
        return 0
    fi

    log "Detected already-running Time Machine backup; waiting up to ${WAIT_FOR_RUNNING_BACKUP_MAX_SECONDS}s before eject decision"
    while backup_in_progress; do
        if [ "$waited" -ge "$WAIT_FOR_RUNNING_BACKUP_MAX_SECONDS" ]; then
            log "Backup still running after ${waited}s; leaving disk mounted for safety"
            return 1
        fi
        sleep "$RUNNING_BACKUP_POLL_SECONDS"
        waited=$((waited + RUNNING_BACKUP_POLL_SECONDS))
    done

    log "Detected completion of already-running Time Machine backup after ${waited}s"
    return 0
}

read_epoch_from_file() {
    local state_path="$1"
    local value
    if [ ! -f "$state_path" ]; then
        return 0
    fi
    value=$(tr -d '[:space:]' < "$state_path" 2>/dev/null)
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$value"
    fi
}

latest_snapshot_id_for_mount() {
    local mount_path="$1"
    local list_output
    local latest_output
    local snapshot_id

    list_output=$(tmutil listbackups -d "$mount_path" 2>/dev/null || true)
    snapshot_id=$(printf '%s\n' "$list_output" | grep -Eo '([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6})' | tail -n 1)

    if [ -z "$snapshot_id" ]; then
        latest_output=$(tmutil latestbackup -d "$mount_path" 2>/dev/null || true)
        snapshot_id=$(printf '%s\n' "$latest_output" | grep -Eo '([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6})' | tail -n 1)
    fi

    printf '%s\n' "$snapshot_id"
}

handle_successful_backup_completion() {
    local pre_backup_id="$1"
    local post_backup_id=""

    post_backup_id=$(latest_snapshot_id_for_mount "$TM_MOUNT")

    if [[ "$REQUIRE_SNAPSHOT_VERIFICATION" == true ]]; then
        if [ -z "$post_backup_id" ]; then
            log "Backup completed but snapshot verification is required and no snapshot ID was readable; leaving disk mounted for re-check"
            return 1
        fi
        if [ -n "$pre_backup_id" ] && [ "$post_backup_id" = "$pre_backup_id" ]; then
            log "Backup completed but snapshot verification is required and no new snapshot was detected; leaving disk mounted for re-check"
            return 1
        fi
    fi

    write_epoch_to_file "$LAST_SUCCESS_FILE" "$(date +%s)"
    if [ -n "$post_backup_id" ]; then
        log "Backup completed successfully (latest snapshot: $post_backup_id)"
    else
        log "Backup completed successfully (snapshot ID unavailable; proceeding by tmutil success exit code)"
    fi
    notify_user "Backup completed successfully" "Time Machine Auto-Backup" || true
    ALLOW_EJECT=true
    return 0
}

run_tmutil_startbackup_with_timeout() {
    local destination_id="$1"
    local timeout_seconds="$2"
    local poll_seconds=5
    local waited=0
    local start_status
    local start_waited=0
    local start_wait_limit=60

    BACKUP_OUTPUT=$(tmutil startbackup --auto --destination "$destination_id" 2>&1)
    start_status=$?
    if [ "$start_status" -ne 0 ]; then
        return "$start_status"
    fi

    # Allow a short window for backupd to flip into Running=1.
    while [ "$start_waited" -lt "$start_wait_limit" ] && ! backup_in_progress; do
        sleep 1
        start_waited=$((start_waited + 1))
    done

    while backup_in_progress; do
        if [ "$waited" -ge "$timeout_seconds" ]; then
            return 124
        fi
        sleep "$poll_seconds"
        waited=$((waited + poll_seconds))
    done

    return 0
}

write_epoch_to_file() {
    local state_path="$1"
    local epoch_value="$2"
    printf '%s\n' "$epoch_value" > "$state_path"
}

notify_fda_once_per_window() {
    local now_epoch last_notice age
    now_epoch=$(date +%s)
    last_notice=$(read_epoch_from_file "$FDA_NOTICE_FILE")
    if [[ "$last_notice" =~ ^[0-9]+$ ]]; then
        age=$((now_epoch - last_notice))
        if [ "$age" -ge 0 ] && [ "$age" -lt "$FDA_NOTIFY_COOLDOWN_SECONDS" ]; then
            return 1
        fi
    fi
    notify_user "Time Machine Auto-Backup needs Full Disk Access. Grant access in System Settings > Privacy & Security > Full Disk Access." "Time Machine Auto-Backup" "Basso" || true
    write_epoch_to_file "$FDA_NOTICE_FILE" "$now_epoch"
    return 0
}

attempt_eject() {
    local mount_path="$1"
    local attempt
    for ((attempt=1; attempt<=EJECT_RETRY_ATTEMPTS; attempt++)); do
        if backup_in_progress; then
            log "Backup is running during eject attempts; leaving disk mounted"
            return 2
        fi
        if ! is_volume_mounted "$mount_path"; then
            return 0
        fi

        log "Eject attempt $attempt/$EJECT_RETRY_ATTEMPTS for $mount_path"
        diskutil unmount "$mount_path" >/dev/null 2>&1 || true
        sleep 2
        if diskutil eject "$mount_path" >/dev/null 2>&1; then
            sleep 1
            if ! is_volume_mounted "$mount_path"; then
                return 0
            fi
        fi
        sleep 3
    done
    return 1
}

read_last_signature() {
    if [ ! -f "$STATE_FILE" ]; then
        return 0
    fi
    grep '^signature=' "$STATE_FILE" 2>/dev/null | head -n 1 | cut -d'=' -f2-
}

read_last_epoch() {
    if [ ! -f "$STATE_FILE" ]; then
        return 0
    fi
    grep '^epoch=' "$STATE_FILE" 2>/dev/null | head -n 1 | cut -d'=' -f2-
}

write_last_signature() {
    local signature="$1"
    printf 'signature=%s\nepoch=%s\n' "$signature" "$(date +%s)" > "$STATE_FILE"
}

validate_numeric_configs
validate_boolean_configs
validate_destination_config
validate_menu_icon_config

if ! acquire_lock; then
    exit 0
fi
trap cleanup INT TERM EXIT

if ! rotate_log_file_if_needed; then
    log "WARNING: Log rotation failed; continuing without rotation"
fi
recover_tm_menu_icon_state_if_needed

# Check if Time Machine destination is available
DEST_INFO=$(read_destination_info)
if [ $? -ne 0 ] || [ -z "$DEST_INFO" ]; then
    log "No Time Machine destination found, exiting"
    exit 0
fi

parse_destinations_from_info "$DEST_INFO"
if [ "${#DEST_IDS[@]}" -eq 0 ]; then
    log "No Time Machine destinations parsed from tmutil output, exiting"
    exit 0
fi

# Fast path: StartOnMount fires for any filesystem mount. If this event does not
# currently show a Time Machine mount point, exit quickly to avoid unnecessary
# sleep and extra processing on unrelated system mounts.
if [ "$ALLOW_AUTOMOUNT" != "true" ] && ! any_local_destination_mounted; then
    fast_wait_elapsed=0
    while [ "$fast_wait_elapsed" -lt "$FAST_PATH_WAIT_SECONDS" ] && ! any_local_destination_mounted; do
        sleep 1
        fast_wait_elapsed=$((fast_wait_elapsed + 1))
        DEST_INFO=$(read_destination_info)
        if [ $? -ne 0 ] || [ -z "$DEST_INFO" ]; then
            log "No Time Machine destination found, exiting"
            exit 0
        fi
        parse_destinations_from_info "$DEST_INFO"
    done

    if ! any_local_destination_mounted; then
        sleep 1
        DEST_INFO=$(read_destination_info)
        if [ $? -eq 0 ] && [ -n "$DEST_INFO" ]; then
            parse_destinations_from_info "$DEST_INFO"
        fi
    fi

    if ! any_local_destination_mounted; then
        exit 0
    fi
fi

# Wait for disk to fully mount only when this event appears relevant to Time Machine.
sleep 5

# Refresh destination info after mount settle delay.
DEST_INFO=$(read_destination_info)
if [ $? -ne 0 ] || [ -z "$DEST_INFO" ]; then
    log "No Time Machine destination found, exiting"
    exit 0
fi

parse_destinations_from_info "$DEST_INFO"
if [ "${#DEST_IDS[@]}" -eq 0 ]; then
    log "No Time Machine destinations parsed from tmutil output, exiting"
    exit 0
fi

LOCAL_DEST_COUNT=0
for idx in "${!DEST_IDS[@]}"; do
    if [ "${DEST_KINDS[$idx]}" = "Local" ]; then
        LOCAL_DEST_COUNT=$((LOCAL_DEST_COUNT + 1))
    fi
done

if [ "$LOCAL_DEST_COUNT" -gt 1 ] && [ -z "$PREFERRED_DESTINATION_ID" ]; then
    log "Multiple local Time Machine destinations detected ($LOCAL_DEST_COUNT). Set PREFERRED_DESTINATION_ID to avoid wrong-disk actions"
    notify_user "Multiple local Time Machine destinations detected. Edit ~/Library/Scripts/timemachine-auto.sh and set PREFERRED_DESTINATION_ID. You can find IDs with: tmutil destinationinfo -X" "Time Machine Auto-Backup" "Basso" || true
    exit 0
fi

DEST_INDEX=""
if [ -n "$PREFERRED_DESTINATION_ID" ]; then
    DEST_INDEX=$(find_destination_index "$PREFERRED_DESTINATION_ID" 2>/dev/null || true)
    if [ -z "$DEST_INDEX" ]; then
        log "Preferred destination ID not found ($PREFERRED_DESTINATION_ID); exiting to avoid acting on the wrong disk"
        exit 0
    fi
else
    DEST_INDEX=$(find_destination_index "" 2>/dev/null || true)
    if [ -z "$DEST_INDEX" ]; then
        log "No suitable local destination found in tmutil output, exiting"
        exit 0
    fi
fi

SELECTED_DEST_ID="${DEST_IDS[$DEST_INDEX]}"
SELECTED_DEST_NAME="${DEST_NAMES[$DEST_INDEX]}"
SELECTED_DEST_KIND="${DEST_KINDS[$DEST_INDEX]}"
SELECTED_DEST_MOUNT="${DEST_MOUNTS[$DEST_INDEX]}"
TM_MOUNT=""

if [ -z "$SELECTED_DEST_ID" ]; then
    log "Selected destination has no ID; exiting to avoid unpinned backup/eject behavior"
    exit 0
fi

initialize_destination_state_files "$SELECTED_DEST_ID"

TM_MOUNT=$(resolve_mounted_path_for_destination "$DEST_INDEX" 2>/dev/null || true)

if [ -z "$TM_MOUNT" ] && [ "$ALLOW_AUTOMOUNT" = "true" ]; then
    TM_MOUNT=$(attempt_mount_destination "$SELECTED_DEST_NAME" "$SELECTED_DEST_MOUNT" "$SELECTED_DEST_ID" 2>/dev/null || true)
    if [ -n "$TM_MOUNT" ]; then
        sleep 3
    fi
fi

if [ -z "$TM_MOUNT" ]; then
    log "Time Machine destination not mounted or not connected (name: ${SELECTED_DEST_NAME:-unknown}, id: ${SELECTED_DEST_ID:-unknown}), exiting"
    exit 0
fi

# Ignore duplicate triggers for a short window.
# StartOnMount fires for any mounted volume; this keeps unrelated mounts from
# immediately retriggering backup/eject for a disk we've just handled.
MOUNT_INODE=$(stat -f '%i' "$TM_MOUNT" 2>/dev/null)
if ! [[ "$MOUNT_INODE" =~ ^[0-9]+$ ]]; then
    MOUNT_INODE="ino-fallback-$(date +%s)-$$-$RANDOM"
    log "Could not determine mount inode for $TM_MOUNT; using fallback signature component"
fi
CURRENT_SIGNATURE="${SELECTED_DEST_ID:-unknown}|${TM_MOUNT}|${MOUNT_INODE:-unknown}"
LAST_SIGNATURE=$(read_last_signature)
LAST_EPOCH=$(read_last_epoch)
NOW_EPOCH=$(date +%s)
LAST_AGE="$DUPLICATE_WINDOW_SECONDS"
if [[ "$LAST_EPOCH" =~ ^[0-9]+$ ]]; then
    LAST_AGE=$((NOW_EPOCH - LAST_EPOCH))
fi
if [ -n "$LAST_SIGNATURE" ] && [ "$LAST_SIGNATURE" = "$CURRENT_SIGNATURE" ] \
    && [ "$LAST_AGE" -ge 0 ] && [ "$LAST_AGE" -lt "$DUPLICATE_WINDOW_SECONDS" ]; then
    log "Mount session recently handled ($TM_MOUNT); exiting duplicate trigger"
    exit 0
fi

log "Time Machine destination ready (name: ${SELECTED_DEST_NAME:-unknown}, id: ${SELECTED_DEST_ID:-unknown}) mounted at: $TM_MOUNT"

if backup_in_progress; then
    if ! wait_for_running_backup_to_finish; then
        log "Will retry while destination remains mounted (backup still in progress)"
        exit 0
    fi
    log "A previously running backup completed; continuing with destination-specific backup need evaluation"
fi

# Get backup history from the selected Time Machine destination if available.
LIST_OUTPUT=$(tmutil listbackups -d "$TM_MOUNT" 2>&1)
LIST_STATUS=$?
BACKUP_HISTORY_AVAILABLE=true
if [ "$LIST_STATUS" -ne 0 ]; then
    BACKUP_HISTORY_AVAILABLE=false
    if output_indicates_fda_issue "$LIST_OUTPUT"; then
        log "WARNING: Full Disk Access missing for this launchd context (tmutil listbackups blocked); using fallback schedule state"
        notify_fda_once_per_window || true
        if ! tmutil status >/dev/null 2>&1; then
            log "CRITICAL: Time Machine operations are blocked in this context; cannot proceed without Full Disk Access"
            notify_user "Time Machine Auto-Backup cannot run without Full Disk Access. Grant access in System Settings > Privacy & Security > Full Disk Access." "Time Machine Auto-Backup" "Basso" || true
            exit 1
        fi
    else
        log "WARNING: tmutil listbackups failed with exit code $LIST_STATUS; using fallback schedule state"
    fi
fi

LAST_BACKUP=""
if [ "$BACKUP_HISTORY_AVAILABLE" = "true" ]; then
    LAST_BACKUP=$(printf '%s\n' "$LIST_OUTPUT" | grep -Eo '([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6})' | tail -n 1)
    if [ -z "$LAST_BACKUP" ]; then
        LATEST_OUTPUT=$(tmutil latestbackup -d "$TM_MOUNT" 2>/dev/null || true)
        LAST_BACKUP=$(printf '%s\n' "$LATEST_OUTPUT" | grep -Eo '([0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6})' | tail -n 1)
    fi
fi
NEEDS_BACKUP=false
ALLOW_EJECT=false
THRESHOLD_SECONDS=$((BACKUP_THRESHOLD_HOURS * 60 * 60))
MAX_FALLBACK_STATE_AGE_SECONDS=$((MAX_FALLBACK_STATE_AGE_HOURS * 60 * 60))

# Determine if backup is needed
if [ "$BACKUP_HISTORY_AVAILABLE" = "false" ]; then
    LAST_SUCCESS_EPOCH=$(read_epoch_from_file "$LAST_SUCCESS_FILE")
    if [[ "$LAST_SUCCESS_EPOCH" =~ ^[0-9]+$ ]]; then
        CURRENT_TIME=$(date +%s)
        SECONDS_SINCE=$((CURRENT_TIME - LAST_SUCCESS_EPOCH))
        HOURS_SINCE=$((SECONDS_SINCE / 3600))
        log "Fallback state: last successful backup run was $HOURS_SINCE hours ago"
        if [ "$SECONDS_SINCE" -lt 0 ]; then
            NEEDS_BACKUP=true
        elif [ "$SECONDS_SINCE" -ge "$MAX_FALLBACK_STATE_AGE_SECONDS" ]; then
            log "Fallback state is older than $MAX_FALLBACK_STATE_AGE_HOURS hours; forcing backup attempt"
            NEEDS_BACKUP=true
        elif [ "$SECONDS_SINCE" -ge "$THRESHOLD_SECONDS" ]; then
            NEEDS_BACKUP=true
        else
            NEEDS_BACKUP=false
        fi
    else
        log "Fallback state has no prior successful backup timestamp. Starting backup..."
        NEEDS_BACKUP=true
    fi
elif [ -z "$LAST_BACKUP" ]; then
    log "No previous backup found. Starting backup..."
    NEEDS_BACKUP=true
else
    # Extract date from backup name (format: YYYY-MM-DD-HHMMSS)
    if [[ "$LAST_BACKUP" =~ ([0-9]{4})-([0-9]{2})-([0-9]{2})-([0-9]{6}) ]]; then
        YEAR="${BASH_REMATCH[1]}"
        MONTH="${BASH_REMATCH[2]}"
        DAY="${BASH_REMATCH[3]}"
        TIME="${BASH_REMATCH[4]}"

        HOUR="${TIME:0:2}"
        MINUTE="${TIME:2:2}"
        SECOND="${TIME:4:2}"

        BACKUP_DATE="$YEAR-$MONTH-$DAY $HOUR:$MINUTE:$SECOND"

        # Convert local backup timestamp to epoch.
        # Around DST shifts, local-time conversion can differ by about one hour.
        LAST_BACKUP_TIMESTAMP=$(date -j -f "%Y-%m-%d %H:%M:%S" "$BACKUP_DATE" "+%s" 2>/dev/null)

        if [[ "$LAST_BACKUP_TIMESTAMP" =~ ^[0-9]+$ ]]; then
            CURRENT_TIME=$(date +%s)
            SECONDS_SINCE=$((CURRENT_TIME - LAST_BACKUP_TIMESTAMP))
            HOURS_SINCE=$((SECONDS_SINCE / 3600))
            write_epoch_to_file "$LAST_SUCCESS_FILE" "$LAST_BACKUP_TIMESTAMP"
            log "Last backup: $BACKUP_DATE ($HOURS_SINCE hours ago)"

            if [ "$SECONDS_SINCE" -lt 0 ]; then
                log "Detected backup timestamp in the future; forcing backup check"
                NEEDS_BACKUP=true
            elif [ "$SECONDS_SINCE" -ge "$MAX_FALLBACK_STATE_AGE_SECONDS" ]; then
                log "Last backup age exceeded $MAX_FALLBACK_STATE_AGE_HOURS hours; forcing backup attempt"
                NEEDS_BACKUP=true
            elif [ "$SECONDS_SINCE" -ge "$THRESHOLD_SECONDS" ]; then
                NEEDS_BACKUP=true
            else
                NEEDS_BACKUP=false
            fi
        else
            log "Could not parse timestamp. Starting backup to be safe..."
            NEEDS_BACKUP=true
        fi
    else
        log "Could not parse backup date. Starting backup to be safe..."
        NEEDS_BACKUP=true
    fi
fi

# Perform backup if needed
if [[ "$NEEDS_BACKUP" == true ]]; then
    BACKUP_OUTPUT=""
    PRE_BACKUP_ID="$LAST_BACKUP"
    log "Starting Time Machine backup..."
    show_tm_menu_icon_for_backup

    run_tmutil_startbackup_with_timeout "$SELECTED_DEST_ID" "$BACKUP_BLOCK_TIMEOUT_SECONDS"
    BACKUP_RESULT=$?

    if [ "$BACKUP_RESULT" -eq 124 ]; then
        log "Backup is still running or unresolved after ${BACKUP_BLOCK_TIMEOUT_SECONDS}s. Keeping disk mounted for safety."
        notify_user "Backup is still running after $BACKUP_BLOCK_TIMEOUT_SECONDS seconds. Disk was left mounted." "Time Machine Auto-Backup" "Basso" || true
        exit 1
    elif [[ $BACKUP_RESULT -eq 0 ]]; then
        if ! handle_successful_backup_completion "$PRE_BACKUP_ID"; then
            exit 0
        fi
    else
        if printf '%s\n' "$BACKUP_OUTPUT" | grep -Eqi 'already running|Backup session is already running' || backup_in_progress; then
            log "tmutil reported an already-running backup while starting. Waiting for completion before eject decision."
            if ! wait_for_running_backup_to_finish; then
                log "Will retry while destination remains mounted (backup still in progress)"
                exit 0
            fi
            log "Retrying destination-specific backup now that the running session has finished"
            run_tmutil_startbackup_with_timeout "$SELECTED_DEST_ID" "$BACKUP_BLOCK_TIMEOUT_SECONDS"
            BACKUP_RESULT=$?

            if [ "$BACKUP_RESULT" -eq 124 ]; then
                log "Retry backup timed out after ${BACKUP_BLOCK_TIMEOUT_SECONDS}s. Keeping disk mounted for safety."
                notify_user "Backup retry timed out after $BACKUP_BLOCK_TIMEOUT_SECONDS seconds. Disk was left mounted." "Time Machine Auto-Backup" "Basso" || true
                exit 1
            elif [ "$BACKUP_RESULT" -eq 0 ]; then
                if ! handle_successful_backup_completion "$PRE_BACKUP_ID"; then
                    exit 0
                fi
            else
                log "Backup retry failed with exit code: $BACKUP_RESULT. Keeping disk mounted for safety."
                notify_user "Backup retry failed (exit code: $BACKUP_RESULT). Disk was left mounted." "Time Machine Auto-Backup" "Basso" || true
                exit 1
            fi
        else
            if output_indicates_fda_issue "$BACKUP_OUTPUT"; then
                log "CRITICAL: Time Machine backup command was blocked by Full Disk Access restrictions"
                notify_fda_once_per_window || true
            fi
            log "Backup failed with exit code: $BACKUP_RESULT. Keeping disk mounted for safety."
            notify_user "Backup failed (exit code: $BACKUP_RESULT). Disk was left mounted." "Time Machine Auto-Backup" "Basso" || true
            exit 1
        fi
    fi
else
    log "Backup not needed (threshold: $BACKUP_THRESHOLD_HOURS hours)"
    if [[ "$EJECT_WHEN_NO_BACKUP" == true ]]; then
        ALLOW_EJECT=true
    else
        log "Leaving disk mounted because EJECT_WHEN_NO_BACKUP=false"
        ALLOW_EJECT=false
    fi
fi

if [[ "$ALLOW_EJECT" == true ]]; then
    # Wait before ejecting
    sleep "$EJECT_PRECHECK_DELAY_SECONDS"

    if backup_in_progress; then
        log "Backup is running at eject check; leaving disk mounted"
        exit 0
    fi

    if ! is_volume_mounted "$TM_MOUNT"; then
        log "Disk already unmounted before eject step"
        write_last_signature "$CURRENT_SIGNATURE"
        exit 0
    fi

    # Eject the disk with retries
    log "Ejecting $TM_MOUNT..."
    attempt_eject "$TM_MOUNT"
    EJECT_RESULT=$?
    if [ "$EJECT_RESULT" -eq 0 ]; then
        log "Disk ejected successfully"
        write_last_signature "$CURRENT_SIGNATURE"
    elif [ "$EJECT_RESULT" -eq 2 ]; then
        log "Backup resumed during eject attempts; leaving disk mounted"
        exit 0
    else
        log "Failed to eject disk after $EJECT_RETRY_ATTEMPTS attempts (may still be in use)"
        rm -f "$STATE_FILE"
        notify_user "Time Machine disk could not be ejected and will be retried on the next run." "Time Machine Auto-Backup" "Basso" || true
        exit 1
    fi
else
    write_last_signature "$CURRENT_SIGNATURE"
fi
