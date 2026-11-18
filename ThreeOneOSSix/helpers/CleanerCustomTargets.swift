import Foundation
import Darwin

/// Folders and files the user added to the Cache Cleaner from the file
/// browser (long-press → "Add to Cache Cleaner").
///
/// Port of the WQFiles v0.9.18 custom-target feature (`WQCache.m` custom
/// targets + `WQCacheSafety.h` validation, `WQCache.h` store API). The store
/// schema is kept identical — UserDefaults key `WQCleanerCustomTargets`,
/// one dictionary per target `{bundle, app, container, path, file, auto}` —
/// so the semantics (and any data written by the same scheme) match.
/// A folder target is emptied (the folder itself stays); a file target is
/// deleted. Targets are selected like caches when `autoSelect` is set, or
/// only by hand otherwise.
struct CleanerCustomTarget: Equatable, Identifiable {
    let bundleID: String
    let appName: String
    let containerPath: String
    /// Path relative to the app container, e.g. `Library/Caches/Offline`.
    let relativePath: String
    let isFile: Bool
    /// Selected after every scan and by Select All, like caches.
    let autoSelect: Bool

    var id: String { bundleID + "|" + relativePath }

    /// Absolute path of the target inside its container.
    var absolutePath: String {
        (containerPath as NSString).appendingPathComponent(relativePath)
    }

    func encode() -> [String: Any] {
        [
            "bundle": bundleID,
            "app": appName,
            "container": containerPath,
            "path": relativePath,
            "file": isFile,
            "auto": autoSelect,
        ]
    }

    static func decode(_ dict: [String: Any]) -> CleanerCustomTarget? {
        guard
            let bundleID = dict["bundle"] as? String, !bundleID.isEmpty,
            let relativePath = dict["path"] as? String,
            CleanerCustomTargets.isValidRelative(relativePath)
        else { return nil }
        return CleanerCustomTarget(
            bundleID: bundleID,
            appName: dict["app"] as? String ?? bundleID,
            containerPath: dict["container"] as? String ?? "",
            relativePath: relativePath,
            isFile: dict["file"] as? Bool ?? false,
            autoSelect: dict["auto"] as? Bool ?? false
        )
    }
}

enum CleanerCustomTargets {
    static let storeKey = "WQCleanerCustomTargets"

    // MARK: - Validation (verbatim port of WQCacheSafety.h rules)

    /// Port of `WQCacheCustomRelativeValid` (`WQCacheSafety.h`): a custom
    /// target must be relative, at least two components deep, with no `.` /
    /// `..` / NUL component; the first component must be `Library`,
    /// `Documents` or `tmp`; under `Library` the second component must NOT
    /// be `Preferences`, `SyncedPreferences`, `Cookies`, or
    /// `Saved Application State` — app settings are explicitly excluded.
    static func isValidRelative(_ relative: String) -> Bool {
        guard !relative.isEmpty, !relative.hasPrefix("/") else { return false }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return false }
        for part in parts {
            if part.isEmpty || part == "." || part == ".." || part.contains("\0") {
                return false
            }
        }
        guard ["Library", "Documents", "tmp"].contains(parts[0]) else { return false }
        if parts[0] == "Library",
           ["Preferences", "SyncedPreferences", "Cookies", "Saved Application State"].contains(parts[1]) {
            return false
        }
        return true
    }

    /// Port of `WQCacheCustomRelativeForPath` (`WQCacheSafety.h`): splits an
    /// absolute path into its app-data container
    /// (`/private/var/mobile/Containers/Data/Application/<UUID>`) and the
    /// relative path below it, or returns nil when it is not a valid custom
    /// target. Accepts the `/var/...` spelling as an alias for
    /// `/private/var/...`.
    static func relativeForPath(_ path: String) -> (container: String, relative: String)? {
        var standardized = (path as NSString).standardizingPath
        if standardized.hasPrefix("/var/") {
            standardized = "/private" + standardized
        }
        let base = "/private/var/mobile/Containers/Data/Application/"
        guard standardized.hasPrefix(base) else { return nil }
        let rest = String(standardized.dropFirst(base.count))
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let uuid = String(rest[..<slash])
        guard UUID(uuidString: uuid) != nil else { return nil }
        let relative = String(rest[rest.index(after: slash)...])
        guard isValidRelative(relative) else { return nil }
        return (container: base + uuid, relative: relative)
    }

    // MARK: - Store (port of wq_cache_custom_target_* in WQCache.m)

    static func all() -> [CleanerCustomTarget] {
        guard let stored = UserDefaults.standard.object(forKey: storeKey) as? [[String: Any]] else {
            return []
        }
        return stored.compactMap(CleanerCustomTarget.decode)
    }

    static func contains(bundleID: String, relativePath: String) -> Bool {
        all().contains { $0.bundleID == bundleID && $0.relativePath == relativePath }
    }

    static func target(forPath path: String) -> CleanerCustomTarget? {
        guard let split = relativeForPath(path) else { return nil }
        return all().first {
            $0.relativePath == split.relative && $0.containerPath == split.container
        }
    }

    static func add(_ target: CleanerCustomTarget) {
        guard !target.bundleID.isEmpty,
              isValidRelative(target.relativePath),
              !contains(bundleID: target.bundleID, relativePath: target.relativePath)
        else { return }
        var targets = all()
        targets.append(target)
        persist(targets)
        log("cleaner: custom target added \(target.relativePath) of \(target.bundleID)")
    }

    static func setAutoSelect(bundleID: String, relativePath: String, autoSelect: Bool) {
        var targets = all()
        for index in targets.indices where targets[index].bundleID == bundleID
            && targets[index].relativePath == relativePath {
            targets[index] = CleanerCustomTarget(
                bundleID: targets[index].bundleID,
                appName: targets[index].appName,
                containerPath: targets[index].containerPath,
                relativePath: targets[index].relativePath,
                isFile: targets[index].isFile,
                autoSelect: autoSelect
            )
        }
        persist(targets)
    }

    static func remove(bundleID: String, relativePath: String) {
        let targets = all().filter {
            !($0.bundleID == bundleID && $0.relativePath == relativePath)
        }
        persist(targets)
        log("cleaner: custom target removed \(relativePath) of \(bundleID)")
    }

    private static func persist(_ targets: [CleanerCustomTarget]) {
        UserDefaults.standard.set(targets.map { $0.encode() }, forKey: storeKey)
    }

    // MARK: - Custom-file deletion (port of WQCacheDeleteCustomFile)

    /// Deletes the scanned file of a custom target: through its no-follow
    /// parent directory, only while it is still the same regular file
    /// (same dev/ino as the scan-time record). A file that no longer exists
    /// counts as already deleted. Port of `WQCacheDeleteCustomFile`
    /// (`WQCache.m:309-325`).
    static func deleteCustomFile(
        _ record: CleanerTargetRecord,
        freed: inout Int64
    ) -> Bool {
        guard record.existed else { return true }
        let parentPath = (record.path as NSString).deletingLastPathComponent
        let parent = parentPath.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard parent >= 0 else { return errno == ENOENT }
        defer { close(parent) }
        let name = (record.path as NSString).lastPathComponent
        var st = stat()
        let status = name.withCString {
            fstatat(parent, $0, &st, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else { return errno == ENOENT }
        guard (st.st_mode & S_IFMT) == S_IFREG,
              st.st_dev == record.device,
              st.st_ino == record.inode
        else { return false }
        let removed = name.withCString { unlinkat(parent, $0, 0) }
        guard removed == 0 else { return false }
        freed += max(0, Int64(st.st_size))
        return true
    }
}
