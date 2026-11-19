import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Passcode Themes (apply .passthm + Theme Creator)
//
// Ported from AirCard-iOS v1.3.2 (MIT), PasscodeThemeTab + ApplyThemeSection
// + ThemeCreatorSection + KeypadPreviewView. Two modes:
//  - Apply: load a local .passthm file and flash it via Airlift.
//  - Create: build a theme from a poster photo (sliced per key) or from
//    per-key photos, preview it live, export it as .passthm, or flash it
//    directly. The target pickers and the flash button are shared by both
//    modes (the store branches on mode internally).
// Pairing / VPN UI is reused from the Wallet flow (WalletVPNStatusRow +
// the shared WalletCardStore) — only a compact pairing row lives here.

struct PasscodeThemesView: View {
    @Environment(\.appLanguage) private var language
    @EnvironmentObject var store: PasscodeThemeStore
    @EnvironmentObject var walletStore: WalletCardStore
    @State private var showDocumentPicker = false
    @State private var showFlashConfirm = false

    // Theme Creator picker state
    @State private var selectedDigitForPicker: String? = nil
    @State private var showKeySourceDialog = false
    @State private var isKeyPhotosPickerPresented = false
    @State private var isKeyDocumentPickerPresented = false
    @State private var selectedKey: [PhotosPickerItem] = []

    @State private var showPosterSourceDialog = false
    @State private var isPosterPhotosPickerPresented = false
    @State private var isPosterDocumentPickerPresented = false
    @State private var selectedPoster: [PhotosPickerItem] = []

    var body: some View {
        NavigationStack {
            Form {
                modeSection

                pairingSection

                if store.passcodeMode == .applyTheme {
                    applySections
                } else {
                    creatorSections
                }

                if store.passcodeMode == .themeCreator || store.loadedTheme != nil {
                    targetSection

                    actionSection

                    if !walletStore.hasPairingFile {
                        Section {
                            Text(language.text("passcode.hint.no_pairing"))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if !store.passthmFlashLog.isEmpty {
                    Section {
                        CompactLogView(
                            title: language.text("passcode.log.title", store.passthmFlashLog.count),
                            lines: store.passthmFlashLog,
                            onClear: { store.passthmFlashLog.removeAll() }
                        )
                    }
                }

                Section(language.text("passcode.help.title")) {
                    helpText(language.text("passcode.help.vs_keypad"))
                    helpText(language.text("passcode.help.destructive"))
                    helpText(language.text("passcode.help.no_backup"))
                    helpText(language.text("passcode.help.ios"))
                    helpText(language.text("passcode.help.lock"))
                }
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 60)
            }
            .navigationTitle(language.text("passcode.title"))
            .onAppear { store.scanDocumentsDirectory() }
            .sheet(isPresented: Binding(
                get: { store.exportedThemeURL != nil },
                set: { if !$0 { store.exportedThemeURL = nil; store.showShareSheet = false } }
            )) {
                if let url = store.exportedThemeURL {
                    ActivityShareSheet(items: [url])
                }
            }
            .alert(
                language.text("passcode.flash.confirm_title"),
                isPresented: $showFlashConfirm
            ) {
                Button(language.text("passcode.flash.confirm_apply"), role: .destructive) {
                    store.flashPassthm()
                }
                Button(language.text("common.cancel"), role: .cancel) {}
            } message: {
                Text(language.text("passcode.flash.confirm_message"))
            }
            .alert(
                language.text("passcode.error.title"),
                isPresented: .init(
                    get: { store.errorMessage != nil },
                    set: { if !$0 { store.errorMessage = nil } }
                )
            ) {
                Button(language.text("common.ok"), role: .cancel) {
                    store.errorMessage = nil
                }
            } message: {
                Text(store.errorMessage ?? "")
            }
            .alert(
                language.text("passcode.title"),
                isPresented: $store.showFlashAlert
            ) {
                Button(language.text("common.ok"), role: .cancel) {
                    store.showFlashAlert = false
                }
            } message: {
                Text(store.flashResultMessage ?? "")
            }
        }
    }

    // MARK: - Mode picker

    private var modeSection: some View {
        Section {
            Picker(language.text("passcode.mode.title"), selection: $store.passcodeMode) {
                ForEach(CreatorMode.allCases) { mode in
                    Text(language.text(mode.titleKey)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Apply mode

    @ViewBuilder
    private var applySections: some View {
        if !store.documentsThemes.isEmpty {
            Section(language.text("passcode.section.documents")) {
                ForEach(store.documentsThemes, id: \.self) { file in
                    HStack {
                        Image(systemName: "paintpalette.fill")
                            .foregroundStyle(.pink)
                        Text(file)
                            .font(.system(size: 13, design: .monospaced))
                        Spacer()
                        Button(language.text("passcode.load")) {
                            store.loadPassthmFromDocuments(filename: file)
                        }
                        .font(.caption.bold())
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
        }

        Section(language.text("passcode.section.browse")) {
            HStack {
                Button {
                    showDocumentPicker = true
                } label: {
                    Label(store.loadedTheme == nil
                          ? language.text("passcode.browse.choose")
                          : language.text("passcode.browse.change"),
                          systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                if store.loadedTheme != nil {
                    Button {
                        store.clearLoadedTheme()
                    } label: {
                        Text(language.text("passcode.browse.clear"))
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .sheet(isPresented: $showDocumentPicker) {
                DocumentPickerView(allowedContentTypes: [
                    UTType(filenameExtension: "passthm") ?? .archive,
                    UTType.zip,
                    UTType.archive
                ]) { url in
                    store.loadPassthm(url: url)
                }
            }
        }

        if let theme = store.loadedTheme {
            Section(language.text("passcode.section.preview")) {
                PasscodeKeypadPreviewView(keys: theme.keysPreview)
                    .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
                    .listRowBackground(Color.clear)
            }

            Section(language.text("passcode.section.info")) {
                LabeledContent(language.text("passcode.info.files"), value: "\(theme.fileCount)")
                LabeledContent(language.text("passcode.info.digits"), value: "\(theme.keysPreview.count)")
                if let last = store.lastAppliedThemeName {
                    LabeledContent(language.text("passcode.info.last_applied"), value: last)
                }

                Button {
                    store.adoptThemeIntoCreator()
                } label: {
                    Label(language.text("passcode.creator.adopt"), systemImage: "pencil")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Theme Creator mode

    @ViewBuilder
    private var creatorSections: some View {
        Section(language.text("passcode.creator.slice_mode")) {
            Picker("", selection: $store.sliceMode) {
                ForEach(SliceMode.allCases) { m in
                    Text(language.text(m.titleKey)).tag(m)
                }
            }
            .pickerStyle(.segmented)
        }

        if store.sliceMode == .posterSlice {
            posterSliceSection
        } else {
            individualKeysSection
        }

        Section(language.text("passcode.section.preview")) {
            PasscodeKeypadPreviewView(keys: store.effectiveKeys)
                .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
                .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var posterSliceSection: some View {
        Section(language.text("passcode.creator.poster_section")) {
                Button {
                    showPosterSourceDialog = true
                } label: {
                    Label(store.posterImage == nil
                          ? language.text("passcode.creator.poster_select")
                          : language.text("passcode.creator.poster_change"),
                          systemImage: "photo")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .confirmationDialog(
                language.text("passcode.creator.poster_source_title"),
                isPresented: $showPosterSourceDialog,
                titleVisibility: .visible
            ) {
                Button {
                    isPosterPhotosPickerPresented = true
                } label: {
                    Label(language.text("passcode.creator.poster_source_library"), systemImage: "photo.on.rectangle")
                }
                Button {
                    isPosterDocumentPickerPresented = true
                } label: {
                    Label(language.text("passcode.creator.poster_source_files"), systemImage: "folder")
                }
                Button(language.text("common.cancel"), role: .cancel) {}
            }
            .photosPicker(
                isPresented: $isPosterPhotosPickerPresented,
                selection: $selectedPoster,
                maxSelectionCount: 1,
                matching: .images
            )
            .onChange(of: selectedPoster) { _ in
                guard let item = selectedPoster.first else { return }
                Task {
                    if let image = await item.loadUIImage(maxDimension: 2560) {
                        await MainActor.run { store.setPosterImage(image) }
                    }
                    await MainActor.run { selectedPoster = [] }
                }
            }
            .sheet(isPresented: $isPosterDocumentPickerPresented) {
                DocumentPickerView(allowedContentTypes: [
                    .image, .png, .jpeg, .heic,
                    UTType(filenameExtension: "webp") ?? .image,
                    UTType(filenameExtension: "tiff") ?? .image
                ]) { url in
                    // Read the file synchronously while the security-scoped
                    // access granted by the picker is still held, then
                    // hand the decoded image to the store on the MainActor.
                    if let data = try? Data(contentsOf: url),
                       let image = ImageEngine.safeImageFromData(data, maxDimension: 2560) {
                        let img = image
                        Task { await MainActor.run { store.setPosterImage(img) } }
                    }
                }
            }

            if store.posterImage != nil {
                Section(language.text("passcode.creator.slicing_style")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $store.maskToCircles) {
                            Text(language.text("passcode.creator.style_seamless")).tag(false)
                            Text(language.text("passcode.creator.style_circles")).tag(true)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: store.maskToCircles) { _ in
                            store.updatePosterSlicing()
                        }

                        Text(store.maskToCircles
                             ? language.text("passcode.creator.style_hint_circles")
                             : language.text("passcode.creator.style_hint_seamless"))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(language.text("passcode.creator.zoom_title"))
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(language.text("passcode.creator.zoom_reset")) {
                                withAnimation(.spring()) {
                                    store.resetPosterPosition()
                                }
                            }
                            .font(.caption2)
                            .buttonStyle(.borderless)
                        }

                        HStack(spacing: 8) {
                            Image(systemName: "minus.magnifyingglass")
                                .foregroundColor(.secondary)
                                .font(.caption)

                            Slider(value: $store.posterZoom, in: 0.5...3.0, step: 0.05)
                                .onChange(of: store.posterZoom) { _ in
                                    store.updatePosterSlicing()
                                }

                            Image(systemName: "plus.magnifyingglass")
                                .foregroundColor(.secondary)
                                .font(.caption)

                            Text(String(format: "%.1fx", store.posterZoom))
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .frame(width: 38, alignment: .trailing)
                        }

                        HStack(spacing: 6) {
                            Image(systemName: "hand.draw")
                                .foregroundColor(.secondary)
                                .font(.caption2)
                            Text(language.text("passcode.creator.zoom_hint"))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
    }

    private var individualKeysSection: some View {
        Section(language.text("passcode.creator.keys_section")) {
            Text(language.text("passcode.creator.keys_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(KeypadLayout.allButtons) { btn in
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color(uiColor: .secondarySystemBackground))
                            .frame(width: 44, height: 44)
                        if let img = store.customKeys[btn.digit] {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 44, height: 44)
                                .clipShape(Circle())
                        } else {
                            Text(btn.digit)
                                .font(.title3.bold())
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(language.text("passcode.creator.key_title", btn.digit))
                            .font(.subheadline.weight(.medium))
                        if !btn.letters.isEmpty {
                            Text(btn.letters)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if store.customKeys[btn.digit] != nil {
                        Button(role: .destructive) {
                            store.clearIndividualKey(digit: btn.digit)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.blue)
                            .font(.title3)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedDigitForPicker = btn.digit
                    showKeySourceDialog = true
                }
            }
        }
        .confirmationDialog(
            language.text("passcode.creator.key_source_title", selectedDigitForPicker ?? ""),
            isPresented: $showKeySourceDialog,
            titleVisibility: .visible
        ) {
            Button {
                isKeyPhotosPickerPresented = true
            } label: {
                Label(language.text("passcode.creator.poster_source_library"), systemImage: "photo.on.rectangle")
            }
            Button {
                isKeyDocumentPickerPresented = true
            } label: {
                Label(language.text("passcode.creator.poster_source_files"), systemImage: "folder")
            }
            Button(language.text("common.cancel"), role: .cancel) {
                selectedDigitForPicker = nil
            }
        }
        .photosPicker(
            isPresented: $isKeyPhotosPickerPresented,
            selection: $selectedKey,
            maxSelectionCount: 1,
            matching: .images
        )
        .onChange(of: selectedKey) { _ in
            guard let item = selectedKey.first,
                  let digit = selectedDigitForPicker else {
                if selectedKey.isEmpty { selectedDigitForPicker = nil }
                return
            }
            let currentDigit = digit
            Task {
                if let image = await item.loadUIImage(maxDimension: 1024) {
                    await MainActor.run { store.setIndividualKey(digit: currentDigit, image: image) }
                }
                await MainActor.run {
                    selectedKey = []
                    selectedDigitForPicker = nil
                }
            }
        }
        .sheet(isPresented: $isKeyDocumentPickerPresented) {
            DocumentPickerView(allowedContentTypes: [
                .image, .png, .jpeg, .heic,
                UTType(filenameExtension: "webp") ?? .image,
                UTType(filenameExtension: "tiff") ?? .image
            ]) { url in
                guard let digit = selectedDigitForPicker else { return }
                // Read the file synchronously while the security-scoped
                // access granted by the picker is still held, then hand
                // the decoded image to the store on the MainActor.
                if let data = try? Data(contentsOf: url),
                   let image = ImageEngine.safeImageFromData(data, maxDimension: 1024) {
                    let img = image
                    Task { await MainActor.run { store.setIndividualKey(digit: digit, image: img) } }
                }
                selectedDigitForPicker = nil
            }
        }
    }

    // MARK: - Shared action section (target pickers + flash)

    private var actionSection: some View {
        Section {
            VStack(spacing: 12) {
                flashButton

                if store.passcodeMode == .themeCreator {
                    if !store.effectiveKeys.isEmpty {
                        Button {
                            _ = store.exportPassthm()
                        } label: {
                            HStack(spacing: 8) {
                                Spacer()
                                Image(systemName: "square.and.arrow.up")
                                Text(language.text("passcode.creator.export"))
                                Spacer()
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive) {
                            store.clearAllCreator()
                        } label: {
                            HStack(spacing: 8) {
                                Spacer()
                                Image(systemName: "trash")
                                Text(language.text("passcode.creator.clear_all"))
                                Spacer()
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                } else {
                    Button(role: .destructive) {
                        store.clearLoadedTheme()
                    } label: {
                        HStack(spacing: 8) {
                            Spacer()
                            Image(systemName: "trash")
                            Text(language.text("passcode.flash.remove"))
                            Spacer()
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        }
    }

    // MARK: - Pairing (compact row + reused VPN row)

    private var pairingSection: some View {
        Section(language.text("passcode.section.pairing")) {
            HStack(spacing: 12) {
                Image(systemName: walletStore.hasPairingFile ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(walletStore.hasPairingFile ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(walletStore.hasPairingFile
                         ? language.text("passcode.pairing.paired", walletStore.pairingFileName)
                         : language.text("passcode.pairing.not_paired"))
                        .font(.subheadline.bold())
                    Text(language.text("passcode.pairing.hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !walletStore.hasPairingFile {
                    Button(walletStore.pairingPhase == .pairing
                           ? language.text("passcode.pairing.pairing")
                           : language.text("passcode.pairing.start")) {
                        walletStore.startPairing()
                    }
                    .font(.caption.bold())
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(walletStore.pairingPhase == .pairing)
                }
            }
            .padding(.vertical, 4)

            WalletVPNStatusRow(store: walletStore)
        }
    }

    // MARK: - Target pickers

    private var targetSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.badge.clock")
                        .foregroundColor(.blue)
                        .font(.headline)
                    Text(language.text("passcode.section.target"))
                        .font(.headline)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(language.text("passcode.target.caches"))
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    Picker(language.text("passcode.target.caches"), selection: $store.targetTelephonyVersion) {
                        Text("TelephonyUI-10 (iOS 18+)").tag("TelephonyUI-10")
                        Text("TelephonyUI-9 (iOS 16–17)").tag("TelephonyUI-9")
                        Text("TelephonyUI-8 (iOS 14–15)").tag("TelephonyUI-8")
                        Text("Tất cả (Universal)").tag("all")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text(language.text("passcode.target.language"))
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    Picker(language.text("passcode.target.language"), selection: $store.passcodeLanguageTarget) {
                        ForEach(PasscodeLanguageTarget.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text(language.text("passcode.target.bold"))
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    Picker(language.text("passcode.target.bold"), selection: $store.passcodeBoldTarget) {
                        ForEach(PasscodeBoldTarget.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: store.passcodeLanguageTarget == .all && store.passcodeBoldTarget == .both ? "globe" : "bolt.fill")
                        .font(.caption)
                        .foregroundColor(store.passcodeLanguageTarget == .all && store.passcodeBoldTarget == .both ? .secondary : .orange)
                        .padding(.top, 1)

                    if store.passcodeLanguageTarget == .all && store.passcodeBoldTarget == .both {
                        Text(language.text("passcode.target.hint_all"))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(language.text(
                            "passcode.target.hint_fast",
                            store.passcodeLanguageTarget.displayName,
                            store.passcodeBoldTarget.displayName
                        ))
                            .font(.caption2)
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Flash button

    @ViewBuilder
    private var flashButton: some View {
        if case .running = store.passthmFlashPhase {
            HStack(spacing: 10) {
                ProgressView()
                VStack(alignment: .leading, spacing: 4) {
                    Text(language.text("passcode.flash.running")).font(.subheadline.bold())
                    ProgressView(value: store.passthmFlashProgress)
                }
            }
            .padding(.vertical, 4)
        } else if case .done(let ok) = store.passthmFlashPhase, !ok {
            Button {
                showFlashConfirm = true
            } label: {
                HStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "arrow.clockwise")
                    Text(language.text("passcode.flash.retry"))
                    Spacer()
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(!store.canFlashPassthm)
        } else {
            Button {
                showFlashConfirm = true
            } label: {
                HStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "bolt.fill")
                    Text(language.text("passcode.flash.apply"))
                    Spacer()
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!store.canFlashPassthm)
        }
    }

    private func helpText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Lock-screen keypad preview (interactive in creator mode)
//
// From AirCard's KeypadPreviewView: in creator + poster-slice mode with a
// poster loaded, the seamless poster artwork shows behind frosted-glass
// key rings and dragging the preview repositions the poster (which
// re-slices the keys live). In apply mode (and circle/individual modes)
// it behaves exactly like the old static preview: theme artwork clipped
// into circles, or the default iOS dialer look for unstyled digits.

struct PasscodeKeypadPreviewView: View {
    @Environment(\.appLanguage) private var language
    @EnvironmentObject var store: PasscodeThemeStore
    let keys: [String: UIImage]

    @State private var dragOffsetStart: CGPoint = .zero
    @State private var isDragging: Bool = false

    private func scaledPosterDimensions(for poster: UIImage, gridW: CGFloat, gridH: CGFloat) -> (width: CGFloat, height: CGFloat) {
        let imgW = poster.size.width
        let imgH = poster.size.height
        guard imgW > 0, imgH > 0 else { return (gridW, gridH) }

        let imgAspect = imgW / imgH
        let gridAspect = gridW / gridH

        if imgAspect > gridAspect {
            let h = gridH * store.posterZoom
            return (width: h * imgAspect, height: h)
        } else {
            let w = gridW * store.posterZoom
            return (width: w, height: w / imgAspect)
        }
    }

    var body: some View {
        let scale: CGFloat = 0.68
        let btnD: CGFloat = KeypadLayout.buttonDiameter * scale
        let colW: CGFloat = KeypadLayout.colWidth * scale
        let rowH: CGFloat = KeypadLayout.rowHeight * scale
        let gridW: CGFloat = KeypadLayout.gridWidth * scale
        let gridH: CGFloat = KeypadLayout.gridHeight * scale

        let isSeamlessPoster = (store.passcodeMode == .themeCreator && store.sliceMode == .posterSlice && !store.maskToCircles && store.posterImage != nil)
        let canDragPoster = (store.passcodeMode == .themeCreator && store.sliceMode == .posterSlice && store.posterImage != nil)

        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(red: 0.07, green: 0.07, blue: 0.09))

            LinearGradient(
                colors: [Color.white.opacity(0.06), Color.clear, Color.black.opacity(0.35)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

            VStack(spacing: 12) {
                ZStack {
                    // Layer 1: Background wallpaper in Seamless Poster mode
                    if isSeamlessPoster, let poster = store.posterImage {
                        let dims = scaledPosterDimensions(for: poster, gridW: gridW, gridH: gridH)
                        Image(uiImage: poster)
                            .resizable()
                            .frame(width: dims.width, height: dims.height)
                            .position(
                                x: gridW / 2.0 + (store.posterOffset.x * scale),
                                y: gridH / 2.0 + (store.posterOffset.y * scale)
                            )
                    }

                    // Layer 2: 10 Keypad buttons
                    ForEach(KeypadLayout.allButtons) { btn in
                        let cx = CGFloat(btn.col) * colW + colW / 2
                        let cy = CGFloat(btn.row) * rowH + rowH / 2

                        keypadButton(btn: btn, btnD: btnD, scale: scale, isSeamlessPoster: isSeamlessPoster)
                            .position(x: cx, y: cy)
                    }
                }
                .frame(width: gridW, height: gridH)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if canDragPoster {
                                if !isDragging {
                                    isDragging = true
                                    dragOffsetStart = store.posterOffset
                                }
                                store.posterOffset = CGPoint(
                                    x: dragOffsetStart.x + value.translation.width / scale,
                                    y: dragOffsetStart.y + value.translation.height / scale
                                )
                                store.updatePosterSlicing()
                            }
                        }
                        .onEnded { _ in
                            isDragging = false
                            dragOffsetStart = store.posterOffset
                        }
                )

                // Drag hint pill (only shown when dragging poster is possible)
                if canDragPoster {
                    HStack(spacing: 5) {
                        Image(systemName: "hand.draw.fill")
                            .font(.system(size: 10))
                        Text(language.text("passcode.creator.zoom_hint"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                }
            }
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: canDragPoster ? 320 : 295)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func keypadButton(btn: KeypadButtonGeometry, btnD: CGFloat, scale: CGFloat, isSeamlessPoster: Bool) -> some View {
        ZStack {
            if isSeamlessPoster {
                // Seamless mode: Frosted glass touch target ring
                Circle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: btnD, height: btnD)

                Circle()
                    .stroke(Color.white.opacity(0.35), lineWidth: 1.0)
                    .frame(width: btnD, height: btnD)

                VStack(spacing: 0) {
                    Text(btn.digit)
                        .font(.system(size: 26 * scale, weight: .light))
                        .foregroundStyle(.white.opacity(0.95))
                    if !btn.letters.isEmpty {
                        Text(btn.letters)
                            .font(.system(size: 8.5 * scale, weight: .semibold))
                            .tracking(0.8 * scale)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            } else if let img = keys[btn.digit] {
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: btnD, height: btnD)

                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: btnD, height: btnD)
                    .clipShape(Circle())

                Circle()
                    .stroke(Color.white.opacity(0.25), lineWidth: 0.8)
                    .frame(width: btnD, height: btnD)
            } else {
                Circle()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: btnD, height: btnD)

                Circle()
                    .stroke(Color.white.opacity(0.25), lineWidth: 0.8)
                    .frame(width: btnD, height: btnD)

                VStack(spacing: 0) {
                    Text(btn.digit)
                        .font(.system(size: 26 * scale, weight: .light))
                        .foregroundStyle(.white)
                    if !btn.letters.isEmpty {
                        Text(btn.letters)
                            .font(.system(size: 8.5 * scale, weight: .semibold))
                            .tracking(0.8 * scale)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
        }
        .frame(width: btnD, height: btnD)
    }
}
