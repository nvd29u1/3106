import Foundation
import Darwin

struct CrashLogSummary: Equatable {
    let fileCount: Int
    let bytes: Int64
    /// True when a crash-log folder exists but could not be fully measured
    /// on this device (WQFiles parity: the section is shown as limited
    /// instead of silently reporting 0).
    let limited: Bool

    init(fileCount: Int, bytes: Int64, limited: Bool = false) {
        self.fileCount = fileCount
        self.bytes = bytes
        self.limited = limited
    }
}

struct CrashLogCleanResult: Equatable {
    let removed: Int
    let failed: Int
    let freedBytes: Int64
}

/// Removes only crash/panic/diagnostic log files under known user log
/// directories. Symlinks and anything outside those roots are refused.
enum CrashLogCleaner {
    /// The two exact CrashReporter candidates (WQFiles parity:
    /// `WQCacheCrashLogCandidates`, `WQCache.m:25-29`): mobile's Library,
    /// and the osanalytics system group as a fallback. The mobile folder
    /// does not exist on iOS 27.0.1, which is when the second one matters.
    static let candidatePaths = [
        "/private/var/mobile/Library/Logs/CrashReporter",
        "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.osanalytics/Library/Logs/CrashReporter",
    ]
    /// Kept for existing callers: the first (mobile) candidate.
    static let rootPath = candidatePaths[0]
    private static let allowedExtensions: Set<String> = [
        "ips", "crash", "panic", "log", "synced", "diag",
    ]
    private static let maximumFiles = 10_000

    /// Port of `WQCacheCrashPathIsSafe` (`WQCache.m:221-228`): one of the
    /// known crash-log folders, spelled exactly, with no link on the way
    /// and resolving to itself.
    static func isSafeCrashPath(_ path: String) -> Bool {
        candidatePaths.contains(path)
            && CleanerSafetyPolicy.hasNoSymlinkAncestry(path, allowMissingFinal: true)
            && CleanerSafetyPolicy.canonicalPath(path) == path
    }

    /// The first candidate that exists and passes the safety check, with a
    /// sandbox grant when needed. Returns nil + limited=true when a
    /// candidate exists but cannot be read even with a grant (WQFiles
    /// parity: left out / reported limited instead of showing 0).
    static func resolvedRoot() -> (path: String, limited: Bool) {
        for candidate in candidatePaths {
            var st = stat()
            if lstat(candidate, &st) != 0 {
                if errno == EPERM || errno == EACCES {
                    let grant = ContainerStore.grantContainerAccess(candidate)
                    defer { SandboxAccess.release(grant) }
                    if lstat(candidate, &st) != 0 { continue }
                } else {
                    continue
                }
            }
            guard isSafeCrashPath(candidate) else {
                log("cleaner: crash logs path check failed \(candidate)")
                return (candidate, true)
            }
            let fd = open(candidate, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd >= 0 {
                close(fd)
                return (candidate, false)
            }
            if errno == EPERM || errno == EACCES {
                let grant = ContainerStore.grantContainerAccess(candidate)
                defer { SandboxAccess.release(grant) }
                let retry = open(candidate, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if retry >= 0 {
                    close(retry)
                    return (candidate, false)
                }
            }
            log("cleaner: crash logs can't be read on this device (\(candidate))")
            return (candidate, true)
        }
        return (candidatePaths[0], false)
    }

    static func scan() -> CrashLogSummary {
        let resolved = resolvedRoot()
        let url = URL(fileURLWithPath: resolved.path, isDirectory: true)
        let grant = ContainerStore.grantContainerAccess(resolved.path)
        defer {
            if grant >= 0 { SandboxAccess.release(grant) }
        }
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            return CrashLogSummary(fileCount: 0, bytes: 0, limited: false)
        }
        if resolved.limited {
            return CrashLogSummary(fileCount: 0, bytes: 0, limited: true)
        }
        var count = 0
        var bytes: Int64 = 0
        for file in files(under: url) {
            count += 1
            bytes += file.size
            if count >= maximumFiles { break }
        }
        return CrashLogSummary(fileCount: count, bytes: bytes, limited: false)
    }

    static func clean() -> CrashLogCleanResult {
        let resolved = resolvedRoot()
        let url = URL(fileURLWithPath: resolved.path, isDirectory: true)
        let grant = ContainerStore.grantContainerAccess(resolved.path)
        defer {
            if grant >= 0 { SandboxAccess.release(grant) }
        }
        guard FileManager.default.fileExists(atPath: resolved.path),
              !resolved.limited else {
            return CrashLogCleanResult(removed: 0, failed: 0, freedBytes: 0)
        }
        var removed = 0
        var failed = 0
        var freed: Int64 = 0
        for file in files(under: url) {
            guard file.url.standardizedFileURL.path.hasPrefix(
                url.standardizedFileURL.path + "/"
            ) else {
                failed += 1
                continue
            }
            do {
                try FileManager.default.removeItem(at: file.url)
                removed += 1
                freed += file.size
            } catch {
                failed += 1
            }
        }
        return CrashLogCleanResult(removed: removed, failed: failed, freedBytes: freed)
    }

    private struct CrashLogFile {
        let url: URL
        let size: Int64
    }

    private static func files(under root: URL) -> [CrashLogFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [CrashLogFile] = []
        for case let url as URL in enumerator {
            guard allowedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ]) else { continue }
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            result.append(CrashLogFile(
                url: url,
                size: Int64(values.fileSize ?? 0)
            ))
            if result.count >= maximumFiles { break }
        }
        return result
    }
}
