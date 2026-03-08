# AutoUnmountTM (macOS Time Machine Auto-Unmount)

## Purpose

When a Time Machine disk is mounted, macOS decides whether a backup is due based on native Time Machine scheduling. This automation triggers that decision, waits for backup completion when needed, and then unmounts the Time Machine volume so dock unplugging is safer and less manual.

## Behavior Contract

On each trigger run:

1. Detect mounted local Time Machine destination(s).
2. Ask macOS for the normal backup decision:
   - `tmutil startbackup --auto --block --destination <ID>`
3. If backup is running, wait until it finishes.
4. Unmount the Time Machine volume.

Expected outcomes:

- Backup due: backup runs, script waits, then unmounts.
- Backup not due: script unmounts.
- Backup already in progress: script waits, then unmounts.

## How The Automation Actually Runs

- `launchd` watches for mount events (`StartOnMount`).
- On each mount event, it starts `AutoUnmountTM.swift`.
- The script runs one full cycle:
  - ask Time Machine to decide backup (`tmutil startbackup --auto --block`)
  - wait if backup is running
  - unmount the Time Machine volume
- The script exits.
- On the next mount event, `launchd` starts it again.

This is intentional. No always-running daemon process is required.

## What You Do Once vs What Happens Automatically

You do once:

- Run install commands (copy script + create/load LaunchAgent).
- Grant Full Disk Access for the launch context.

Then it is automatic:

- Trigger on mount
- Backup due/not-due decision
- Wait for backup completion
- Volume unmount with retries and safety checks

## Requirements

- macOS with Time Machine configured
- At least one local Time Machine destination
- `swift`, `tmutil`, `diskutil`, `launchctl`
- Full Disk Access granted to the relevant run context

## Install + Enable Automation (Copy/Paste)

Run these commands from the directory that contains `AutoUnmountTM.swift`:

```bash
# 1) Install script into user Library
mkdir -p "$HOME/Library/Scripts"
cp ./AutoUnmountTM.swift "$HOME/Library/Scripts/AutoUnmountTM.swift"
chmod +x "$HOME/Library/Scripts/AutoUnmountTM.swift"

# 2) Write LaunchAgent
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$HOME/Library/LaunchAgents/com.user.autounmounttm.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.user.autounmounttm</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>-lc</string>
    <string>exec /usr/bin/swift "$HOME/Library/Scripts/AutoUnmountTM.swift"</string>
  </array>

  <key>StartOnMount</key>
  <true/>

  <key>RunAtLoad</key>
  <true/>

  <key>StandardOutPath</key>
  <string>/tmp/AutoUnmountTM.log</string>

  <key>StandardErrorPath</key>
  <string>/tmp/AutoUnmountTM.log</string>
</dict>
</plist>
PLIST

# 3) Reload agent cleanly
launchctl bootout "gui/$(id -u)"/com.user.autounmounttm 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.user.autounmounttm.plist"
launchctl enable "gui/$(id -u)"/com.user.autounmounttm

# 4) Verify loaded
launchctl print "gui/$(id -u)"/com.user.autounmounttm

# 5) Optional immediate test run (does not wait for next mount event)
launchctl kickstart -k "gui/$(id -u)/com.user.autounmounttm"
```

## Full Disk Access (Critical)

Grant Full Disk Access to the process context that runs the script. If using the LaunchAgent above, add and enable:

- `/bin/zsh`
- `/usr/bin/swift`

Then restart affected apps/session and reload the LaunchAgent.

## Configuration (in `AutoUnmountTM.swift`)

- `preferredDestinationID`: optional UUID pinning when multiple local TM destinations exist
- `backupPollSeconds`: polling interval while waiting for running backup
- `backupMaxWaitSeconds`: max wait for completion before fail-safe exit
- `startBackupRetryCount`: additional retries after initial `startbackup` attempt
- `retryDelaySeconds`: delay between retries
- `unmountRetryAttempts`: unmount retries
- `lockPath`: single-instance lock file path

## Manual Run (One-Off)

```bash
/usr/bin/swift "$HOME/Library/Scripts/AutoUnmountTM.swift"
```

## Troubleshooting (Symptom -> Cause -> Fix)

- `Operation not permitted`, `not authorized`, `access denied`, `Full Disk Access`
  - Cause: missing FDA permissions
  - Fix: grant FDA for launch context binaries and reload agent

- `The backup disk is not available`
  - Cause: disk mounted but not recognized as configured TM destination, or destination config mismatch
  - Fix: verify with `tmutil destinationinfo -X`, confirm TM settings, remount disk

- Unmount fails
  - Cause: files/processes still using mount
  - Fix: `lsof +D "/Volumes/<YourTMVolumeName>"` and close blockers

- Agent appears idle
  - Cause: waiting for mount event, not a continuous daemon loop
  - Fix: `launchctl kickstart -k "gui/$(id -u)/com.user.autounmounttm"` for immediate run

## Logs and Diagnostics

```bash
# Agent status
launchctl print "gui/$(id -u)"/com.user.autounmounttm

# Follow the single runtime log file
tail -f /tmp/AutoUnmountTM.log

# Time Machine visibility checks
tmutil destinationinfo -X
tmutil status -X
```

Console note:

- Console.app "Log Reports" is for crash/diagnostic reports, not this runtime log file.
- This automation writes operational logs to `/tmp/AutoUnmountTM.log`.


## Uninstall

```bash
launchctl bootout "gui/$(id -u)"/com.user.autounmounttm 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.user.autounmounttm.plist"
rm -f "$HOME/Library/Scripts/AutoUnmountTM.swift"
rm -f /tmp/AutoUnmountTM.log
```

## Important Note

This automation unmounts the Time Machine volume. It does not eject every device/volume connected to a dock. If other mounted devices remain active, macOS may still show unplug warnings for those devices.
