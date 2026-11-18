import Foundation

struct CleanerResolvedApplication: Equatable {
    let bundleID: String
    let name: String
    let containerPath: String
    let version: String
}

struct CleanerCatalogRecord: Equatable {
    let application: CleanerResolvedApplication
    let containerPath: String
    let usage: LimitedCleanerUsage

    var bundleID: String { application.bundleID }
}

enum CleanerSortOrder: String, CaseIterable, Identifiable {
    case largestFirst
    case smallestFirst

    var id: String { rawValue }
}

enum CleanerCatalog {
    /// Rows below this size are omitted from the list when both of their
    /// directories were fully measured (WQFiles parity:
    /// `WQCache.m -scan` drops `cacheBytes + tempBytes < 64 * 1024`).
    /// Limited rows are always kept, whatever their size.
    static let minimumVisibleBytes: Int64 = 64 * 1024

    /// Select Large Caches threshold (WQFiles parity: 50 MB, decimal).
    static let largeCacheThresholdBytes: Int64 = 50_000_000
    static func sorted<Record>(
        _ records: [Record],
        order: CleanerSortOrder,
        size: (Record) -> Int64,
        displayName: (Record) -> String,
        stableID: (Record) -> String
    ) -> [Record] {
        records.sorted { left, right in
            let leftSize = size(left)
            let rightSize = size(right)
            if leftSize != rightSize {
                switch order {
                case .largestFirst:
                    return leftSize > rightSize
                case .smallestFirst:
                    return leftSize < rightSize
                }
            }

            let nameComparison = displayName(left).localizedCaseInsensitiveCompare(displayName(right))
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }
            return stableID(left).localizedCaseInsensitiveCompare(stableID(right)) == .orderedAscending
        }
    }

    static func selectingAllVisible(
        _ visibleBundleIDs: [String],
        preserving selectedBundleIDs: Set<String>
    ) -> Set<String> {
        selectedBundleIDs.union(visibleBundleIDs)
    }

    /// Invert Selection (WQFiles parity: `selectWhere: !it.selected`).
    /// Visible rows flip; rows outside the current view are untouched.
    static func invertedVisible(
        _ visibleBundleIDs: [String],
        selected selectedBundleIDs: Set<String>
    ) -> Set<String> {
        var updated = selectedBundleIDs
        for bundleID in visibleBundleIDs {
            if updated.contains(bundleID) {
                updated.remove(bundleID)
            } else {
                updated.insert(bundleID)
            }
        }
        return updated
    }

    /// Select Large Caches (WQFiles parity: total bytes >= 50 MB).
    /// `visible` carries each visible row's id and size; non-large visible
    /// rows are left as they are.
    static func selectingLarge(
        _ visible: [(id: String, bytes: Int64)],
        threshold: Int64 = largeCacheThresholdBytes,
        preserving selectedBundleIDs: Set<String>
    ) -> Set<String> {
        var updated = selectedBundleIDs
        for row in visible where row.bytes >= threshold {
            updated.insert(row.id)
        }
        return updated
    }

    static func scanNewApplications(
        _ applications: [CleanerResolvedApplication],
        scannedBundleIDs: inout Set<String>,
        shouldIncludeBundleID: (String) -> Bool,
        activateContainer: (CleanerResolvedApplication) -> String?,
        isValidContainerPath: (String) -> Bool,
        usageForContainer: (String) -> LimitedCleanerUsage?,
        onApplication: ((String) -> Void)? = nil,
        onRecord: ((CleanerCatalogRecord) -> Void)? = nil,
        shouldStop: (() -> Bool)? = nil
    ) -> [CleanerCatalogRecord] {
        var records: [CleanerCatalogRecord] = []
        for application in applications {
            if shouldStop?() == true { break }
            let bundleID = application.bundleID
            defer { onApplication?(bundleID) }
            // Do not mark an app as scanned until its container was actually
            // resolved and measured; otherwise a failed MCM/LS pass hides the
            // filesystem fallback for the same bundle id.
            guard shouldIncludeBundleID(bundleID),
                  !scannedBundleIDs.contains(bundleID),
                  let containerPath = activateContainer(application),
                  isValidContainerPath(containerPath),
                  let usage = usageForContainer(containerPath),
                  usage.totalBytes >= minimumVisibleBytes || usage.limited else {
                continue
            }
            scannedBundleIDs.insert(bundleID)
            let record = CleanerCatalogRecord(
                application: application,
                containerPath: containerPath,
                usage: usage
            )
            records.append(record)
            onRecord?(record)
        }
        return records
    }
}
