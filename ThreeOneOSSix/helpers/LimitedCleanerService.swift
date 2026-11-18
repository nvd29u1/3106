import Foundation
import Darwin

struct LimitedCleanerUsage: Equatable {
    let cacheBytes: Int64
    let temporaryBytes: Int64
    let removableItemCount: Int
    /// True when a target directory existed but could not be measured
    /// (grant/enumeration failure). Limited rows are shown, never cleaned
    /// (WQFiles parity: `WQCacheItem.limited`).
    let limited: Bool

    init(cacheBytes: Int64, temporaryBytes: Int64, removableItemCount: Int, limited: Bool = false) {
        self.cacheBytes = cacheBytes
        self.temporaryBytes = temporaryBytes
        self.removableItemCount = removableItemCount
        self.limited = limited
    }

    static let empty = LimitedCleanerUsage(
        cacheBytes: 0,
        temporaryBytes: 0,
        removableItemCount: 0
    )

    var totalBytes: Int64 {
        cacheBytes + temporaryBytes
    }
}

struct LimitedCleanerResult: Equatable {
    let before: LimitedCleanerUsage
    let after: LimitedCleanerUsage
    let removedItemCount: Int
    let failedItemCount: Int
    /// True when cleaning stopped early at the user's request (Stop button).
    let stopped: Bool

    init(
        before: LimitedCleanerUsage,
        after: LimitedCleanerUsage,
        removedItemCount: Int,
        failedItemCount: Int,
        stopped: Bool = false
    ) {
        self.before = before
        self.after = after
        self.removedItemCount = removedItemCount
        self.failedItemCount = failedItemCount
        self.stopped = stopped
    }

    var freedBytes: Int64 {
        max(0, before.totalBytes - after.totalBytes)
    }
}

enum LimitedCleanerError: Error, Equatable {
    case unsafeContainerRoot
    /// Pre-delete revalidation failed; the reason names the changed item.
    /// The caller must force a rescan before any retry (WQFiles parity:
    /// `_cleanRequiresRescan`).
    case validationFailed(reason: String)
}

/// Scan-time identity of one planned target, ported from
/// `WQCacheTargetRecord` (`WQCache.m`): device, inode and file-type mode
/// captured at scan time and re-checked immediately before deletion.
struct CleanerTargetRecord: Equatable {
    let path: String
    let relativePath: String
    let existed: Bool
    let device: dev_t
    let inode: ino_t
    let mode: mode_t

    static func capture(path: String, relativePath: String) -> CleanerTargetRecord {
        var st = stat()
        if lstat(path, &st) == 0 {
            return CleanerTargetRecord(
                path: path, relativePath: relativePath, existed: true,
                device: st.st_dev, inode: st.st_ino, mode: st.st_mode & S_IFMT
            )
        }
        return CleanerTargetRecord(
            path: path, relativePath: relativePath, existed: false,
            device: 0, inode: 0, mode: 0
        )
    }
}

/// Scan-time identity of a container and its planned targets, ported from
/// `WQCacheItem`'s container/target identity fields (`WQCache.m`).
/// Captured by `scanWithSnapshot` / `measureCustomTarget` and re-validated
/// by `validateSnapshot` before anything is deleted.
struct CleanerItemSnapshot: Equatable {
    let containerPath: String
    let bundleID: String
    let containerKnown: Bool
    let containerDevice: dev_t
    let containerInode: ino_t
    let containerMode: mode_t
    let targetRecords: [CleanerTargetRecord]
    /// Set for custom-target snapshots: the single custom relative path.
    /// Nil for ordinary app rows (whose targets are Library/Caches + tmp).
    let customRelativePath: String?

    /// Copy with the expected bundle ID replaced. The list scan knows the
    /// bundle ID from the app list (authoritative); the snapshot captured
    /// inside the service only resolves it best-effort.
    func withBundleID(_ bundleID: String) -> CleanerItemSnapshot {
        CleanerItemSnapshot(
            containerPath: containerPath,
            bundleID: bundleID,
            containerKnown: containerKnown,
            containerDevice: containerDevice,
            containerInode: containerInode,
            containerMode: containerMode,
            targetRecords: targetRecords,
            customRelativePath: customRelativePath
        )
    }
}

/// Measurement of one custom target (folder or file).
struct CleanerCustomMeasurement: Equatable {
    let bytes: Int64
    let files: Int
    let limited: Bool
    let snapshot: CleanerItemSnapshot
}

enum LimitedCleanerService {
    typealias ContainerRootValidator = (URL) -> Bool

    /// This explicit allowlist is the product boundary. Do not add global `/var`
    /// paths here: this cleaner is intentionally limited to per-app disposable data.
    static let allowedRelativeDirectories = ["Library/Caches", "tmp"]

    /// Budgeted-walk limits (WQManager parity): a single relative directory
    /// walk stops after this many entries or this many seconds, whichever
    /// comes first, and reports what it measured so far. Oversized apps get a
    /// partial (understated) size on first pass; the mtime-keyed incremental
    /// cache finishes catching up on later passes without blocking the list.
    static let measureBudgetEntries = 12_000
    static let measureBudgetSeconds: TimeInterval = 0.25

    /// Result of a budgeted walk: totals plus whether the budget ran out and
    /// whether the directory could not be measured at all (limited).
    struct BudgetedMeasure {
        let bytes: Int64
        let files: Int
        let budgetExhausted: Bool
        let limited: Bool
    }

    /// Latest scan-time snapshot for a container path, captured by the
    /// most recent `scanWithSnapshot` for it. The cleaner view reads this
    /// in its record callback and attaches the authoritative bundle ID
    /// (the scan closure itself only sees the container path).
    private static let snapshotLock = NSLock()
    private static var snapshotCache: [String: CleanerItemSnapshot] = [:]

    static func snapshot(forContainerPath path: String) -> CleanerItemSnapshot? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshotCache[path]
    }

    // MARK: - Scan

    static func scan(
        containerURL: URL,
        rootValidator: ContainerRootValidator,
        taskID: String? = nil
    ) throws -> LimitedCleanerUsage {
        try scanWithSnapshot(
            containerURL: containerURL, rootValidator: rootValidator, taskID: taskID
        ).usage
    }

    /// Scans the container and captures the scan-time identity snapshot the
    /// clean step revalidates before deleting anything (port of
    /// `WQCacheCaptureContainerIdentity` + `WQCacheTargetRecordForPath`).
    /// The snapshot is captured BEFORE measuring, so a file that appears
    /// mid-scan is caught as "appeared after the scan" at clean time.
    static func scanWithSnapshot(
        containerURL: URL,
        rootValidator: ContainerRootValidator,
        taskID: String? = nil
    ) throws -> (usage: LimitedCleanerUsage, snapshot: CleanerItemSnapshot) {
        let root = containerURL.standardizedFileURL
        guard root.path.hasPrefix("/"),
              root.path != "/",
              rootValidator(root) else {
            throw LimitedCleanerError.unsafeContainerRoot
        }

        let containerGrant = ContainerStore.grantContainerAccess(root.path)
        defer { SandboxAccess.release(containerGrant) }

        // Best-effort bundle ID for the snapshot; the list scan replaces it
        // with the authoritative bundle ID from the app list (see
        // snapshot(forContainerPath:) + withBundleID). Validation compares
        // the live container label against that expected ID.
        let resolvedBundleID = containerBundleID(forPath: root.path) ?? ""
        let snapshot = captureSnapshot(
            containerRoot: root, bundleID: resolvedBundleID,
            relatives: allowedRelativeDirectories, customRelativePath: nil
        )
        snapshotLock.lock()
        snapshotCache[root.path] = snapshot
        snapshotLock.unlock()

        let cache = budgetedMeasure(
            root: root, containerPath: root.path,
            relative: "Library/Caches", taskID: taskID
        )
        let temporary = budgetedMeasure(
            root: root, containerPath: root.path,
            relative: "tmp", taskID: taskID
        )
        return (
            usage: LimitedCleanerUsage(
                cacheBytes: cache.bytes,
                temporaryBytes: temporary.bytes,
                removableItemCount: cache.files + temporary.files,
                limited: cache.limited || temporary.limited
            ),
            snapshot: snapshot
        )
    }

    /// One budgeted directory walk, shared by the app scan and custom-target
    /// measurement. Consults the resumable-scan journal first (a checkpoint
    /// from the same task + unchanged directory identity is reused), then
    /// the mtime cache, then walks; a completed walk saves a checkpoint so
    /// a paused or killed scan resumes without re-measuring it.
    private static func budgetedMeasure(
        root: URL,
        containerPath: String,
        relative: String,
        taskID: String?
    ) -> BudgetedMeasure {
        if let cached = CleanerMeasureCache.cachedUsage(
            containerPath: containerPath,
            relativePath: relative
        ) {
            let bytes = relative == "Library/Caches"
                ? cached.cacheBytes : cached.temporaryBytes
            return BudgetedMeasure(
                bytes: bytes, files: cached.removableItemCount,
                budgetExhausted: false, limited: false
            )
        }

        let url = relative.split(separator: "/").reduce(root) { current, part in
            current.appendingPathComponent(String(part), isDirectory: true)
        }
        if let taskID,
           let checkpoint = CleanerScanJournal.loadCheckpoint(taskID: taskID, directory: url.path) {
            log("cleaner: checkpoint hit \(url.path) bytes=\(checkpoint.bytes)")
            return BudgetedMeasure(
                bytes: checkpoint.bytes, files: checkpoint.files,
                budgetExhausted: false, limited: checkpoint.limited
            )
        }

        let grant = ContainerStore.grantContainerAccess(url.path)
        defer { SandboxAccess.release(grant) }

        // Sample the directory mtime BEFORE walking (ContainerSizeMeter
        // parity): a store() that stats after the walk binds any file
        // written mid-walk to an mtime its measured bytes never had,
        // and the stale total then never re-measures.
        let preWalkMTime = CleanerMeasureCache.directoryMTime(atPath: url.path)

        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isDirectoryKey
        ]
        var bytes: Int64 = 0
        var files = 0
        var visited = 0
        var exhausted = false
        let limited = false
        let startedAt = Date()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return BudgetedMeasure(bytes: 0, files: 0, budgetExhausted: false, limited: false)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { failedURL, error in
                log(
                    "cleaner: enumerate failed \(failedURL.path) " +
                        "error=\(error.localizedDescription)"
                )
                return true
            }
        ) else {
            // The directory exists but cannot be opened at all: limited,
            // not empty (WQFiles parity: limited rows are shown, not hidden).
            return BudgetedMeasure(bytes: 0, files: 0, budgetExhausted: false, limited: true)
        }

        for case let item as URL in enumerator {
            visited += 1
            if visited % 256 == 0 {
                if visited >= measureBudgetEntries
                    || Date().timeIntervalSince(startedAt) >= measureBudgetSeconds {
                    exhausted = true
                    log(
                        "cleaner: measure budget hit \(url.path) " +
                            "entries=\(visited) bytes=\(bytes)"
                    )
                    break
                }
            }
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values?.isRegularFile == true else { continue }
            bytes += max(0, Int64(values?.fileSize ?? 0))
            files += 1
        }
        log("cleaner: measured \(url.path) bytes=\(bytes) files=\(files) exhausted=\(exhausted)")
        if !exhausted, let preWalkMTime {
            CleanerMeasureCache.store(
                containerPath: containerPath,
                relativePath: relative,
                bytes: bytes,
                files: files,
                directoryMTime: preWalkMTime
            )
            if let taskID {
                CleanerScanJournal.saveCheckpoint(
                    taskID: taskID, directory: url.path,
                    bytes: bytes, files: files, limited: limited
                )
            }
        }
        return BudgetedMeasure(bytes: bytes, files: files, budgetExhausted: exhausted, limited: limited)
    }

    // MARK: - Identity snapshots + pre-delete validation

    /// Captures the container identity (dev/ino/mode, directory only) and
    /// one target record per relative path. The caller must already hold a
    /// container grant when the paths need one to lstat.
    static func captureSnapshot(
        containerRoot root: URL,
        bundleID: String,
        relatives: [String],
        customRelativePath: String?
    ) -> CleanerItemSnapshot {
        var st = stat()
        let known = lstat(root.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
        let records = relatives.map { relative in
            CleanerTargetRecord.capture(
                path: (root.path as NSString).appendingPathComponent(relative),
                relativePath: relative
            )
        }
        return CleanerItemSnapshot(
            containerPath: root.path,
            bundleID: bundleID,
            containerKnown: known,
            containerDevice: known ? st.st_dev : 0,
            containerInode: known ? st.st_ino : 0,
            containerMode: known ? (st.st_mode & S_IFMT) : 0,
            targetRecords: records,
            customRelativePath: customRelativePath
        )
    }

    /// The bundle ID the container currently belongs to, via the target's
    /// own container index first, then the container metadata plist.
    /// Nil when it cannot be resolved from any source.
    static func containerBundleID(forPath path: String) -> String? {
        let index = worse_query_path_identifiers()
        let candidates = [
            path,
            (path as NSString).standardizingPath,
            path.hasPrefix("/var/") ? "/private" + path : path,
        ]
        for candidate in candidates {
            if let id = index[candidate], !id.isEmpty { return id }
        }
        if let metadata = ContainerStore.readContainerMetadata(containerPath: path),
           !metadata.bundleID.isEmpty {
            return metadata.bundleID
        }
        return nil
    }

    /// Port of `WQCacheValidateItem` (`WQCache.m:326-392`), adapted:
    /// - the container (dev/ino/mode, no-symlink ancestry, still the same
    ///   bundle ID) and every target record (dev/ino/mode, missing targets
    ///   still missing) must match the scan-time snapshot;
    /// - custom targets additionally require the strict
    ///   `targetMatchesContainer` check (lexical + no-follow + canonical);
    ///   the two standard directories keep `checkTarget` semantics, which
    ///   allow a `Library/Caches` symlink that stays inside the container
    ///   (apps commonly make it one — the old fd walker rejected it as
    ///   ELOOP and reported an empty target);
    /// - any mismatch returns a reason; the caller aborts that item and
    ///   forces a rescan before any retry.
    /// Returns nil when the snapshot is still valid.
    static func validateSnapshot(_ snapshot: CleanerItemSnapshot) -> String? {
        if let custom = snapshot.customRelativePath {
            guard snapshot.targetRecords.count == 1,
                  snapshot.targetRecords[0].relativePath == custom else {
                return "the scanned cache targets are incomplete"
            }
        } else if snapshot.targetRecords.count != allowedRelativeDirectories.count {
            return "the scanned cache targets are incomplete"
        }
        guard snapshot.containerKnown,
              CleanerSafetyPolicy.hasNoSymlinkAncestry(
                snapshot.containerPath, allowMissingFinal: false
              ) else {
            return "the app container identity or ancestry is unavailable"
        }
        var container = stat()
        guard lstat(snapshot.containerPath, &container) == 0,
              (container.st_mode & S_IFMT) == S_IFDIR,
              container.st_dev == snapshot.containerDevice,
              container.st_ino == snapshot.containerInode,
              (container.st_mode & S_IFMT) == snapshot.containerMode else {
            return "\(snapshot.bundleID) changed after the scan"
        }
        guard let label = containerBundleID(forPath: snapshot.containerPath) else {
            return "the app container identity could not be confirmed"
        }
        guard label == snapshot.bundleID else {
            return "\(snapshot.bundleID) no longer has the scanned container identity"
        }
        for record in snapshot.targetRecords {
            if snapshot.customRelativePath != nil {
                guard CleanerSafetyPolicy.targetMatchesContainer(
                    target: record.path,
                    container: snapshot.containerPath,
                    relativePath: record.relativePath
                ) else {
                    return "\(record.path) has unsafe path ancestry"
                }
            } else if let planned = CleanerSafetyPolicy.PlannedTarget.build(
                containerRoot: snapshot.containerPath,
                relativePath: record.relativePath
            ), CleanerSafetyPolicy.checkTarget(planned, snapshot: nil) != .allowed {
                return "\(record.path) has unsafe path ancestry"
            } else if CleanerSafetyPolicy.PlannedTarget.build(
                containerRoot: snapshot.containerPath,
                relativePath: record.relativePath
            ) == nil {
                return "\(record.path) has unsafe path ancestry"
            }
            if let reason = recordIdentityMismatch(record) { return reason }
        }
        return nil
    }

    private static func recordIdentityMismatch(_ record: CleanerTargetRecord) -> String? {
        var st = stat()
        let ok = lstat(record.path, &st) == 0
        if !record.existed {
            return ok ? "\(record.path) appeared after the scan" : nil
        }
        guard ok,
              st.st_dev == record.device,
              st.st_ino == record.inode,
              (st.st_mode & S_IFMT) == record.mode else {
            return "\(record.path) changed after the scan"
        }
        return nil
    }

    // MARK: - Clean (apps)

    static func clean(
        containerURL: URL,
        rootValidator: ContainerRootValidator
    ) throws -> LimitedCleanerResult {
        try clean(
            containerURL: containerURL, rootValidator: rootValidator,
            snapshot: nil, taskID: nil, shouldStop: nil
        )
    }

    /// Cleans the container's `Library/Caches` + `tmp` contents (the
    /// folders themselves stay), revalidating the scan-time snapshot before
    /// cleaning and again before each target. `snapshot` is the snapshot
    /// captured by the list scan when available; otherwise the snapshot
    /// from the `before` scan in this call is used. A validation failure
    /// throws `validationFailed` — the caller must force a rescan before
    /// any retry. Purge uses the fd-relative helpers on a write grant
    /// (`worse_query_grant_ex(require_write:1)` via
    /// `SandboxAccess.grant(writable:)`); a target that cannot be opened
    /// fd-relative (e.g. a symlinked `Library/Caches`) falls back to the
    /// FileManager children removal, which re-checks every child still
    /// resolves inside the container.
    static func clean(
        containerURL: URL,
        rootValidator: ContainerRootValidator,
        snapshot: CleanerItemSnapshot?,
        taskID: String?,
        shouldStop: (() -> Bool)? = nil
    ) throws -> LimitedCleanerResult {
        let (before, scannedSnapshot) = try scanWithSnapshot(
            containerURL: containerURL, rootValidator: rootValidator, taskID: taskID
        )
        let snapshotToUse = snapshot ?? scannedSnapshot
        if let reason = validateSnapshot(snapshotToUse) {
            log("cleaner: refusing \(snapshotToUse.bundleID) because \(reason)")
            throw LimitedCleanerError.validationFailed(reason: reason)
        }
        // The snapshot belongs to exactly one container: refuse when the
        // caller resolved a different container than the scan measured.
        guard snapshotToUse.containerPath == containerURL.standardizedFileURL.path else {
            throw LimitedCleanerError.validationFailed(
                reason: "\(snapshotToUse.bundleID) changed after the scan"
            )
        }

        let root = containerURL.standardizedFileURL
        guard root.path.hasPrefix("/"),
              root.path != "/",
              rootValidator(root) else {
            throw LimitedCleanerError.unsafeContainerRoot
        }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL

        // Purge paths take the WRITE grant: the target's grant
        // distinguishes read vs write, and a read-only token must not fake
        // a successful clean (spec D-03.3/D-04).
        let containerWriteGrant = SandboxAccess.grant(path: root.path, writable: true)
        defer { SandboxAccess.release(containerWriteGrant) }
        var targetWriteGrants: [Int64] = []
        defer {
            for grant in targetWriteGrants { SandboxAccess.release(grant) }
        }

        var summary = RemovalSummary()
        var stopped = false

        for relative in allowedRelativeDirectories {
            if shouldStop?() == true {
                stopped = true
                break
            }
            // Re-validate immediately before each target (WQFiles parity:
            // validation runs before cleaning AND before each target).
            if let reason = validateSnapshot(snapshotToUse) {
                log("cleaner: refusing \(relative) in \(root.path) because \(reason)")
                throw LimitedCleanerError.validationFailed(reason: reason)
            }
            let target = relative.split(separator: "/").reduce(root) { current, part in
                current.appendingPathComponent(String(part), isDirectory: true)
            }
            let writeGrant = SandboxAccess.grant(path: target.path, writable: true)
            if writeGrant >= 0 { targetWriteGrants.append(writeGrant) }
            guard FileManager.default.fileExists(atPath: target.path) else { continue }

            let components = relative.split(separator: "/").map(String.init)
            let purged: Bool = (try? withValidatedRootDescriptor(
                root, rootValidator: rootValidator
            ) { descriptor in
                purgeContentsOfRelativeDirectory(
                    components, rootDescriptor: descriptor, summary: &summary
                )
            }) ?? false
            if !purged {
                removeChildrenViaFileManager(
                    target: target, resolvedRoot: resolvedRoot, summary: &summary
                )
            }
            log("cleaner: removed=\(summary.removedItemCount) failed=\(summary.failedItemCount) under \(target.path)")
        }

        let after = try scan(containerURL: containerURL, rootValidator: rootValidator)
        return LimitedCleanerResult(
            before: before,
            after: after,
            removedItemCount: summary.removedItemCount,
            failedItemCount: summary.failedItemCount,
            stopped: stopped
        )
    }

    /// Removes the contents of one relative directory through a pinned
    /// root descriptor (fd-relative, never follows symlinks). Returns false
    /// when the directory cannot be opened that way (e.g. a symlinked
    /// `Library/Caches`), so the caller can fall back.
    private static func purgeContentsOfRelativeDirectory(
        _ components: [String],
        rootDescriptor: Int32,
        summary: inout RemovalSummary
    ) -> Bool {
        guard let directoryDescriptor = openDirectory(
            components: components, relativeTo: rootDescriptor
        ) else {
            return false
        }
        defer { close(directoryDescriptor) }
        removeDirectoryContents(directoryDescriptor, summary: &summary)
        return true
    }

    /// Fallback children removal for targets the fd path cannot open
    /// (notably a `Library/Caches` symlink): only follows the link when
    /// the resolved target stays inside the app container, and re-verifies
    /// each child still resolves inside the container immediately before
    /// deletion.
    private static func removeChildrenViaFileManager(
        target: URL,
        resolvedRoot: URL,
        summary: inout RemovalSummary
    ) {
        let resolvedTarget = target.resolvingSymlinksInPath().standardizedFileURL
        guard LaunchServicesStore.isPath(
            resolvedTarget.path, containedIn: resolvedRoot.path
        ) else {
            summary.failedItemCount += 1
            log(
                "cleaner: refusing symlink outside container " +
                    "\(target.path) -> \(resolvedTarget.path)"
            )
            return
        }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: target,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        )) ?? []
        for child in children {
            let resolvedChild = child.resolvingSymlinksInPath().standardizedFileURL
            guard LaunchServicesStore.isPath(
                resolvedChild.path, containedIn: resolvedRoot.path
            ) else {
                summary.failedItemCount += 1
                log(
                    "cleaner: refusing child outside container " +
                        "\(child.path) -> \(resolvedChild.path)"
                )
                continue
            }
            do {
                try FileManager.default.removeItem(at: child)
                summary.removedItemCount += 1
            } catch {
                summary.failedItemCount += 1
                log(
                    "cleaner: remove failed \(child.path) " +
                        "error=\(error.localizedDescription)"
                )
            }
        }
    }

    // MARK: - Custom targets

    /// Measures one custom target (folder: budgeted walk; file: lstat
    /// size) and captures its scan-time snapshot. Returns nil when the
    /// relative path is invalid or the container root is unsafe.
    static func measureCustomTarget(
        containerURL: URL,
        rootValidator: ContainerRootValidator,
        target: CleanerCustomTarget,
        taskID: String? = nil
    ) -> CleanerCustomMeasurement? {
        guard CleanerCustomTargets.isValidRelative(target.relativePath) else { return nil }
        let root = containerURL.standardizedFileURL
        guard root.path.hasPrefix("/"),
              root.path != "/",
              rootValidator(root) else {
            return nil
        }
        let grant = ContainerStore.grantContainerAccess(root.path)
        defer { SandboxAccess.release(grant) }
        let snapshot = captureSnapshot(
            containerRoot: root, bundleID: target.bundleID,
            relatives: [target.relativePath], customRelativePath: target.relativePath
        )
        if target.isFile {
            var st = stat()
            let absolute = target.absolutePath
            if lstat(absolute, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG {
                return CleanerCustomMeasurement(
                    bytes: max(0, Int64(st.st_size)), files: 1,
                    limited: false, snapshot: snapshot
                )
            }
            if errno == ENOENT {
                return CleanerCustomMeasurement(
                    bytes: 0, files: 0, limited: false, snapshot: snapshot
                )
            }
            return CleanerCustomMeasurement(
                bytes: 0, files: 0, limited: true, snapshot: snapshot
            )
        }
        let measured = budgetedMeasure(
            root: root, containerPath: root.path,
            relative: target.relativePath, taskID: taskID
        )
        return CleanerCustomMeasurement(
            bytes: measured.bytes, files: measured.files,
            limited: measured.limited, snapshot: snapshot
        )
    }

    /// Cleans one custom target: a folder is emptied (the folder stays), a
    /// file is deleted via the no-follow delete. The snapshot is
    /// revalidated immediately before the purge; a failure throws
    /// `validationFailed` and nothing is deleted.
    static func cleanCustomTarget(
        _ target: CleanerCustomTarget,
        containerURL: URL,
        rootValidator: ContainerRootValidator,
        snapshot: CleanerItemSnapshot?
    ) throws -> (freedBytes: Int64, removed: Int, failed: Int) {
        guard let before = measureCustomTarget(
            containerURL: containerURL, rootValidator: rootValidator, target: target
        ) else {
            throw LimitedCleanerError.unsafeContainerRoot
        }
        let snapshotToUse = snapshot ?? before.snapshot
        if let reason = validateSnapshot(snapshotToUse) {
            log("cleaner: refusing custom target \(target.relativePath) because \(reason)")
            throw LimitedCleanerError.validationFailed(reason: reason)
        }
        guard snapshotToUse.containerPath == containerURL.standardizedFileURL.path else {
            throw LimitedCleanerError.validationFailed(
                reason: "\(target.bundleID) changed after the scan"
            )
        }
        let root = containerURL.standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let writeGrant = SandboxAccess.grant(path: root.path, writable: true)
        defer { SandboxAccess.release(writeGrant) }

        var summary = RemovalSummary()
        if target.isFile {
            var freed: Int64 = 0
            guard let record = snapshotToUse.targetRecords.first else {
                throw LimitedCleanerError.validationFailed(reason: "the scanned cache targets are incomplete")
            }
            if CleanerCustomTargets.deleteCustomFile(record, freed: &freed) {
                summary.removedItemCount += 1
            } else {
                summary.failedItemCount += 1
            }
        } else {
            let targetGrant = SandboxAccess.grant(
                path: target.absolutePath, writable: true
            )
            defer { SandboxAccess.release(targetGrant) }
            let components = target.relativePath.split(separator: "/").map(String.init)
            let purged: Bool = (try? withValidatedRootDescriptor(
                root, rootValidator: rootValidator
            ) { descriptor in
                purgeContentsOfRelativeDirectory(
                    components, rootDescriptor: descriptor, summary: &summary
                )
            }) ?? false
            if !purged {
                let targetURL = URL(fileURLWithPath: target.absolutePath, isDirectory: true)
                removeChildrenViaFileManager(
                    target: targetURL, resolvedRoot: resolvedRoot, summary: &summary
                )
            }
        }
        let after = measureCustomTarget(
            containerURL: containerURL, rootValidator: rootValidator, target: target
        )
        return (
            freedBytes: max(0, before.bytes - (after?.bytes ?? 0)),
            removed: summary.removedItemCount,
            failed: summary.failedItemCount
        )
    }

    // MARK: - Fd-relative helpers (previously dead code, now wired up)

    private static func withValidatedRootDescriptor<T>(
        _ rawURL: URL,
        rootValidator: ContainerRootValidator,
        operation: (Int32) throws -> T
    ) throws -> T {
        guard rawURL.isFileURL else { throw LimitedCleanerError.unsafeContainerRoot }
        let root = rawURL.standardizedFileURL
        guard root.path.hasPrefix("/"),
              root.path != "/",
              rootValidator(root) else {
            throw LimitedCleanerError.unsafeContainerRoot
        }

        // iOS 26/27: the cleaner opens the container root directly, so the
        // sandbox grant must be active for the whole scan/removal pass.
        let grant = ContainerStore.grantContainerAccess(root.path)
        defer { SandboxAccess.release(grant) }

        // worse_query grants are path-scoped. Grant the two measured targets
        // explicitly, mirroring WQ Files' wq_grant(dir) before measuring.
        var targetGrants: [Int64] = []
        defer {
            for targetGrant in targetGrants { SandboxAccess.release(targetGrant) }
        }
        for relative in allowedRelativeDirectories {
            let targetURL = relative.split(separator: "/").reduce(root) { url, part in
                url.appendingPathComponent(String(part), isDirectory: true)
            }
            let targetGrant = ContainerStore.grantContainerAccess(targetURL.path)
            if targetGrant >= 0 { targetGrants.append(targetGrant) }
        }

        let descriptor = open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw LimitedCleanerError.unsafeContainerRoot }
        defer { close(descriptor) }
        return try operation(descriptor)
    }

    private static func scanAllowedDirectory(
        components: [String],
        rootDescriptor: Int32
    ) -> ScanSummary {
        guard let directoryDescriptor = openDirectory(
            components: components,
            relativeTo: rootDescriptor
        ) else {
            log("cleaner: open failed \(components.joined(separator: "/")) errno=\(errno)")
            return .empty
        }
        defer { close(directoryDescriptor) }
        return scanDirectory(directoryDescriptor)
    }

    private static func openDirectory(
        components: [String],
        relativeTo rootDescriptor: Int32
    ) -> Int32? {
        var currentDescriptor = dup(rootDescriptor)
        guard currentDescriptor >= 0 else { return nil }

        for component in components {
            let nextDescriptor = component.withCString {
                openat(
                    currentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            close(currentDescriptor)
            guard nextDescriptor >= 0 else { return nil }
            currentDescriptor = nextDescriptor
        }
        return currentDescriptor
    }

    private static func scanDirectory(_ directoryDescriptor: Int32) -> ScanSummary {
        var result = ScanSummary.empty
        forEachEntry(in: directoryDescriptor) { name, information in
            switch information.st_mode & S_IFMT {
            case S_IFREG:
                result.bytes += max(0, Int64(information.st_size))
                result.itemCount += 1
            case S_IFDIR:
                let childDescriptor = name.withCString {
                    openat(
                        directoryDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard childDescriptor >= 0 else { return }
                let nested = scanDirectory(childDescriptor)
                close(childDescriptor)
                result.bytes += nested.bytes
                result.itemCount += nested.itemCount
            default:
                // Symbolic links, sockets and device nodes are never followed or counted.
                break
            }
        }
        return result
    }

    private static func removeDirectoryContents(
        _ directoryDescriptor: Int32,
        summary: inout RemovalSummary
    ) {
        forEachEntry(in: directoryDescriptor) { name, information in
            switch information.st_mode & S_IFMT {
            case S_IFREG:
                let result = name.withCString { unlinkat(directoryDescriptor, $0, 0) }
                if result == 0 {
                    summary.removedItemCount += 1
                } else if errno != ENOENT {
                    summary.failedItemCount += 1
                }
            case S_IFDIR:
                let childDescriptor = name.withCString {
                    openat(
                        directoryDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard childDescriptor >= 0 else {
                    if errno != ENOENT && errno != ELOOP {
                        summary.failedItemCount += 1
                    }
                    return
                }
                removeDirectoryContents(childDescriptor, summary: &summary)
                close(childDescriptor)

                let result = name.withCString {
                    unlinkat(directoryDescriptor, $0, AT_REMOVEDIR)
                }
                if result != 0,
                   errno != ENOENT,
                   errno != ENOTEMPTY {
                    summary.failedItemCount += 1
                }
            default:
                // Symbolic links and special nodes are unlinked, never
                // followed (WQFiles parity: symlink children are unlinked,
                // never followed).
                let result = name.withCString { unlinkat(directoryDescriptor, $0, 0) }
                if result == 0 {
                    summary.removedItemCount += 1
                } else if errno != ENOENT {
                    summary.failedItemCount += 1
                }
            }
        }
    }

    private static func forEachEntry(
        in directoryDescriptor: Int32,
        body: (String, stat) -> Void
    ) {
        let iterationDescriptor = dup(directoryDescriptor)
        guard iterationDescriptor >= 0,
              let directory = fdopendir(iterationDescriptor) else {
            if iterationDescriptor >= 0 { close(iterationDescriptor) }
            return
        }
        defer { closedir(directory) }

        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }

            var information = stat()
            let status = name.withCString {
                fstatat(directoryDescriptor, $0, &information, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else { continue }
            body(name, information)
        }
    }
}

private struct ScanSummary {
    var bytes: Int64
    var itemCount: Int

    static let empty = ScanSummary(bytes: 0, itemCount: 0)
}

private struct RemovalSummary {
    var removedItemCount = 0
    var failedItemCount = 0
}
