import SwiftUI

struct CleanerView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var records: [CleanerAppRecord] = []
    @State private var selectedBundleIDs = Set<String>()
    @State private var searchText = ""
    @EnvironmentObject private var scanCoordinator: ScanCoordinator
    @State private var sortOrder: CleanerSortOrder = .largestFirst
    @State private var isScanning = false
    @State private var isCleaning = false
    @State private var scannedAppCount = 0
    @State private var hasLoaded = false
    @State private var scanID = UUID()
    @State private var activeAlert: CleanerAlert?
    @State private var crashSummary: CrashLogSummary?
    @State private var isCrashBusy = false
    @State private var cleanerHistory: [CleanerHistoryEntry] = []
    @State private var cleaningProgressText = ""
    // Custom targets (folders/files added from the file browser).
    @State private var customRows: [CleanerCustomRow] = []
    @State private var selectedCustomKeys = Set<String>()
    // Scan-time identity snapshots (WQCacheValidateItem parity), keyed by
    // record id / custom-target id. The clean step revalidates them.
    @State private var itemSnapshots: [String: CleanerItemSnapshot] = [:]
    @State private var customSnapshots: [String: CleanerItemSnapshot] = [:]
    // Resumable scans (WQScanTask / WQScanJournal parity).
    @State private var scanPaused = false
    @State private var scanTaskID = UUID().uuidString
    @State private var lastScanFinishedAt: Date?
    @State private var scanStopToken: CancellationToken?
    @State private var cleanStopToken: CancellationToken?
    @State private var cleanRequiresRescan = false
    let confirmationGate = CleanerSafetyPolicy.ConfirmationGate()
    let onOpenSettings: () -> Void

    init(onOpenSettings: @escaping () -> Void = {}) {
        self.onOpenSettings = onOpenSettings
    }

    private var filteredRecords: [CleanerAppRecord] {
        let matchingRecords: [CleanerAppRecord]
        if searchText.isEmpty {
            matchingRecords = records
        } else {
            let query = searchText.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: language.locale
            )
            matchingRecords = records.filter {
                $0.app.displayName.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: language.locale
                ).contains(query) || $0.app.bundleID.lowercased().contains(query.lowercased())
            }
        }

        return CleanerCatalog.sorted(
            matchingRecords,
            order: sortOrder,
            size: { $0.usage.totalBytes },
            displayName: { $0.app.displayName },
            stableID: { $0.id }
        )
    }

    private var visibleBundleIDs: [String] {
        // Limited rows are shown but never cleanable (WQFiles parity).
        filteredRecords.filter { $0.isIdentified && !$0.limited }.map(\.id)
    }

    private var areAllVisibleRecordsSelected: Bool {
        !visibleBundleIDs.isEmpty
            && visibleBundleIDs.allSatisfy { selectedBundleIDs.contains($0) }
    }

    private var totalAvailableBytes: Int64 {
        records.reduce(0) { $0 + $1.usage.totalBytes }
            + customRows.reduce(0) { $0 + $1.bytes }
    }

    private var selectedBytes: Int64 {
        records.reduce(0) { result, record in
            result + (selectedBundleIDs.contains(record.id) ? record.usage.totalBytes : 0)
        } + customRows.reduce(0) { result, row in
            result + (selectedCustomKeys.contains(row.id) ? row.bytes : 0)
        }
    }

    private var selectedItemCount: Int {
        selectedBundleIDs.count + selectedCustomKeys.count
    }

    private var isBusy: Bool {
        isScanning || isCleaning
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AppSearchField(
                    text: $searchText,
                    prompt: language.text("cleaner.search"),
                    clearLabel: language.text("common.clear")
                )
                Divider()
                cleanerList
                    .listStyle(.insetGrouped)
            }
            .navigationTitle(language.text("cleaner.title"))
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar { toolbarContent }
            .alert(item: $activeAlert, content: alert(for:))
            .onAppear {
                guard !hasLoaded else { return }
                hasLoaded = true
                // History is a small plist; load once per tab entry, not on
                // every struct init (search typing re-inits the view).
                cleanerHistory = CleanerHistory.loadEntries()
                loadCrashLogs()
                CleanerScanJournal.prune()
                // A fresh scan never destroys the last completed result
                // (WQScanTask parity): restore it when present.
                let restored = restoreLastScanResult()
                if restored {
                    if let finishedAt = lastScanFinishedAt,
                       Date().timeIntervalSince(finishedAt) > 600 {
                        reload()
                    }
                } else if scanPaused {
                    reload(resume: true)
                } else {
                    reload()
                }
            }
        }
    }

    @ViewBuilder
    private var cleanerList: some View {
        if records.isEmpty && customRows.isEmpty {
            List {
                crashLogSection
                if isScanning {
                    loadingSection
                } else {
                    emptySection
                }
            }
        } else {
            List {
                summarySection
                crashLogSection
                customTargetsSection
                applicationsSection
                if isScanning {
                    loadingSection
                }
            }
        }
    }

    /// Folders/files the user added from the file browser
    /// (WQFiles parity: custom-target rows).
    @ViewBuilder
    private var customTargetsSection: some View {
        if !customRows.isEmpty {
            Section {
                ForEach(customRows) { row in
                    Button {
                        toggleCustomSelection(row.id)
                    } label: {
                        customRow(row)
                    }
                    .buttonStyle(.plain)
                    .disabled(isCleaning)
                    .contextMenu {
                        Button {
                            let target = row.target
                            CleanerCustomTargets.setAutoSelect(
                                bundleID: target.bundleID,
                                relativePath: target.relativePath,
                                autoSelect: !target.autoSelect
                            )
                            refreshCustomRowAutoSelect(row.id, autoSelect: !target.autoSelect)
                        } label: {
                            Label(
                                language.text("cleaner.custom_auto_select"),
                                systemImage: row.target.autoSelect
                                    ? "checkmark.circle.fill" : "checkmark.circle"
                            )
                        }
                        Button(role: .destructive) {
                            removeCustomRow(row)
                        } label: {
                            Label(
                                language.text("cleaner.custom_remove"),
                                systemImage: "minus.circle"
                            )
                        }
                    }
                }
            } header: {
                Text(language.text("cleaner.custom_section"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            } footer: {
                Text(language.text("cleaner.custom_footer"))
            }
        }
    }

    private func customRow(_ row: CleanerCustomRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.target.isFile ? "doc.fill" : "folder.fill")
                .font(.system(size: AppTheme.selectionIconSize, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.target.appName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(row.target.relativePath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(sizeText(row.bytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Image(systemName: row.limited
                  ? "lock.circle"
                  : (selectedCustomKeys.contains(row.id) ? "checkmark.circle.fill" : "circle"))
                .font(.system(size: AppTheme.selectionIconSize, weight: .medium))
                .foregroundStyle(
                    !row.limited && selectedCustomKeys.contains(row.id)
                        ? AppTheme.accent
                        : Color.secondary
                )
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            selectedCustomKeys.contains(row.id)
                ? language.text("cleaner.accessibility_selected")
                : language.text("cleaner.accessibility_not_selected")
        )
    }

    private var crashLogSection: some View {
        Section {
            if let crashSummary {
                LabeledContent(language.text("cleaner.crash.title")) {
                    Text(language.text(
                        "cleaner.crash.summary",
                        Int64(crashSummary.fileCount),
                        sizeText(crashSummary.bytes)
                    ))
                    .monospacedDigit()
                }
                Button(role: .destructive) {
                    activeAlert = .crashConfirmation
                } label: {
                    Label(language.text("cleaner.crash.clean"), systemImage: "trash")
                }
                .disabled(crashSummary.fileCount == 0 || isCrashBusy)
            } else {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(language.text("cleaner.crash.loading"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Label(language.text("cleaner.crash.section"), systemImage: "exclamationmark.triangle")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(language.text("cleaner.crash.footer"))
                if crashSummary?.limited == true {
                    Text(language.text("cleaner.crash_limited"))
                }
            }
        }
    }

    private var loadingSection: some View {
        Section {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(language.text(
                    "cleaner.loading_count",
                    Int64(scannedAppCount),
                    Int64(records.count)
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    private var summarySection: some View {
        Section {
            LabeledContent(language.text("cleaner.available")) {
                Text(sizeText(totalAvailableBytes))
                    .monospacedDigit()
            }
            LabeledContent(language.text("cleaner.selected")) {
                Text(language.text("cleaner.selected_summary", Int64(selectedItemCount), sizeText(selectedBytes)))
                    .monospacedDigit()
            }
            if cleanRequiresRescan {
                Text(language.text("cleaner.rescan_required"))
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
            if totalFreedBytes > 0 {
                LabeledContent(language.text("cleaner.history_total")) {
                    Text(sizeText(totalFreedBytes))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.accent)
                }
            }
            cleanAction
        } header: {
            Label(language.text("cleaner.limited_mode"), systemImage: "checkmark.shield")
        } footer: {
            Text(language.text("cleaner.scope_footer"))
        }
    }

    private var totalFreedBytes: Int64 {
        CleanerHistory.totalFreedBytes(in: cleanerHistory)
    }

    private var applicationsSection: some View {
        Section {
            if filteredRecords.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(language.text("browser.search_empty"))
                        .font(.headline)
                    Text(language.text("cleaner.search_empty_message"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ForEach(filteredRecords) { record in
                    Button {
                        toggleSelection(record.id)
                    } label: {
                        applicationRow(record)
                    }
                    .buttonStyle(.plain)
                    .disabled(isCleaning)
                }
            }
        } header: {
            HStack(spacing: 8) {
                Text(language.text("cleaner.apps_with_cache", Int64(filteredRecords.count)))
                Spacer()
                if isScanning {
                    ProgressView()
                        .controlSize(.mini)
                    Text(language.text("cleaner.scanned_count", Int64(scannedAppCount)))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(nil)
        } footer: {
            if !records.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(language.text("cleaner.apps_footer"))
                    if records.contains(where: { !$0.isIdentified }) {
                        Text(language.text("cleaner.unidentified_footer"))
                    }
                }
            }
        }
    }

    private func applicationRow(_ record: CleanerAppRecord) -> some View {
        HStack(spacing: 10) {
            BrowserAppIcon(app: record.app)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.app.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                // Per-app cache/temp split (WQFiles parity: "cache X · temp Y").
                Text(rowDetailText(for: record))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text(sizeText(record.usage.totalBytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Image(systemName: record.isCleanable
                  ? (selectedBundleIDs.contains(record.id) ? "checkmark.circle.fill" : "circle")
                  : "lock.circle")
                .font(.system(size: AppTheme.selectionIconSize, weight: .medium))
                .foregroundStyle(
                    record.isCleanable && selectedBundleIDs.contains(record.id)
                        ? AppTheme.accent
                        : Color.secondary
                )
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(record.app.displayName + ", " + record.app.bundleID))
        .accessibilityValue(
            selectedBundleIDs.contains(record.id)
                ? language.text("cleaner.accessibility_selected")
                : language.text("cleaner.accessibility_not_selected")
        )
    }

    /// "Bộ nhớ đệm X · Tạm Y" (WQFiles parity), with "Không rõ" and the
    /// limited suffix for rows that could not be fully measured.
    private func rowDetailText(for record: CleanerAppRecord) -> String {
        let unknown = language.text("cleaner.row_unknown")
        let detail = language.text(
            "cleaner.row_detail",
            record.limited ? unknown : sizeText(record.usage.cacheBytes),
            record.limited ? unknown : sizeText(record.usage.temporaryBytes)
        )
        return record.limited ? detail + language.text("cleaner.row_limited") : detail
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !records.isEmpty || !customRows.isEmpty {
            ToolbarItem(placement: .navigationBarLeading) {
                selectionMenu
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if isCleaning {
                    stopCleanButton
                } else if isScanning {
                    pauseScanButton
                } else if scanPaused {
                    resumeScanButton
                }
                sortMenu
                refreshButton
                settingsButton
            }
        } else {
            ToolbarItem(placement: .navigationBarLeading) {
                if isScanning {
                    pauseScanButton
                } else if scanPaused {
                    resumeScanButton
                } else {
                    refreshButton
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                settingsButton
            }
        }
    }

    private var pauseScanButton: some View {
        Button { pauseScan() } label: {
            Image(systemName: "pause.circle")
        }
        .accessibilityLabel(language.text("cleaner.pause_scan"))
    }

    private var resumeScanButton: some View {
        Button { reload(resume: true) } label: {
            Image(systemName: "play.circle")
        }
        .accessibilityLabel(language.text("cleaner.resume_scan"))
    }

    private var stopCleanButton: some View {
        Button { cleanStopToken?.cancel(reason: "user stopped cleaning") } label: {
            Image(systemName: "stop.circle")
        }
        .accessibilityLabel(language.text("cleaner.stop_clean"))
    }

    private var settingsButton: some View {
        Button { onOpenSettings() } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel(language.text("settings.title"))
    }

    private var selectionMenu: some View {
        Menu {
            Button {
                selectedBundleIDs = CleanerCatalog.selectingAllVisible(
                    visibleBundleIDs,
                    preserving: selectedBundleIDs
                )
            } label: {
                Label(
                    searchText.isEmpty
                        ? language.text("patch.select_all")
                        : language.text("cleaner.select_all_results"),
                    systemImage: "checkmark.circle"
                )
            }
            .disabled(areAllVisibleRecordsSelected)

            Button {
                selectedBundleIDs.removeAll()
            } label: {
                Label(language.text("patch.deselect_all"), systemImage: "circle")
            }
            .disabled(selectedBundleIDs.isEmpty)

            Button {
                selectedBundleIDs = CleanerCatalog.invertedVisible(
                    visibleBundleIDs, selected: selectedBundleIDs
                )
            } label: {
                Label(language.text("cleaner.invert_selection"), systemImage: "circle.lefthalf.filled")
            }
            .disabled(visibleBundleIDs.isEmpty)

            Button {
                selectedBundleIDs = CleanerCatalog.selectingLarge(
                    filteredRecords
                        .filter { $0.isIdentified && !$0.limited }
                        .map { (id: $0.id, bytes: $0.usage.totalBytes) },
                    preserving: selectedBundleIDs
                )
            } label: {
                Label(language.text("cleaner.select_large"), systemImage: "arrow.up.circle")
            }
            .disabled(visibleBundleIDs.isEmpty)
        } label: {
            Image(systemName: "checklist")
        }
        .disabled(isBusy)
        .accessibilityLabel(language.text("cleaner.selection_actions"))
    }

    private var sortMenu: some View {
        Menu {
            Picker(language.text("cleaner.sort"), selection: $sortOrder) {
                Label(
                    language.text("cleaner.sort_largest_first"),
                    systemImage: "arrow.down"
                )
                .tag(CleanerSortOrder.largestFirst)

                Label(
                    language.text("cleaner.sort_smallest_first"),
                    systemImage: "arrow.up"
                )
                .tag(CleanerSortOrder.smallestFirst)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .disabled(isBusy)
        .accessibilityLabel(language.text("cleaner.sort"))
    }

    private var refreshButton: some View {
        Button { reload(refreshLaunchServices: true) } label: {
            if isScanning {
                ProgressView()
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .disabled(isBusy)
        .accessibilityLabel(language.text("cleaner.scan_again"))
    }

    private var cleanAction: some View {
        Button {
            activeAlert = .confirmation
        } label: {
            HStack(spacing: 8) {
                if isCleaning {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "trash")
                }
                Text(
                    isCleaning
                        ? (cleaningProgressText.isEmpty
                            ? language.text("cleaner.cleaning")
                            : cleaningProgressText)
                        : language.text("cleaner.clean_button", sizeText(selectedBytes))
                )
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(selectedItemCount == 0 || isBusy || cleanRequiresRescan)
        .padding(.vertical, 4)
    }

    private var emptySection: some View {
        Section {
            VStack(spacing: 12) {
                if isScanning {
                    ProgressView()
                    Text(language.text("cleaner.scanning"))
                        .font(.headline)
                    Text(language.text("cleaner.scanned_count", Int64(scannedAppCount)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(language.text("cleaner.empty_title"))
                        .font(.headline)
                    Text(language.text("cleaner.empty_message"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button(language.text("cleaner.scan_again")) { reload(refreshLaunchServices: true) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        }
    }

    private func alert(for alert: CleanerAlert) -> Alert {
        switch alert {
        case .confirmation:
            return Alert(
                title: Text(language.text("cleaner.confirm_title")),
                message: Text(
                    selectedCustomKeys.isEmpty
                        ? language.text(
                            "cleaner.confirm_message",
                            Int64(selectedItemCount),
                            sizeText(selectedBytes)
                        )
                        : language.text(
                            "cleaner.confirm_message_custom",
                            Int64(selectedItemCount),
                            sizeText(selectedBytes)
                        )
                ),
                primaryButton: .destructive(Text(language.text("cleaner.confirm_action"))) {
                    // Three-stage gate (WQManager parity): the alert tap only
                    // acknowledges the scope; the actual run must still pass
                    // authorize() bound to the same operation id.
                    let operationID = UUID().uuidString
                    guard confirmationGate.begin(operationID: operationID),
                          confirmationGate.acknowledgeScope(operationID: operationID),
                          confirmationGate.authorize(operationID: operationID) else {
                        confirmationGate.cancel()
                        return
                    }
                    defer { confirmationGate.finish(operationID: operationID) }
                    cleanSelectedApps()
                },
                secondaryButton: .cancel(Text(language.text("common.cancel"))) {
                    confirmationGate.cancel()
                }
            )
        case .result(let message):
            return Alert(
                title: Text(language.text("cleaner.result_title")),
                message: Text(message),
                dismissButton: .default(Text(language.text("common.done")))
            )
        case .crashConfirmation:
            return Alert(
                title: Text(language.text("cleaner.crash.confirm_title")),
                message: Text(language.text("cleaner.crash.confirm_message")),
                primaryButton: .destructive(Text(language.text("cleaner.crash.clean"))) {
                    cleanCrashLogs()
                },
                secondaryButton: .cancel(Text(language.text("common.cancel")))
            )
        case .crashResult(let message):
            return Alert(
                title: Text(language.text("cleaner.crash.result_title")),
                message: Text(message),
                dismissButton: .default(Text(language.text("common.done")))
            )
        case .limited:
            return Alert(
                title: Text(language.text("cleaner.limited_title")),
                message: Text(language.text("cleaner.limited_message")),
                dismissButton: .default(Text(language.text("common.done")))
            )
        }
    }

    private func loadCrashLogs() {
        DispatchQueue.global(qos: .utility).async {
            let summary = CrashLogCleaner.scan()
            DispatchQueue.main.async {
                crashSummary = summary
            }
        }
    }

    private func cleanCrashLogs() {
        isCrashBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = CrashLogCleaner.clean()
            let summary = CrashLogCleaner.scan()
            DispatchQueue.main.async {
                isCrashBusy = false
                crashSummary = summary
                activeAlert = .crashResult(message: language.text(
                    "cleaner.crash.result",
                    Int64(result.removed),
                    Int64(result.failed),
                    sizeText(result.freedBytes)
                ))
            }
        }
    }

    private func toggleSelection(_ bundleID: String) {
        guard let record = records.first(where: { $0.id == bundleID }) else { return }
        guard record.isCleanable else {
            activeAlert = .limited
            return
        }
        if selectedBundleIDs.contains(bundleID) {
            selectedBundleIDs.remove(bundleID)
        } else {
            selectedBundleIDs.insert(bundleID)
        }
    }

    private func toggleCustomSelection(_ key: String) {
        guard let row = customRows.first(where: { $0.id == key }) else { return }
        guard !row.limited else {
            activeAlert = .limited
            return
        }
        if selectedCustomKeys.contains(key) {
            selectedCustomKeys.remove(key)
        } else {
            selectedCustomKeys.insert(key)
        }
    }

    private func removeCustomRow(_ row: CleanerCustomRow) {
        CleanerCustomTargets.remove(
            bundleID: row.target.bundleID, relativePath: row.target.relativePath
        )
        customRows.removeAll { $0.id == row.id }
        selectedCustomKeys.remove(row.id)
        customSnapshots.removeValue(forKey: row.id)
        log("cleaner: custom target removed from list \(row.target.relativePath)")
    }

    private func refreshCustomRowAutoSelect(_ key: String, autoSelect: Bool) {
        guard let index = customRows.firstIndex(where: { $0.id == key }) else { return }
        let row = customRows[index]
        let target = CleanerCustomTarget(
            bundleID: row.target.bundleID,
            appName: row.target.appName,
            containerPath: row.target.containerPath,
            relativePath: row.target.relativePath,
            isFile: row.target.isFile,
            autoSelect: autoSelect
        )
        customRows[index] = CleanerCustomRow(
            target: target, bytes: row.bytes, limited: row.limited
        )
        if autoSelect && !row.limited {
            selectedCustomKeys.insert(key)
        }
    }

    private func reload(refreshLaunchServices: Bool = false, resume: Bool = false) {
        guard !isBusy else { return }
        if refreshLaunchServices {
            ContainerStore.refreshLaunchServicesSnapshot()
        }
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-cleaner-empty") {
            records = []
            selectedBundleIDs = []
            scannedAppCount = 388
            isScanning = false
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--simulate-cleaner-data") {
            let samples = [
                CleanerAppRecord(
                    app: InstalledApp(
                        bundleID: "com.lemon.lvoverseas",
                        name: "CapCut",
                        containerPath: "/tmp/CapCut",
                        version: "",
                        icon: nil
                    ),
                    usage: LimitedCleanerUsage(
                        cacheBytes: 184_549_376,
                        temporaryBytes: 12_582_912,
                        removableItemCount: 284
                    )
                ),
                CleanerAppRecord(
                    app: InstalledApp(
                        bundleID: "com.apple.Maps",
                        name: "Maps",
                        containerPath: "/tmp/Maps",
                        version: "",
                        icon: nil
                    ),
                    usage: LimitedCleanerUsage(
                        cacheBytes: 61_865_984,
                        temporaryBytes: 3_145_728,
                        removableItemCount: 92
                    )
                ),
                CleanerAppRecord(
                    app: InstalledApp(
                        bundleID: "com.apple.mobilesafari",
                        name: "Safari",
                        containerPath: "/tmp/Safari",
                        version: "",
                        icon: nil
                    ),
                    usage: LimitedCleanerUsage(
                        cacheBytes: 27_262_976,
                        temporaryBytes: 1_048_576,
                        removableItemCount: 48
                    )
                )
            ]
            records = samples
            selectedBundleIDs = Set(samples.prefix(2).map(\.id))
            scannedAppCount = 388
            isScanning = false
            if ProcessInfo.processInfo.arguments.contains("--simulate-cleaner-warning") {
                activeAlert = .confirmation
            }
            return
        }
#endif
        let requestID = UUID()
        scanID = requestID
        isScanning = true
        scanPaused = false
        scannedAppCount = 0
        // A fresh scan never destroys the last completed result (WQScanTask
        // parity): the previous list stays visible until the new scan
        // finishes; a scan from an empty list starts empty.
        let hadPreviousResult = !records.isEmpty || !customRows.isEmpty
        if !hadPreviousResult {
            selectedBundleIDs.removeAll()
            selectedCustomKeys.removeAll()
            records.removeAll()
            customRows.removeAll()
        }
        // Task identity: a resumed scan keeps its identifier so its
        // measurement checkpoints stay valid; a fresh scan starts a new one.
        let taskID: String
        if resume, let resumable = CleanerScanJournal.loadTask(), resumable.isResumable {
            taskID = resumable.identifier
        } else {
            taskID = UUID().uuidString
        }
        scanTaskID = taskID
        let stopToken = CancellationToken()
        scanStopToken = stopToken
        let previousEncodedRows = encodeScanRows(records)
        // Mark the task unfinished now, so a kill mid-scan leaves it
        // resumable; the previous result rows are kept in the record.
        CleanerScanJournal.saveTask(
            CleanerScanJournal.ScanTaskRecord(
                identifier: taskID,
                finishedAt: lastScanFinishedAt,
                userPaused: false,
                interrupted: true,
                status: "",
                resultRows: hadPreviousResult ? previousEncodedRows : nil
            )
        )

        DispatchQueue.global(qos: .userInitiated).async {
            var scannedBundleIDs = Set<String>()
            var examinedBundleIDs = Set<String>()
            var discoveredRecords: [CleanerAppRecord] = []
            var discoveredSnapshots: [String: CleanerItemSnapshot] = [:]
            var processedCount = 0
            var lastPublishAt = Date.distantPast
            let keepPreviousUntilFinish = hadPreviousResult

            func finishPaused() {
                DispatchQueue.main.async {
                    guard scanID == requestID else { return }
                    isScanning = false
                    scanPaused = true
                    scanStopToken = nil
                    CleanerScanJournal.saveTask(
                        CleanerScanJournal.ScanTaskRecord(
                            identifier: taskID,
                            finishedAt: lastScanFinishedAt,
                            userPaused: true,
                            interrupted: false,
                            status: "",
                            resultRows: previousEncodedRows
                        )
                    )
                    log("cleaner: scan paused, checkpoints kept task=\(taskID)")
                }
            }

            func publish(force: Bool = false) {
                // Publishing after every app floods the main queue when a
                // device has hundreds of apps; switching tabs then freezes.
                // Throttle to a few updates per second and flush at the end of
                // each batch.
                let now = Date()
                guard force || now.timeIntervalSince(lastPublishAt) >= 0.25 else {
                    return
                }
                lastPublishAt = now
                let snapshot = discoveredRecords.sorted {
                    $0.app.displayName.localizedCaseInsensitiveCompare($1.app.displayName) == .orderedAscending
                }
                let count = processedCount
                DispatchQueue.main.async {
                    guard scanID == requestID else { return }
                    scannedAppCount = count
                    // While a previous result is on screen, hold it until
                    // the new scan finishes (WQScanTask parity).
                    guard !keepPreviousUntilFinish else { return }
                    records = snapshot
                }
            }

            func scanNewApps(_ applications: [InstalledApp]) {
                let metadata = Dictionary(
                    applications.map {
                        ($0.bundleID, $0)
                    },
                    uniquingKeysWith: { first, _ in first }
                )
                let catalogApplications = applications.map {
                    CleanerResolvedApplication(
                        bundleID: $0.bundleID,
                        name: $0.name,
                        containerPath: $0.containerPath,
                        version: $0.version
                    )
                }
                _ = CleanerCatalog.scanNewApplications(
                    catalogApplications,
                    scannedBundleIDs: &scannedBundleIDs,
                    // Unidentified containers are scanned too: they are real
                    // app data and the user asked to see everything. They are
                    // shown with a lock and cannot be selected for cleaning.
                    shouldIncludeBundleID: { _ in true },
                    activateContainer: { application in
                        // Filesystem enumeration already knows the exact
                        // container; do not throw it away when MCM/LS fail.
                        if ContainerStore.isApplicationContainerPath(application.containerPath) {
                            return application.containerPath
                        }
                        if let resolved = ContainerStore.resolveAppContainerPath(
                            bundleID: application.bundleID
                        ), ContainerStore.isApplicationContainerPath(resolved) {
                            return resolved
                        }
                        return nil
                    },
                    isValidContainerPath: ContainerStore.isApplicationContainerPath,
                    usageForContainer: { containerPath in
                        guard !stopToken.isCancelled else { return nil }
                        do {
                            return try LimitedCleanerService.scan(
                                containerURL: URL(fileURLWithPath: containerPath, isDirectory: true),
                                rootValidator: { ContainerStore.isApplicationContainerPath($0.path) },
                                taskID: taskID
                            )
                        } catch {
                            log("cleaner: scan failed \(containerPath) error=\(error)")
                            return nil
                        }
                    },
                    onApplication: { bundleID in
                        guard examinedBundleIDs.insert(bundleID).inserted else { return }
                        processedCount = examinedBundleIDs.count
                        publish()
                    },
                    onRecord: { record in
                        let original = metadata[record.bundleID]
                        let resolvedApp = InstalledApp(
                            bundleID: record.bundleID,
                            name: record.application.name,
                            containerPath: record.containerPath,
                            version: record.application.version,
                            icon: original?.icon
                        )
                        discoveredRecords.append(
                            CleanerAppRecord(
                                app: resolvedApp, usage: record.usage,
                                limited: record.usage.limited
                            )
                        )
                        // Scan-time identity snapshot for the clean step
                        // (WQCacheValidateItem parity).
                        if let snapshot = LimitedCleanerService.snapshot(
                            forContainerPath: record.containerPath
                        ) {
                            discoveredSnapshots[record.bundleID] = snapshot.withBundleID(record.bundleID)
                        }
                    },
                    shouldStop: { stopToken.isCancelled }
                )
                publish(force: true)
            }

            let catalogApps = ContainerStore.installedAppsFromCatalog()
            if !catalogApps.isEmpty {
                log("cleaner: catalog fast path \(catalogApps.count) apps")
                scanNewApps(catalogApps)
            }
            if stopToken.isCancelled { finishPaused(); return }

            let apiApps = ContainerStore.installedAppsFromAPI()
            let dynamicIdentifiers = catalogApps.isEmpty
                ? ContainerStore.dynamicAppIdentifiers()
                : []
            let mcmApps = catalogApps.isEmpty
                ? ContainerStore.installedAppsFromMCM(identifiers: dynamicIdentifiers)
                : []
            scanNewApps(apiApps + mcmApps)
            if stopToken.isCancelled { finishPaused(); return }

            let launchServicesIdentifiers: [String] = catalogApps.isEmpty
                ? ContainerStore.launchServicesStoreIdentifiers()
                : Array(Set(catalogApps.map(\.bundleID)))

            // MCM/LS can be empty inside signing containers such as
            // LiveContainer; enumerate the app-data root directly and resolve
            // identities through the container index, exactly like App Data.
            let knownAppsByBundleID = Dictionary(
                (apiApps + mcmApps).map { ($0.bundleID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let resolvedFilesystemApps: [InstalledApp]
            if catalogApps.isEmpty {
                let token = ScanToken()
                _ = stopToken.onCancel { token.cancel() }
                DispatchQueue.main.async {
                    scanCoordinator.begin(
                        title: language.text("scan.title.cleaner"),
                        message: language.text("scan.message.cleaner"),
                        token: token
                    )
                }
                resolvedFilesystemApps = ContainerStore.containersFromFilesystem(token: token) { done, total in
                    DispatchQueue.main.async {
                        scanCoordinator.update(done: done, total: total)
                    }
                }.map {
                    ContainerStore.inferredApp(
                        for: $0,
                        knownAppsByBundleID: knownAppsByBundleID,
                        launchServicesIdentifiers: Set(launchServicesIdentifiers)
                    ) ?? $0
                }
                DispatchQueue.main.async {
                    scanCoordinator.finish()
                }
            } else {
                resolvedFilesystemApps = []
            }
            scanNewApps(resolvedFilesystemApps)
            if stopToken.isCancelled { finishPaused(); return }

            let candidates = catalogApps.isEmpty ? MHAIdentifierCatalog.identifiers(
                dynamic: dynamicIdentifiers,
                installed: apiApps.map(\.bundleID),
                research: ContainerStore.researchAppIdentifiers,
                custom: [],
                launchServices: launchServicesIdentifiers
            ) : []
            log("cleaner: resolving \(candidates.count) MHA-C2 bundle candidates")
            let mhaApps = ContainerStore.installedAppsFromMHACandidates(
                identifiers: candidates
            ) { progressiveApps in
                scanNewApps(progressiveApps)
            }
            scanNewApps(mhaApps)
            if stopToken.isCancelled { finishPaused(); return }
            log("cleaner: scan finished apps=\(scannedBundleIDs.count) records=\(discoveredRecords.count)")

            // Custom targets added from the file browser, measured now so
            // their sizes are current (WQFiles parity: custom rows are
            // measured during the scan like app rows).
            var measuredCustomRows: [CleanerCustomRow] = []
            var measuredCustomSnapshots: [String: CleanerItemSnapshot] = [:]
            for target in CleanerCustomTargets.all() {
                if stopToken.isCancelled { break }
                guard ContainerStore.isApplicationContainerPath(target.containerPath) else { continue }
                guard let measurement = LimitedCleanerService.measureCustomTarget(
                    containerURL: URL(fileURLWithPath: target.containerPath, isDirectory: true),
                    rootValidator: { ContainerStore.isApplicationContainerPath($0.path) },
                    target: target,
                    taskID: taskID
                ) else { continue }
                measuredCustomRows.append(
                    CleanerCustomRow(
                        target: target, bytes: measurement.bytes, limited: measurement.limited
                    )
                )
                measuredCustomSnapshots[target.id] = measurement.snapshot
            }
            if stopToken.isCancelled { finishPaused(); return }

            let finishedAt = Date()
            let encodedRows = encodeScanRows(discoveredRecords)
            DispatchQueue.main.async {
                guard scanID == requestID else { return }
                isScanning = false
                scanPaused = false
                scanStopToken = nil
                // The rescan a failed clean forced has now finished: the
                // Clean button may be used again (WQFiles parity:
                // _cleanRequiresRescan clears on the new scan).
                cleanRequiresRescan = false
                records = discoveredRecords.sorted {
                    $0.app.displayName.localizedCaseInsensitiveCompare($1.app.displayName) == .orderedAscending
                }
                itemSnapshots = discoveredSnapshots
                customRows = measuredCustomRows
                customSnapshots = measuredCustomSnapshots
                scannedAppCount = processedCount
                lastScanFinishedAt = finishedAt
                // A scan finishing on this screen auto-selects what can be
                // cleaned (WQFiles parity, 0.9.10 #67); historical results
                // never restore a destructive selection implicitly.
                selectedBundleIDs = Set(records.filter(\.isCleanable).map(\.id))
                selectedCustomKeys = Set(
                    customRows.filter { $0.target.autoSelect && !$0.limited }.map(\.id)
                )
                CleanerScanJournal.saveTask(
                    CleanerScanJournal.ScanTaskRecord(
                        identifier: taskID,
                        finishedAt: finishedAt,
                        userPaused: false,
                        interrupted: false,
                        status: "",
                        resultRows: encodedRows
                    )
                )
                log(
                    "cleaner: scan complete bundles=\(processedCount) " +
                        "reclaimableApps=\(discoveredRecords.count)"
                )
            }
        }
    }

    /// Restores the last completed scan result from the journal when one
    /// exists (WQScanTask parity). Returns true when a result was restored;
    /// sets `scanPaused` when the task was interrupted or user-paused.
    /// Snapshots are not persisted with the rows: cleaning a restored
    /// result re-captures its snapshot in the clean step itself.
    private func restoreLastScanResult() -> Bool {
        guard let task = CleanerScanJournal.loadTask() else { return false }
        scanTaskID = task.identifier
        lastScanFinishedAt = task.finishedAt
        if let rows = task.resultRows, !rows.isEmpty {
            records = decodeScanRows(rows)
            scannedAppCount = records.count
            scanPaused = task.isResumable
            return true
        }
        if task.isResumable {
            scanPaused = true
        }
        return false
    }

    private func encodeScanRows(_ rows: [CleanerAppRecord]) -> [[String: Any]] {
        rows.map { record in
            [
                "bundleID": record.app.bundleID,
                "name": record.app.displayName,
                "containerPath": record.app.containerPath,
                "cacheBytes": record.usage.cacheBytes,
                "tempBytes": record.usage.temporaryBytes,
                "files": record.usage.removableItemCount,
                "limited": record.limited,
            ] as [String: Any]
        }
    }

    private func decodeScanRows(_ rows: [[String: Any]]) -> [CleanerAppRecord] {
        rows.compactMap { row in
            guard let bundleID = row["bundleID"] as? String,
                  let containerPath = row["containerPath"] as? String else { return nil }
            let app = InstalledApp(
                bundleID: bundleID,
                name: row["name"] as? String ?? bundleID,
                containerPath: containerPath,
                version: "",
                icon: nil
            )
            let usage = LimitedCleanerUsage(
                cacheBytes: row["cacheBytes"] as? Int64 ?? 0,
                temporaryBytes: row["tempBytes"] as? Int64 ?? 0,
                removableItemCount: row["files"] as? Int ?? 0,
                limited: row["limited"] as? Bool ?? false
            )
            return CleanerAppRecord(app: app, usage: usage, limited: usage.limited)
        }
    }

    private func pauseScan() {
        scanStopToken?.cancel(reason: "user paused scan")
    }
    private func cleanSelectedApps() {
        guard !isBusy else { return }
        let selectedRecords = records.filter { selectedBundleIDs.contains($0.id) }
        let selectedCustomRows = customRows.filter { selectedCustomKeys.contains($0.id) }
        guard !selectedRecords.isEmpty || !selectedCustomRows.isEmpty else { return }
        isCleaning = true
        cleaningProgressText = ""
        let stopToken = CancellationToken()
        cleanStopToken = stopToken

        DispatchQueue.global(qos: .userInitiated).async {
            var updatedUsage: [String: LimitedCleanerUsage] = [:]
            var freedBytes: Int64 = 0
            var removedItems = 0
            var failedItems = 0
            var unavailableApps = 0
            var validationReason: String?
            let totalSelected = selectedRecords.count + selectedCustomRows.count
            var processedIndex = 0
            var lastProgressPublish = Date.distantPast

            func publishProgress(name: String) {
                processedIndex += 1
                // Throttled per-app progress: the clean of many large apps
                // takes minutes; a bare spinner read as "hung".
                let now = Date()
                guard now.timeIntervalSince(lastProgressPublish) >= 0.5 else { return }
                lastProgressPublish = now
                let progressText = language.text(
                    "cleaner.progress",
                    processedIndex, totalSelected,
                    sizeText(freedBytes), name
                )
                DispatchQueue.main.async {
                    cleaningProgressText = progressText
                }
            }

            func resolveContainer(for record: CleanerAppRecord) -> String? {
                // The scan already resolved the exact container. Re-resolving
                // by bundle id fails whenever MCM is unavailable.
                if ContainerStore.isApplicationContainerPath(record.app.containerPath) {
                    return record.app.containerPath
                }
                return ContainerStore.resolveAppContainerPath(bundleID: record.app.bundleID)
            }

            for record in selectedRecords {
                if stopToken.isCancelled || validationReason != nil { break }
                publishProgress(name: record.app.displayName)
                guard let containerPath = resolveContainer(for: record) else {
                    unavailableApps += 1
                    log("cleaner: bundle unavailable \(record.app.bundleID)")
                    continue
                }
                log("cleaner: cleaning \(record.app.bundleID) at \(containerPath)")

                do {
                    let result = try LimitedCleanerService.clean(
                        containerURL: URL(fileURLWithPath: containerPath, isDirectory: true),
                        rootValidator: { ContainerStore.isApplicationContainerPath($0.path) },
                        snapshot: itemSnapshots[record.id],
                        taskID: nil,
                        shouldStop: { stopToken.isCancelled }
                    )
                    updatedUsage[record.id] = result.after
                    freedBytes += result.freedBytes
                    removedItems += result.removedItemCount
                    failedItems += result.failedItemCount
                    log(
                        "cleaner: cleaned \(record.app.bundleID) " +
                            "freed=\(result.freedBytes) removed=\(result.removedItemCount) " +
                            "failed=\(result.failedItemCount)"
                    )
                } catch let error as LimitedCleanerError {
                    if case .validationFailed(let reason) = error {
                        // Pre-delete revalidation failed: stop everything
                        // and force a rescan before any retry (WQFiles
                        // parity: _cleanRequiresRescan).
                        validationReason = "\(record.app.displayName) (\(reason))"
                        log("cleaner: refusing \(record.app.bundleID) because \(reason)")
                    } else {
                        unavailableApps += 1
                        log("cleaner: failed \(record.app.bundleID) error=\(error)")
                    }
                } catch {
                    unavailableApps += 1
                    log("cleaner: failed \(record.app.bundleID) error=\(error)")
                }
            }

            for row in selectedCustomRows {
                if stopToken.isCancelled || validationReason != nil { break }
                publishProgress(name: row.target.appName)
                let target = row.target
                log("cleaner: cleaning custom target \(target.relativePath) of \(target.bundleID)")
                do {
                    let result = try LimitedCleanerService.cleanCustomTarget(
                        target,
                        containerURL: URL(fileURLWithPath: target.containerPath, isDirectory: true),
                        rootValidator: { ContainerStore.isApplicationContainerPath($0.path) },
                        snapshot: customSnapshots[row.id]
                    )
                    freedBytes += result.freedBytes
                    removedItems += result.removed
                    failedItems += result.failed
                } catch let error as LimitedCleanerError {
                    if case .validationFailed(let reason) = error {
                        validationReason = "\(target.appName) (\(reason))"
                        log("cleaner: refusing custom target \(target.relativePath) because \(reason)")
                    } else {
                        failedItems += 1
                        log("cleaner: failed custom target \(target.relativePath) error=\(error)")
                    }
                } catch {
                    failedItems += 1
                    log("cleaner: failed custom target \(target.relativePath) error=\(error)")
                }
            }

            // Re-measure the custom rows so their new sizes show without a
            // full rescan (app rows were already re-measured by clean()).
            var refreshedCustomRows: [CleanerCustomRow] = []
            var refreshedCustomSnapshots: [String: CleanerItemSnapshot] = [:]
            for row in customRows {
                guard let measurement = LimitedCleanerService.measureCustomTarget(
                    containerURL: URL(fileURLWithPath: row.target.containerPath, isDirectory: true),
                    rootValidator: { ContainerStore.isApplicationContainerPath($0.path) },
                    target: row.target
                ) else { continue }
                refreshedCustomRows.append(
                    CleanerCustomRow(
                        target: row.target, bytes: measurement.bytes, limited: measurement.limited
                    )
                )
                refreshedCustomSnapshots[row.id] = measurement.snapshot
            }

            let stopped = stopToken.isCancelled
            let resultMessage: String
            if let reason = validationReason {
                resultMessage = language.text("cleaner.validation_message", reason)
            } else if stopped {
                resultMessage = language.text(
                    "cleaner.clean_stopped",
                    sizeText(freedBytes),
                    Int64(removedItems),
                    Int64(failedItems + unavailableApps)
                )
            } else {
                resultMessage = language.text(
                    "cleaner.result_message",
                    sizeText(freedBytes),
                    Int64(removedItems),
                    Int64(failedItems + unavailableApps)
                )
            }
            let cleanedCount = selectedRecords.count - unavailableApps
            let historyEntry = CleanerHistoryEntry(
                cleanedAppCount: max(0, cleanedCount),
                failedItemCount: failedItems + unavailableApps,
                freedBytes: freedBytes
            )
            DispatchQueue.main.async {
                records = records.compactMap { record in
                    guard let usage = updatedUsage[record.id] else { return record }
                    guard usage.totalBytes >= CleanerCatalog.minimumVisibleBytes || usage.limited else {
                        return nil
                    }
                    return CleanerAppRecord(app: record.app, usage: usage, limited: usage.limited)
                }
                customRows = refreshedCustomRows
                customSnapshots = refreshedCustomSnapshots
                cleaningProgressText = ""
                selectedBundleIDs.removeAll()
                selectedCustomKeys.removeAll()
                cleanerHistory = CleanerHistory.record(historyEntry)
                ActivityHistory.log(
                    .clean,
                    feature: "cleaner",
                    "apps=\(historyEntry.cleanedAppCount) freed=\(historyEntry.totalFreedBytes)"
                )
                isCleaning = false
                cleanStopToken = nil
                activeAlert = .result(message: resultMessage)
                // A stopped or validation-failed clean leaves sizes
                // uncertain: rescan before the next clean (WQFiles parity:
                // rescanAfterClean). A completed clean already re-measured.
                if stopped || validationReason != nil {
                    cleanRequiresRescan = true
                    reload()
                }
            }
        }
    }
    private func sizeText(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

private struct CleanerAppRecord: Identifiable {
    let app: InstalledApp
    let usage: LimitedCleanerUsage
    let limited: Bool

    init(app: InstalledApp, usage: LimitedCleanerUsage, limited: Bool = false) {
        self.app = app
        self.usage = usage
        self.limited = limited
    }

    var id: String { app.bundleID }
    var isIdentified: Bool {
        ContainerPresentationPolicy.isIdentified(bundleID: app.bundleID)
    }
    /// Cleanable rows only: identified and fully measured (WQFiles parity:
    /// limited rows are shown, never cleaned).
    var isCleanable: Bool {
        isIdentified && !limited
    }
}

/// One folder/file added to the Cache Cleaner from the file browser.
private struct CleanerCustomRow: Identifiable {
    let target: CleanerCustomTarget
    let bytes: Int64
    let limited: Bool

    var id: String { target.id }
}

private enum CleanerAlert: Identifiable {
    case confirmation
    case result(message: String)
    case crashConfirmation
    case crashResult(message: String)
    case limited

    var id: String {
        switch self {
        case .confirmation: return "confirmation"
        case .crashConfirmation: return "crashConfirmation"
        case .limited: return "limited"
        case .result(let message): return "result-\(message)"
        case .crashResult(let message): return "crashResult-\(message)"
        }
    }
}
