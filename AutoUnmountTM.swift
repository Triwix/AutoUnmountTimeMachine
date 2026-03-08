#!/usr/bin/swift
import Foundation
import Darwin

// MARK: - Configuration
let preferredDestinationID: String? = nil
let backupPollSeconds: UInt32 = 15
let backupMaxWaitSeconds: UInt32 = 43_200
let startBackupRetryCount = 1 // Additional retries after the first attempt (1 => up to 2 total attempts).
let retryDelaySeconds: UInt32 = 2
let unmountRetryAttempts = 3
let lockPath = "/tmp/com.user.AutoUnmountTM.lock"

// MARK: - Types
struct TMDestination {
    let id: String
    let name: String
    let kind: String
    let mountPoint: String?
    let lastDestination: Int?
}

enum BackupDecisionOutcome {
    case backupCompletedThisRun
    case noNewBackupDetectedLikelyNotDue
    case decisionCompletedButOutcomeUnclassified
}

enum ScriptError: Error, CustomStringConvertible {
    case commandFailed([String], Int32, String)
    case fullDiskAccessRequired(String)
    case malformedPlist(String)
    case ambiguousDestination([String])
    case destinationNotFound(String)
    case noMountedLocalDestination
    case backupTimeout(UInt32)
    case unmountFailed(String)

    var description: String {
        switch self {
        case .commandFailed(let args, let code, let details):
            return "Command failed (\(code)): \(args.joined(separator: " "))\(details.isEmpty ? "" : " | \(details)")"
        case .fullDiskAccessRequired(let details):
            return details
        case .malformedPlist(let context):
            return "Malformed plist data: \(context)"
        case .ambiguousDestination(let names):
            return "Ambiguous local Time Machine destinations: \(names.joined(separator: ", "))"
        case .destinationNotFound(let id):
            return "Preferred destination ID not found or not mounted: \(id)"
        case .noMountedLocalDestination:
            return "No mounted local Time Machine destination detected."
        case .backupTimeout(let seconds):
            return "Backup still running after \(seconds)s; leaving disk mounted."
        case .unmountFailed(let mountPoint):
            return "Failed to unmount \(mountPoint) after \(unmountRetryAttempts) attempts."
        }
    }
}

enum ExitCode {
    case success
    case softSkip
    case failure

    var code: Int32 {
        switch self {
        case .success, .softSkip:
            return 0
        case .failure:
            return 1
        }
    }
}

// MARK: - Logging
let logDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

let mergedLogPath = "/tmp/AutoUnmountTM.log"

func appendToMergedLog(_ line: String) {
    let data = Data((line + "\n").utf8)
    let mode: mode_t = S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH
    let fd = open(mergedLogPath, O_CREAT | O_WRONLY | O_APPEND, mode)
    guard fd >= 0 else {
        // Last-resort visibility if file append fails.
        print(line)
        return
    }
    _ = data.withUnsafeBytes { buffer in
        guard let ptr = buffer.baseAddress else { return 0 }
        return write(fd, ptr, buffer.count)
    }
    close(fd)
}

func log(_ message: String) {
    let ts = logDateFormatter.string(from: Date())
    let line = "[\(ts)] \(message)"
    appendToMergedLog(line)
    if isatty(STDOUT_FILENO) == 1 {
        print(line)
    }
}

// MARK: - Shell
func run(_ args: [String]) -> (status: Int32, stdout: String, stderr: String) {
    precondition(!args.isEmpty, "run(_:) requires at least one argument (executable path)")

    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    process.executableURL = URL(fileURLWithPath: args[0])
    process.arguments = Array(args.dropFirst())
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return (1, "", "Failed to launch process: \(error.localizedDescription)")
    }

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
    let stderr = String(data: stderrData, encoding: .utf8) ?? ""

    return (process.terminationStatus, stdout, stderr)
}

func combinedOutput(stdout: String, stderr: String) -> String {
    [stdout.trimmingCharacters(in: .whitespacesAndNewlines), stderr.trimmingCharacters(in: .whitespacesAndNewlines)]
        .filter { !$0.isEmpty }
        .joined(separator: " | ")
}

func looksLikeFullDiskAccessError(_ output: String) -> Bool {
    let lower = output.lowercased()
    let indicators = [
        "full disk access",
        "operation not permitted",
        "permission denied",
        "not authorized",
        "authorization denied",
        "access denied",
        "insufficient privileges",
    ]
    return indicators.contains(where: { lower.contains($0) })
}

func tmutilError(_ args: [String], status: Int32, stdout: String, stderr: String) -> ScriptError {
    let details = combinedOutput(stdout: stdout, stderr: stderr)
    if looksLikeFullDiskAccessError(details) {
        let command = args.joined(separator: " ")
        return .fullDiskAccessRequired(
            "Time Machine command appears blocked by permissions. Grant Full Disk Access to the runner context (Terminal/iTerm or launchd parent process), then retry. Command: \(command)\(details.isEmpty ? "" : " | \(details)")"
        )
    }
    return .commandFailed(args, status, details)
}

// MARK: - Locking
struct LockState {
    let pid: Int32?
    let createdAt: TimeInterval?
}

func readLockState(from path: String) -> LockState {
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
        return LockState(pid: nil, createdAt: nil)
    }

    var pid: Int32?
    var createdAt: TimeInterval?
    for line in raw.split(separator: "\n") {
        let parts = line.split(separator: "=", maxSplits: 1)
        if parts.count != 2 { continue }
        let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        if key == "pid", let parsed = Int32(value) {
            pid = parsed
        } else if key == "created", let parsed = TimeInterval(value) {
            createdAt = parsed
        }
    }

    return LockState(pid: pid, createdAt: createdAt)
}

func isProcessAlive(_ pid: Int32) -> Bool {
    if pid <= 0 { return false }
    if kill(pid, 0) == 0 { return true }
    return errno != ESRCH
}

func writeLockFile(fd: Int32) {
    let payload = "pid=\(getpid())\ncreated=\(Date().timeIntervalSince1970)\n"
    _ = payload.withCString { ptr in
        write(fd, ptr, strlen(ptr))
    }
}

func acquireLock(at path: String) -> Bool {
    let mode: mode_t = S_IRUSR | S_IWUSR

    while true {
        let fd = open(path, O_CREAT | O_EXCL | O_WRONLY, mode)
        if fd >= 0 {
            writeLockFile(fd: fd)
            close(fd)
            log("Lock acquired: \(path)")
            return true
        }

        if errno != EEXIST {
            log("Failed to create lock file \(path): errno \(errno)")
            return false
        }

        let lock = readLockState(from: path)
        if let pid = lock.pid, isProcessAlive(pid) {
            log("Another AutoUnmountTM instance is running (pid \(pid)); exiting.")
            return false
        }

        if let created = lock.createdAt {
            let age = Int(Date().timeIntervalSince1970 - created)
            log("Reclaiming stale lock (age \(age)s): \(path)")
        } else {
            log("Reclaiming stale lock with missing metadata: \(path)")
        }

        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            log("Failed to remove stale lock \(path): \(error.localizedDescription)")
            return false
        }
    }
}

func releaseLock(at path: String) {
    do {
        try FileManager.default.removeItem(atPath: path)
        log("Lock released: \(path)")
    } catch {
        if (error as NSError).code != NSFileNoSuchFileError {
            log("Failed to release lock \(path): \(error.localizedDescription)")
        }
    }
}

// MARK: - Parsing Helpers
func parsePlistDictionary(_ plistString: String, context: String) throws -> [String: Any] {
    guard let data = plistString.data(using: .utf8) else {
        throw ScriptError.malformedPlist("\(context): invalid UTF-8")
    }

    var format = PropertyListSerialization.PropertyListFormat.xml
    let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
    guard let dict = plist as? [String: Any] else {
        throw ScriptError.malformedPlist("\(context): root is not dictionary")
    }

    return dict
}

func parseDestinations(from plistString: String) throws -> [TMDestination] {
    let root = try parsePlistDictionary(plistString, context: "tmutil destinationinfo -X")
    guard let entries = root["Destinations"] as? [[String: Any]] else {
        return []
    }

    return entries.compactMap { item in
        guard let id = item["ID"] as? String, !id.isEmpty else { return nil }
        let name = (item["Name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = (item["Kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // `tmutil destinationinfo -X` has used both "Mount Point" and "MountPoint"
        // across macOS/tooling contexts. Accept either key for compatibility.
        let mountPointRaw = ((item["Mount Point"] as? String) ?? (item["MountPoint"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mountPoint = (mountPointRaw?.isEmpty == false) ? mountPointRaw : nil

        var lastDestination: Int?
        if let value = item["LastDestination"] as? NSNumber {
            lastDestination = value.intValue
        } else if let value = item["LastDestination"] as? String, let parsed = Int(value) {
            lastDestination = parsed
        }

        return TMDestination(
            id: id,
            name: name?.isEmpty == false ? name! : id,
            kind: kind ?? "",
            mountPoint: mountPoint,
            lastDestination: lastDestination
        )
    }
}

func parseBackupRunning(from plistString: String) throws -> Bool {
    let root = try parsePlistDictionary(plistString, context: "tmutil status -X")
    if let running = root["Running"] as? Bool {
        return running
    }
    if let running = root["Running"] as? NSNumber {
        return running.boolValue
    }
    return false
}

func isUsableMountPoint(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) { return false }
    return isDir.boolValue
}

func mountedLocalDestinations(_ destinations: [TMDestination]) -> [TMDestination] {
    destinations.filter { destination in
        guard destination.kind.caseInsensitiveCompare("Local") == .orderedSame else { return false }
        guard let mountPoint = destination.mountPoint, !mountPoint.isEmpty else { return false }
        return isUsableMountPoint(mountPoint)
    }
}

func selectDestination(from mountedLocals: [TMDestination], preferredID: String?) throws -> TMDestination {
    if let preferredID, !preferredID.isEmpty {
        guard let exact = mountedLocals.first(where: { $0.id.caseInsensitiveCompare(preferredID) == .orderedSame }) else {
            throw ScriptError.destinationNotFound(preferredID)
        }
        return exact
    }

    if mountedLocals.count == 1, let first = mountedLocals.first {
        return first
    }

    let lastPreferred = mountedLocals.filter { $0.lastDestination == 1 }
    if mountedLocals.count > 1, lastPreferred.count == 1, let chosen = lastPreferred.first {
        return chosen
    }

    if mountedLocals.isEmpty {
        throw ScriptError.noMountedLocalDestination
    }

    throw ScriptError.ambiguousDestination(mountedLocals.map { "\($0.name) [\($0.id)]" })
}

// MARK: - Backup State
func isBackupRunning() throws -> Bool {
    let result = run(["/usr/bin/tmutil", "status", "-X"])
    guard result.status == 0 else {
        throw tmutilError(["/usr/bin/tmutil", "status", "-X"], status: result.status, stdout: result.stdout, stderr: result.stderr)
    }
    return try parseBackupRunning(from: result.stdout)
}

func waitForBackupCompletion(maxWaitSeconds: UInt32, pollSeconds: UInt32) throws {
    var waited: UInt32 = 0
    log("Backup running; waiting up to \(maxWaitSeconds)s for completion.")

    while true {
        let running = try isBackupRunning()
        if !running {
            log("Backup completed after \(waited)s.")
            return
        }

        if waited >= maxWaitSeconds {
            throw ScriptError.backupTimeout(maxWaitSeconds)
        }

        sleep(pollSeconds)
        waited = min(waited + pollSeconds, maxWaitSeconds)
    }
}

func latestCompletedBackupPath(for mountPoint: String) -> String? {
    let result = run(["/usr/bin/tmutil", "latestbackup", "-d", mountPoint])
    guard result.status == 0 else {
        let details = combinedOutput(stdout: result.stdout, stderr: result.stderr)
        if looksLikeFullDiskAccessError(details) {
            log("Could not read latest backup history due to permissions for mount point \(mountPoint).")
        } else if !details.isEmpty {
            log("Could not read latest backup history for \(mountPoint): \(details)")
        }
        return nil
    }

    let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

// MARK: - Main Flow Helpers
func loadMountedDestination(preferredID: String?) throws -> TMDestination {
    let result = run(["/usr/bin/tmutil", "destinationinfo", "-X"])
    guard result.status == 0 else {
        throw tmutilError(["/usr/bin/tmutil", "destinationinfo", "-X"], status: result.status, stdout: result.stdout, stderr: result.stderr)
    }

    let destinations = try parseDestinations(from: result.stdout)
    let mountedLocals = mountedLocalDestinations(destinations)
    return try selectDestination(from: mountedLocals, preferredID: preferredID)
}

func triggerAutoDecision(for destination: TMDestination) -> BackupDecisionOutcome {
    let baseArgs = ["/usr/bin/tmutil", "startbackup", "--auto", "--block", "--destination", destination.id]
    var attempt = 0
    let latestBefore = destination.mountPoint.flatMap { latestCompletedBackupPath(for: $0) }

    while true {
        attempt += 1
        log("Running Time Machine auto decision (attempt \(attempt)): \(destination.name) [\(destination.id)]")
        let result = run(baseArgs)

        if result.status == 0 {
            let latestAfter = destination.mountPoint.flatMap { latestCompletedBackupPath(for: $0) }
            switch (latestBefore, latestAfter) {
            case let (before?, after?):
                if before != after {
                    log("tmutil startbackup --auto --block completed; a new completed backup was detected.")
                    return .backupCompletedThisRun
                } else {
                    log("tmutil startbackup --auto --block completed; no new completed backup was detected (likely not due).")
                    return .noNewBackupDetectedLikelyNotDue
                }
            case (nil, let after?):
                log("tmutil startbackup --auto --block completed; a completed backup is now present (\(after)).")
                return .backupCompletedThisRun
            case (_, nil):
                log("tmutil startbackup --auto --block completed; backup decision finished but backup history was unavailable to classify.")
                return .decisionCompletedButOutcomeUnclassified
            }
        }

        let details = combinedOutput(stdout: result.stdout, stderr: result.stderr)
        log("tmutil startbackup returned \(result.status). \(details)")
        if looksLikeFullDiskAccessError(details) {
            log("Full Disk Access likely missing for this run context. The script will not unmount unless later backup-state checks confirm it is safe.")
        }

        if attempt > startBackupRetryCount {
            log("Backup trigger retries exhausted; continuing cautiously with backup-state revalidation before any unmount attempt.")
            return .decisionCompletedButOutcomeUnclassified
        }

        sleep(retryDelaySeconds)
    }
}

func unmountVolume(at mountPoint: String) throws {
    guard isUsableMountPoint(mountPoint) else {
        log("Mount point no longer present or not mounted (\(mountPoint)); nothing to unmount.")
        return
    }

    for attempt in 1...unmountRetryAttempts {
        // Defensive re-check to handle the race where backupd transitions states right before unmount.
        if let resumed = try? isBackupRunning(), resumed {
            log("Backup resumed before unmount attempt \(attempt); waiting again.")
            try waitForBackupCompletion(maxWaitSeconds: backupMaxWaitSeconds, pollSeconds: backupPollSeconds)
        }

        log("Unmount attempt \(attempt)/\(unmountRetryAttempts): \(mountPoint)")
        let result = run(["/usr/sbin/diskutil", "unmount", mountPoint])
        if result.status == 0 {
            log("Disk unmounted successfully: \(mountPoint)")
            return
        }

        let details = [result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                       result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        log("Unmount attempt \(attempt) failed (\(result.status)). \(details)")

        if attempt < unmountRetryAttempts {
            sleep(retryDelaySeconds)
        }
    }

    throw ScriptError.unmountFailed(mountPoint)
}

// MARK: - Entrypoint
func main() -> ExitCode {
    guard acquireLock(at: lockPath) else {
        return .softSkip
    }
    defer { releaseLock(at: lockPath) }

    do {
        log("Starting AutoUnmountTM run.")
        let destination = try loadMountedDestination(preferredID: preferredDestinationID)
        guard let mountPoint = destination.mountPoint else {
            throw ScriptError.noMountedLocalDestination
        }
        var decisionOutcome: BackupDecisionOutcome = .decisionCompletedButOutcomeUnclassified

        log("Selected destination: \(destination.name) [\(destination.id)] @ \(mountPoint)")

        if try isBackupRunning() {
            log("Backup already running before auto decision.")
            try waitForBackupCompletion(maxWaitSeconds: backupMaxWaitSeconds, pollSeconds: backupPollSeconds)
            decisionOutcome = .backupCompletedThisRun
        } else {
            decisionOutcome = triggerAutoDecision(for: destination)
        }

        // Defensive check: `--block` usually covers this, but backupd can transition state around process boundaries.
        if try isBackupRunning() {
            log("Backup is running after trigger path; waiting for completion.")
            try waitForBackupCompletion(maxWaitSeconds: backupMaxWaitSeconds, pollSeconds: backupPollSeconds)
            decisionOutcome = .backupCompletedThisRun
        }

        switch decisionOutcome {
        case .backupCompletedThisRun:
            log("Decision summary: backup completed this run; proceeding to unmount.")
        case .noNewBackupDetectedLikelyNotDue:
            log("Decision summary: no new backup detected (likely not due); proceeding to unmount.")
        case .decisionCompletedButOutcomeUnclassified:
            log("Decision summary: backup decision completed but outcome was unclassified; proceeding with conservative checks and unmount.")
        }

        try unmountVolume(at: mountPoint)
        log("Run completed successfully.")
        return .success
    } catch ScriptError.noMountedLocalDestination {
        log("No mounted local destination found; exiting without action.")
        return .softSkip
    } catch ScriptError.fullDiskAccessRequired(let details) {
        log("ERROR: \(details)")
        return .failure
    } catch {
        log("ERROR: \(error)")
        return .failure
    }
}

let exitCode = main()
exit(exitCode.code)
