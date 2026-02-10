# Time Machine Auto-Backup (macOS LaunchAgent)

Automates Time Machine backups when your backup disk mounts, and can eject the disk after backup/no-backup decisions.

This project is based on two files:

- `timemachine-auto.sh`
- `com.user.timemachine-auto.plist`

## What It Does

- Runs via `launchd` when:
  - any volume mounts (`StartOnMount`)
  - your user session loads (`RunAtLoad`)
  - every 30 minutes (`StartInterval = 1800`)
- Detects Time Machine destinations using `tmutil destinationinfo -X`.
- Selects a local destination (or a preferred destination ID if configured).
- Decides whether a backup is needed based on `BACKUP_THRESHOLD_HOURS` and backup history/fallback state.
- Runs `tmutil startbackup --auto --destination <ID>` with timeout handling.
- Optionally ejects the Time Machine disk after completion or when no backup is needed.
- Writes logs and state files for reliability, duplicate-trigger suppression, and stale-lock recovery.

## Requirements

- macOS (only tested on 26.2)
- A configured local Time Machine destination

## Files and Runtime Paths

The script is designed to run from:

- `~/Library/Scripts/timemachine-auto.sh`
- `~/Library/LaunchAgents/com.user.timemachine-auto.plist`

Runtime paths used by the script:

- Log file: `~/Library/Logs/AutoTMLogs/tm-auto-backup.log`
- State directory: `~/Library/Application Support/TimeMachineAuto`
- Lock directory: `~/Library/Caches/com.user.timemachine-auto.lock`

## Install

1. Copy script:
   - `mkdir -p "$HOME/Library/Scripts"`
   - `cp timemachine-auto.sh "$HOME/Library/Scripts/timemachine-auto.sh"`
   - `chmod +x "$HOME/Library/Scripts/timemachine-auto.sh"`
2. Copy LaunchAgent plist:
   - `mkdir -p "$HOME/Library/LaunchAgents"`
   - `cp com.user.timemachine-auto.plist "$HOME/Library/LaunchAgents/com.user.timemachine-auto.plist"`
3. Load agent:
   - `launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.user.timemachine-auto.plist"`

## Common Commands

- Unload/disable:
  - `launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.user.timemachine-auto.plist"`
- Load/enable:
  - `launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.user.timemachine-auto.plist"`
- Run once now:
  - `launchctl kickstart -k "gui/$(id -u)/com.user.timemachine-auto"`
- Agent status:
  - `launchctl print "gui/$(id -u)/com.user.timemachine-auto"`
- Manual script run:
  - `"$HOME/Library/Scripts/timemachine-auto.sh"`
- Destination info:
  - `tmutil destinationinfo -X`
- Tail logs:
  - `tail -f "$HOME/Library/Logs/AutoTMLogs/tm-auto-backup.log"`

## Configuration

Edit config variables at the top of `timemachine-auto.sh`.

Frequently tuned settings:

- `BACKUP_THRESHOLD_HOURS=72`
- `EJECT_WHEN_NO_BACKUP=true`
- `SHOW_MENUBAR_ICON_DURING_BACKUP=true`
- `ALLOW_AUTOMOUNT=false`
- `PREFERRED_DESTINATION_ID=""`
- `REQUIRE_SNAPSHOT_VERIFICATION=false`

Selected reliability/time controls:

- `DUPLICATE_WINDOW_SECONDS=120`
- `WAIT_FOR_RUNNING_BACKUP_MAX_SECONDS=7200`
- `BACKUP_BLOCK_TIMEOUT_SECONDS=14400`
- `EJECT_RETRY_ATTEMPTS=3`
- `LOCK_STALE_SECONDS=1200`

## Troubleshooting

- If no destination is found, verify Time Machine destination setup:
  - `tmutil destinationinfo -X`
- If multiple local destinations exist, set:
  - `PREFERRED_DESTINATION_ID="<destination-uuid>"`
- If operations are blocked by permissions, grant Full Disk Access to the app/shell context running this LaunchAgent.
- If eject fails, the script retries and logs failures; check:
  - `~/Library/Logs/AutoTMLogs/tm-auto-backup.log`

## Uninstall

1. `launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.user.timemachine-auto.plist"`
2. `rm -f "$HOME/Library/LaunchAgents/com.user.timemachine-auto.plist"`
3. `rm -f "$HOME/Library/Scripts/timemachine-auto.sh"`
4. `rm -rf "$HOME/Library/Application Support/TimeMachineAuto" "$HOME/Library/Caches/com.user.timemachine-auto.lock" "$HOME/Library/Logs/AutoTMLogs"`
