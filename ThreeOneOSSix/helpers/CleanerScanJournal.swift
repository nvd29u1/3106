import Foundation
import CryptoKit

/// Durable scan state for the Cache Cleaner: the scan-task record and
/// per-directory measurement checkpoints.
///
/// Port of the `WQScanJournal.h` + `WQScanTask.m` semantics (WQFiles
/// v0.9.18), adapted to the Swift cleaner:
/// - Storage: `Library/Application Support/ScanTasks/<sha256(key)>.plist`,
///   directory 0700 and excluded from backup; each file is a
///   `{version: 1, key, value}` envelope, the file name being the SHA-256
///   of the key — identical to the ObjC journal format.
/// - Task record key `task:clean`: `{identifier, unfinished, userPaused,
///   status, finishedAt?, result?}`. A fresh scan never destroys the last
///   completed result: `finish` keeps the previous result when the new
///   scan is incomplete, and the UI keeps showing it until a new scan
///   finishes.
/// - Measurement checkpoints key `measure:clean:<dir>`: `{task, identity,
///   bytes, files, limited}`. A checkpoint is valid only for the same task
///   identifier and the same directory identity (dev, ino, birth time —
///   the `wq_measure_identity` tuple). Checkpoints are written per
///   directory as the scan completes it, so a scan interrupted by a kill
///   or by pause resumes without re-measuring finished directories.
///
/// Deliberate adaptation: the ObjC measurement keeps a per-subdirectory
/// pending queue (`wq_measure_tree_resumable`); the Swift measurement is a
/// budgeted `FileManager` walk, not a pending-queue walk, so checkpoints
/// are per-directory (one per measured `Library/Caches` / `tmp` / custom
/// directory) rather than per-subdirectory. The walk itself is untouched
/// (`CleanerMeasureCache` / `LimitedCleanerService`).
enum CleanerScanJournal {

    // MARK: - Journal files

    private static let directoryName = "ScanTasks"
    private static let pruneAge: TimeInterval = 7 * 24 * 60 * 60

    /// Injectable root for tests: the policy harness runs as a bare CLI
    /// binary whose applicationSupportDirectory is the developer's real
    /// Library, so tests must redirect the journal to a temp dir.
    nonisolated(unsafe) private static var injectedRoot: URL?

    static func setRootForTesting(_ root: URL?) {
        injectedRoot = root
    }

    static var directoryURL: URL {
        if let injectedRoot { return injectedRoot }
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return support.appendingPathComponent(directoryName, isDirectory: true)
    }

    private static var directoryReady = false
    private static let lock = NSLock()

    private static func ensureDirectory() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if directoryReady { return true }
        let url = directoryURL
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try? mutableURL.setResourceValues(values)
            directoryReady = true
            return true
        } catch {
            log("cleaner: scan journal directory unavailable \(error.localizedDescription)")
            return false
        }
    }

    static func fileURL(forKey key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined() + ".plist"
        return directoryURL.appendingPathComponent(name)
    }

    @discardableResult
    static func save(key: String, value: [String: Any]) -> Bool {
        guard ensureDirectory() else { return false }
        let envelope: [String: Any] = ["version": 1, "key": key, "value": value]
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: envelope, format: .binary, options: 0
        ) else { return false }
        do {
            try data.write(to: fileURL(forKey: key), options: .atomic)
            return true
        } catch {
            log("cleaner: scan journal save failed \(key) \(error.localizedDescription)")
            return false
        }
    }

    static func load(key: String) -> [String: Any]? {
        guard
            let data = try? Data(contentsOf: fileURL(forKey: key)),
            let envelope = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any],
            envelope["version"] as? Int == 1,
            envelope["key"] as? String == key,
            let value = envelope["value"] as? [String: Any]
        else { return nil }
        return value
    }

    static func remove(key: String) {
        try? FileManager.default.removeItem(at: fileURL(forKey: key))
    }

    /// Removes journal files nobody resumed (an app uninstalled mid-scan, a
    /// scan never reopened) once older than `pruneAge`. Called at scan start.
    static func prune() {
        guard ensureDirectory() else { return }
        let now = Date()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path)) ?? []
        for name in names where name.hasSuffix(".plist") {
            let url = directoryURL.appendingPathComponent(name)
            guard
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                now.timeIntervalSince(modified) > pruneAge
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Scan-task record (key: task:clean)

    static let taskKey = "task:clean"

    struct ScanTaskRecord {
        var identifier: String
        var finishedAt: Date?
        var userPaused: Bool
        var interrupted: Bool
        var status: String
        /// Last completed result rows, if any (never overwritten by an
        /// incomplete scan).
        var resultRows: [[String: Any]]?

        var isResumable: Bool { interrupted || userPaused }
    }

    static func loadTask() -> ScanTaskRecord? {
        guard let value = load(key: taskKey) else { return nil }
        guard let identifier = value["identifier"] as? String else { return nil }
        return ScanTaskRecord(
            identifier: identifier,
            finishedAt: value["finishedAt"] as? Date,
            userPaused: value["userPaused"] as? Bool ?? false,
            interrupted: value["unfinished"] as? Bool ?? false,
            status: value["status"] as? String ?? "",
            resultRows: value["result"] as? [[String: Any]]
        )
    }

    /// Persists the task record. `resultRows` is only replaced when a new
    /// (non-nil) result is supplied — a paused or interrupted scan keeps the
    /// last completed result.
    static func saveTask(_ record: ScanTaskRecord, resultRows: [[String: Any]]? = nil) {
        var value: [String: Any] = [
            "identifier": record.identifier,
            "unfinished": record.interrupted || record.userPaused,
            "userPaused": record.userPaused,
            "status": record.status,
        ]
        if let finishedAt = record.finishedAt {
            value["finishedAt"] = finishedAt
        }
        if let resultRows {
            value["result"] = resultRows
        } else if let kept = record.resultRows {
            value["result"] = kept
        }
        _ = save(key: taskKey, value: value)
    }

    // MARK: - Measurement checkpoints (key: measure:clean:<dir>)

    struct MeasurementCheckpoint {
        let taskID: String
        /// Directory identity at checkpoint time: (dev, ino, birth sec,
        /// birth nsec) — the `wq_measure_identity` tuple.
        let identity: [Int64]
        let bytes: Int64
        let files: Int
        let limited: Bool
    }

    static func checkpointKey(forDirectory dir: String) -> String {
        "measure:clean:" + dir
    }

    /// Identity tuple for a directory, or nil when it cannot be stat'ed.
    static func identity(forDirectory dir: String) -> [Int64]? {
        var st = stat()
        guard stat(dir, &st) == 0 else { return nil }
        return [
            Int64(st.st_dev), Int64(st.st_ino),
            Int64(st.st_birthtimespec.tv_sec), Int64(st.st_birthtimespec.tv_nsec),
        ]
    }

    static func saveCheckpoint(
        taskID: String, directory: String, bytes: Int64, files: Int, limited: Bool
    ) {
        guard let identity = identity(forDirectory: directory) else { return }
        _ = save(key: checkpointKey(forDirectory: directory), value: [
            "task": taskID,
            "identity": identity,
            "bytes": bytes,
            "files": files,
            "limited": limited,
        ])
    }

    /// Returns the checkpoint only when it belongs to this task and the
    /// directory identity is unchanged — a replaced directory (new inode)
    /// invalidates it, exactly like `wq_measure_tree_resumable`.
    static func loadCheckpoint(taskID: String, directory: String) -> MeasurementCheckpoint? {
        guard
            let value = load(key: checkpointKey(forDirectory: directory)),
            value["task"] as? String == taskID,
            let rawIdentity = value["identity"] as? [NSNumber],
            rawIdentity.map(\.int64Value) == self.identity(forDirectory: directory),
            let bytes = value["bytes"] as? Int64,
            let files = value["files"] as? Int,
            let limited = value["limited"] as? Bool
        else { return nil }
        return MeasurementCheckpoint(
            taskID: taskID, identity: rawIdentity.map(\.int64Value),
            bytes: bytes, files: files, limited: limited
        )
    }

    static func removeCheckpoint(directory: String) {
        remove(key: checkpointKey(forDirectory: directory))
    }
}
