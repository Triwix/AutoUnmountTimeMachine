#!/bin/bash

# Time Machine Auto-Backup Script
# Automatically backs up when Time Machine disk is mounted
# 
# Configuration:
# - BACKUP_THRESHOLD_DAYS: Minimum days between backups (default: 3)
# - Runs on disk mount and at login
# - Logs to: ~/Library/Logs/AutoTMLogs/tm-auto-backup.log
#
# To disable: launchctl unload ~/Library/LaunchAgents/com.user.timemachine-auto.plist
# To enable: launchctl load ~/Library/LaunchAgents/com.user.timemachine-auto.plist

# Configuration
BACKUP_THRESHOLD_DAYS=3
LOG_FILE="$HOME/Library/Logs/AutoTMLogs/tm-auto-backup.log"

# Create log directory if it doesn't exist
mkdir -p "$(dirname "$LOG_FILE")"

# Log function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Wait for disk to fully mount
sleep 5

# Check if Time Machine destination is available
if ! tmutil destinationinfo &> /dev/null; then
    log "No Time Machine destination found, exiting"
    exit 0
fi

# Get the Time Machine disk mount point
TM_MOUNT=$(tmutil destinationinfo | grep "Mount Point" | awk -F': ' '{print $2}' | xargs)

# Exit if disk isn't actually mounted
if [ -z "$TM_MOUNT" ]; then
    log "Time Machine destination configured but disk not mounted, exiting"
    exit 0
fi

log "Time Machine disk mounted at: $TM_MOUNT"

# Get the last backup
LAST_BACKUP=$(tmutil listbackups 2>/dev/null | tail -1)

# Determine if backup is needed
if [ -z "$LAST_BACKUP" ]; then
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
        
        # Convert to timestamp
        LAST_BACKUP_TIMESTAMP=$(date -j -f "%Y-%m-%d %H:%M:%S" "$BACKUP_DATE" "+%s" 2>/dev/null)
        
        if [[ "$LAST_BACKUP_TIMESTAMP" =~ ^[0-9]+$ ]]; then
            CURRENT_TIME=$(date +%s)
            SECONDS_SINCE=$((CURRENT_TIME - LAST_BACKUP_TIMESTAMP))
            DAYS_SINCE=$((SECONDS_SINCE / 86400))
            HOURS_SINCE=$((SECONDS_SINCE / 3600))
            THRESHOLD_SECONDS=$((BACKUP_THRESHOLD_DAYS * 24 * 60 * 60))
            
            log "Last backup: $BACKUP_DATE ($DAYS_SINCE days, $HOURS_SINCE hours ago)"
            
            if [ $SECONDS_SINCE -gt $THRESHOLD_SECONDS ]; then
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
    log "Starting Time Machine backup..."
    
    tmutil startbackup --auto --block
    BACKUP_RESULT=$?
    
    if [[ $BACKUP_RESULT -eq 0 ]]; then
        log "Backup completed successfully"
        osascript -e 'display notification "Backup completed successfully" with title "Time Machine Auto-Backup"'
    else
        log "Backup finished with exit code: $BACKUP_RESULT"
        osascript -e "display notification \"Backup may have failed (exit code: $BACKUP_RESULT)\" with title \"Time Machine Auto-Backup\" sound name \"Basso\""
    fi
else
    log "Backup not needed (threshold: $BACKUP_THRESHOLD_DAYS days)"
fi

# Wait before ejecting
sleep 5

# Eject the disk
log "Ejecting $TM_MOUNT..."
diskutil eject "$TM_MOUNT"

if [[ $? -eq 0 ]]; then
    log "Disk ejected successfully"
else
    log "Failed to eject disk (may still be in use)"
    osascript -e 'display notification "Time Machine disk could not be ejected" with title "Time Machine Auto-Backup" sound name "Basso"'
fi
