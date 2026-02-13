# Time Machine Auto-Backup

Behavior:
- `launchd` triggers a script on login and any volume mount.
- The script asks macOS to decide backup timing with `tmutil startbackup --auto --block`.
- If macOS starts (or is already running) a backup, the script waits for completion and then unmounts the disk.
- If macOS does not start a backup, the script unmounts the Time Machine disk.

## Requirements
- macOS 10.13 (High Sierra) or later
- Time Machine already configured with at least one local destination
- Full Disk Access granted to the process running the script (feel free to audit it!)
- Script runs as a per-user LaunchAgent (not a daemon)

## Install
Use either Finder drag-and-drop or Terminal.

<details>

<summary> Option A: Finder (Drag-and-Drop)</summary>

1. Open the folder containing these files:
   - `timemachine-auto.sh`
   - `com.user.timemachine-auto.plist`
2. In Finder, press `Shift+Command+G` and open: `~/Library/Scripts`
   - Create the folder if it does not exist.
3. Drag `timemachine-auto.sh` into `~/Library/Scripts/`.
4. In Finder, press `Shift+Command+G` and open: `~/Library/LaunchAgents`
   - Create the folder if it does not exist.
5. Drag `com.user.timemachine-auto.plist` into `~/Library/LaunchAgents/`.
6. Open Terminal and run:
```bash
chmod +x "$HOME/Library/Scripts/timemachine-auto.sh"
```
7. Load the LaunchAgent:
```bash
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.user.timemachine-auto.plist"
```
</details>

<details>

<summary>Option B: Terminal</summary>
Important: run these commands from the directory that contains this README, `timemachine-auto.sh`, and `com.user.timemachine-auto.plist`.

```bash
# Go to folder with script + plist
cd "/path/to/folder-containing-these-files"

# Create script destination folder if missing
mkdir -p "$HOME/Library/Scripts"

# Copy script
cp ./timemachine-auto.sh "$HOME/Library/Scripts/timemachine-auto.sh"

# Make script executable
chmod +x "$HOME/Library/Scripts/timemachine-auto.sh"

# Create LaunchAgent folder if missing
mkdir -p "$HOME/Library/LaunchAgents"

# Install plist
cp ./com.user.timemachine-auto.plist "$HOME/Library/LaunchAgents/com.user.timemachine-auto.plist"

# Load LaunchAgent (Automates the triggering of timemachine-auto.sh)
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.user.timemachine-auto.plist"

# Unload LaunchAgent (Disable the auto triggering of timemachine-auto.sh)
launchctl bootout "gui/$(id -u)"/com.user.timemachine-auto 2>/dev/null || true

# Optional: This command just ensures if the LaunchAgent is enabled
launchctl enable "gui/$(id -u)"/com.user.timemachine-auto
```
</details>

## Things to Note
#### Full Disk Access
- Grant Full Disk Access in System Settings -> Privacy & Security -> Full Disk Access. Add entries based on how you run the script:
  - Manual runs: add your terminal app (Terminal, iTerm, etc.).
  - Automatic LaunchAgent runs: add `/bin/bash` (the .plist runs the script through `/bin/bash`).
- After adding entries:
  - Ensure each toggle is ON.
  - Quit and reopen the added app(s).
  - Reload the LaunchAgent (bootout/bootstrap) before re-testing.
- Common related errors in logs:
  - `Operation not permitted`
  - `Full Disk Access`
  - `not authorized`
  - `access denied`

#### Multiple Destinations
- This script is designed for single local Time Machine destination setups. If you have multiple local destinations:
  - Set `PREFERRED_DESTINATION_ID` to the one you want managed.
  - Get IDs with `tmutil destinationinfo`.
- If you have network destinations (iCloud, Time Capsule, NAS):
  - The script waits for ANY backup to complete, not only local disk backup.
  - This is safe but may keep local disk mounted longer than necessary.

#### StartOnMount Note
- `StartOnMount` triggers for all mounted volumes (USB, DMG, network, etc.).
- The script exits quickly when the configured local Time Machine disk is not mounted.

#### First Run vs Later Runs
- First run after mount evaluates destination, runs macOS auto decision, waits if needed, then unmounts.
- If another instance is already running, lock protection makes the new trigger exit.
- If a stale lock exists without a PID and is at least 60 seconds old, the script reclaims it and continues.

## Configuration

### Script Configuration (`timemachine-auto.sh`)
User config block:
- `PREFERRED_DESTINATION_ID=""`
  - Optional destination UUID. Get destination IDs with `tmutil destinationinfo`. Leave empty to auto-select when exactly one local destination is configured.
  - Rules: Must be a full UUID format: `XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX` (hex digits). If format is invalid, script logs an error, shows a notification, and exits
- `BACKUP_POLL_SECONDS=15`
  - Poll interval while checking backup status.
- `BACKUP_MAX_WAIT_SECONDS=43200`
  - Maximum total wait for an active backup before leaving disk mounted.
- `POST_BACKUP_SETTLE_SECONDS=10`
  - Delay after backup completes before unmount, to let final I/O settle.
- `UNMOUNT_RETRY_ATTEMPTS=3`
  - Number of unmount retries before failure.
- `LOCK_STALE_SECONDS=21600`
  - Lock age threshold before a stale lock is reclaimed.
- `LOCK_REFRESH_SECONDS=600`
  - How often to refresh lock metadata while waiting in long-running loops.

Backward compatibility:
- If `EJECT_RETRY_ATTEMPTS` is set, it overrides `UNMOUNT_RETRY_ATTEMPTS`.

Logging behavior:
- Log file rotates at 1 MiB.
- Up to 3 rotated files are kept (`.1`, `.2`, `.3`).

### Configuration Examples
Default (good for most users):
```bash
PREFERRED_DESTINATION_ID=""
BACKUP_POLL_SECONDS=15
BACKUP_MAX_WAIT_SECONDS=43200
POST_BACKUP_SETTLE_SECONDS=10
UNMOUNT_RETRY_ATTEMPTS=3
LOCK_STALE_SECONDS=21600
LOCK_REFRESH_SECONDS=600
```

Less frequent status polling:
```bash
BACKUP_POLL_SECONDS=30
```

Very large first backup:
```bash
BACKUP_MAX_WAIT_SECONDS=86400
LOCK_STALE_SECONDS=86400
```

## Troubleshooting
```bash
# Check LaunchAgent status
launchctl print "gui/$(id -u)"/com.user.timemachine-auto

# Check running script process
ps aux | grep '[t]imemachine-auto.sh'

# Follow logs live with this command, open the log file itself, or find it in Console.app -> Log Reports -> tm-auto-backup.log
tail -f "$HOME/Library/Logs/AutoTMLogs/tm-auto-backup.log"

# Manual one-off test run
"$HOME/Library/Scripts/timemachine-auto.sh"

# Find open files blocking unmount
lsof +D "/Volumes/<YourTMVolumeName>"

# Reset state file
rm -f "$HOME/Library/Application Support/TimeMachineAuto/last-processed-mount.state"

# Clear lock if needed
rm -rf "$HOME/Library/Caches/com.user.timemachine-auto.lock"
```
