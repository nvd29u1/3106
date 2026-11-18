import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Shared helpers

func logLineColor(_ line: String) -> Color {
    if line.contains("✅") || line.contains("🎉") { return .green }
    if line.contains("❌") { return .red }
    if line.contains("⚠️") { return .orange }
    return .secondary
}

// MARK: - Compact Scrollable Log View with 1-Click Copy

struct CompactLogView: View {
    @Environment(\.appLanguage) private var language
    let title: String
    let lines: [String]
    var onClear: (() -> Void)? = nil
    @State private var copied: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if let onClear = onClear, !lines.isEmpty {
                    Button(action: onClear) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .padding(.trailing, 6)
                }
                Button {
                    UIPasteboard.general.string = lines.joined(separator: "\n")
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        copied = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        var t2 = Transaction()
                        t2.disablesAnimations = true
                        withTransaction(t2) {
                            copied = false
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .bold))
                        Text(copied ? language.text("wallet.common.copied") : language.text("wallet.common.copy"))
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(copied ? .green : .blue)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color(uiColor: .tertiarySystemFill))
                    .clipShape(Capsule())
                }
                .buttonStyle(.borderless)
                .transaction { $0.animation = nil }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(logLineColor(line))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 180)
                .background(Color(uiColor: .tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                )
                .onChange(of: lines.count) { _, _ in
                    if !lines.isEmpty {
                        proxy.scrollTo(lines.count - 1, anchor: .bottom)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Native Document Picker

struct DocumentPickerView: UIViewControllerRepresentable {
    let allowedContentTypes: [UTType]
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: allowedContentTypes, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPickerView

        init(_ parent: DocumentPickerView) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            let shouldStop = url.startAccessingSecurityScopedResource()
            defer {
                if shouldStop { url.stopAccessingSecurityScopedResource() }
            }
            parent.onPick(url)
            parent.dismiss()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }
    }
}

// MARK: - VPN / Network Status Row

struct WalletVPNStatusRow: View {
    @Environment(\.appLanguage) private var language
    @ObservedObject var store: WalletCardStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: store.vpnUp
                      ? "checkmark.shield.fill"
                      : "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(store.vpnUp ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.vpnUp ? language.text("wallet.vpn.active") : language.text("wallet.vpn.not_detected"))
                        .font(.subheadline.bold())
                    Text(store.vpnUp
                         ? language.text("wallet.vpn.ready")
                         : language.text("wallet.vpn.connect_before"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !store.vpnUp {
                VStack(alignment: .leading, spacing: 6) {
                    Text(language.text("wallet.vpn.setup_title"))
                        .font(.caption.bold())
                    ForEach([
                        language.text("wallet.vpn.step1"),
                        language.text("wallet.vpn.step2")
                    ], id: \.self) { step in
                        Text(step)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Link(language.text("wallet.vpn.launch"),
                         destination: URL(string: "localdevvpn://")!)
                        .font(.caption.bold())
                }
                .padding(10)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            HStack(spacing: 8) {
                Text(language.text("wallet.vpn.device_ip"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("10.7.0.1", text: $store.deviceIP)
                    .font(.caption.monospaced())
                    .keyboardType(.decimalPad)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(uiColor: .tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(width: 120)
                Spacer()
                Button {
                    store.refreshNetworkStatus()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.bold())
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            if !store.networkDetail.isEmpty {
                Text(store.networkDetail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Apple Wallet Card View Component

struct WalletCardView: View {
    @Environment(\.appLanguage) private var language
    let card: CardItem
    let cardIndex: Int
    let onToggleSelected: (Bool) -> Void
    let onPickImage: () -> Void
    let onClearImage: () -> Void
    let onDelete: () -> Void
    var onRename: ((String) -> Void)? = nil

    @State private var copied = false
    @State private var isRenaming = false
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 12) {
            // Realistic Apple Wallet Card Mockup (1.586 : 1 aspect ratio)
            GeometryReader { geo in
                let width = geo.size.width
                let height = width / 1.586

                ZStack {
                    if let img = card.uiImage {
                        // Custom skin applied
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: width, height: height)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                            // Subtle Apple Wallet Card Gloss Overlay
                            LinearGradient(
                                colors: [.white.opacity(0.18), .clear, .black.opacity(0.12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                            // Top Right Remove Button
                            Button(action: onClearImage) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.white.opacity(0.95))
                                    .background(Circle().fill(Color.black.opacity(0.55)))
                            }
                            .buttonStyle(.plain)
                            .padding(10)
                        }
                    } else {
                        // Empty / Placeholder Card Mockup
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(uiColor: .secondarySystemBackground),
                                            Color(uiColor: .tertiarySystemBackground)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )

                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(
                                    Color.secondary.opacity(0.25),
                                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                                )

                            // Contactless & Chip icons
                            VStack(alignment: .leading) {
                                HStack {
                                    Image(systemName: "wave.3.right")
                                        .font(.system(size: 15))
                                        .foregroundStyle(.secondary.opacity(0.6))
                                    Spacer()
                                    Image(systemName: "creditcard")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.secondary.opacity(0.5))
                                }
                                .padding(14)
                                Spacer()
                            }

                            // Center Action Callout
                            VStack(spacing: 8) {
                                Image(systemName: "photo.badge.plus")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.blue)

                                Text(language.text("wallet.card.assign_skin"))
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.primary)

                                Text(language.text("wallet.card.tap_choose_photo"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(width: width, height: height)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                .contentShape(Rectangle())
                .onTapGesture { onPickImage() }
            }
            .aspectRatio(1.586, contentMode: .fit)

            // Card Controls & Meta Bar
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { card.isSelected },
                    set: { onToggleSelected($0) }
                ))
                .labelsHidden()

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(card.title)
                            .font(.system(size: 13, weight: .bold))
                            .lineLimit(1)

                        if let network = card.paymentNetwork {
                            Text(network)
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.12))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        }
                    }

                    // Monospace Hash Pill with Copy Button
                    HStack(spacing: 4) {
                        Text(card.id.prefix(8) + "…" + card.id.suffix(6))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Button {
                            UIPasteboard.general.string = card.id
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        } label: {
                            Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundStyle(copied ? .green : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                Button {
                    renameText = card.displayName ?? ""
                    isRenaming = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if card.uiImage != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 14))
                }

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(card.isSelected ? Color.blue.opacity(0.35) : Color.clear, lineWidth: 1.5)
        )
        .alert(language.text("wallet.card.rename_title"), isPresented: $isRenaming) {
            TextField(language.text("wallet.card.rename_placeholder"), text: $renameText)
            Button(language.text("wallet.common.save")) {
                onRename?(renameText)
            }
            Button(language.text("wallet.common.cancel"), role: .cancel) {}
        } message: {
            Text(language.text("wallet.card.rename_message"))
        }
    }
}

// MARK: - Wallet Cards Tab

struct WalletCardsView: View {
    @Environment(\.appLanguage) private var language
    @EnvironmentObject var store: WalletCardStore
    @State private var newHashText = ""
    @State private var showAddSheet = false
    enum ActiveCardPicker: Identifiable {
        case singleCard(String)
        case bulkAll
        var id: String {
            switch self {
            case .singleCard(let id): return id
            case .bulkAll: return "bulk_all"
            }
        }
    }
    @State private var activePicker: ActiveCardPicker? = nil
    @State private var showSourceDialog: Bool = false
    @State private var isPhotosPickerPresented: Bool = false
    @State private var isDocumentPickerPresented: Bool = false
    @State private var showPairingFilePicker = false
    @State private var showDeletePairingConfirm = false
    private struct CropRequest: Identifiable {
        let id = UUID()
        let image: UIImage
        let target: ActiveCardPicker
    }
    @State private var pendingCrop: CropRequest?
    @State private var cropRequest: CropRequest?
    @State private var photoLoadFailed = false
    @State private var pendingLoadError = false
    @State private var cropAccepted = false

    private var isIOS27OrNewer: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    private var isPotentiallyPatchedOS: Bool {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        if os.majorVersion > 27 { return true }
        if os.majorVersion == 27 && os.minorVersion >= 3 { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    setupSection
                    scannerBanner

                    if store.cards.isEmpty {
                        walletEmptyState
                            .padding(.top, 8)
                    } else {
                        cardsList
                    }
                }
                .padding(.vertical)
                .transaction { $0.animation = nil }
            }
            .transaction { $0.animation = nil }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 60)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(language.text("wallet.title", store.cards.count))
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        store.toggleCardScanning()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: store.isScanningCards ? "stop.circle.fill" : "wave.3.left.circle")
                            Text(store.isScanningCards ? language.text("wallet.stop_scan") : language.text("wallet.scan"))
                        }
                        .font(.subheadline.bold())
                        .foregroundStyle(store.isScanningCards ? .red : .blue)
                    }
                    .transaction { $0.animation = nil }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showAddSheet = true
                        } label: {
                            Label(language.text("wallet.menu.add_manually"), systemImage: "plus")
                        }
                        if !store.cards.isEmpty {
                            Button {
                                activePicker = .bulkAll
                                showSourceDialog = true
                            } label: {
                                Label(language.text("wallet.menu.set_skin_all"), systemImage: "photo.on.rectangle.angled")
                            }

                            Divider()

                            Button {
                                store.selectAllCards(true)
                            } label: {
                                Label(language.text("wallet.menu.select_all"), systemImage: "checkmark.circle")
                            }

                            Button {
                                store.selectAllCards(false)
                            } label: {
                                Label(language.text("wallet.menu.deselect_all"), systemImage: "circle")
                            }

                            Divider()

                            Button(role: .destructive) {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                    store.clearAllCards()
                                }
                            } label: {
                                Label(language.text("wallet.menu.clear_all"), systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    flashButton
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddCardSheet(hashText: $newHashText) {
                    store.addCardHash(newHashText)
                    newHashText = ""
                    showAddSheet = false
                }
            }
            .sheet(isPresented: $showPairingFilePicker) {
                DocumentPickerView(allowedContentTypes: [
                    .propertyList,
                    UTType(filenameExtension: "mobiledevicepairing") ?? .data,
                    UTType(filenameExtension: "mobilepair") ?? .data
                ]) { url in
                    _ = store.importPairingFile(from: url, originalName: url.lastPathComponent)
                }
            }
            .confirmationDialog(language.text("wallet.source.title"), isPresented: $showSourceDialog, titleVisibility: .visible) {
                Button {
                    isPhotosPickerPresented = true
                } label: {
                    Label(language.text("wallet.source.photo_library"), systemImage: "photo.on.rectangle")
                }
                Button {
                    isDocumentPickerPresented = true
                } label: {
                    Label(language.text("wallet.source.files"), systemImage: "folder")
                }
                Button(language.text("wallet.common.cancel"), role: .cancel) {
                    activePicker = nil
                }
            }
            .sheet(isPresented: $isPhotosPickerPresented, onDismiss: { activePicker = nil }) {
                if let target = activePicker {
                    CardPhotoPicker { image in
                        assignImage(image, to: target)
                    }
                }
            }
            .sheet(isPresented: $isDocumentPickerPresented, onDismiss: presentPendingCrop) {
                DocumentPickerView(allowedContentTypes: [
                    .image, .png, .jpeg, .heic,
                    UTType(filenameExtension: "webp") ?? .image,
                    UTType(filenameExtension: "tiff") ?? .image
                ]) { url in
                    guard let picker = activePicker else { return }
                    if let data = try? Data(contentsOf: url),
                       let image = ImageEngine.safeImageFromData(data, maxDimension: 2560) {
                        pendingCrop = CropRequest(image: image, target: picker)
                    } else {
                        pendingLoadError = true
                    }
                    activePicker = nil
                }
            }
            .sheet(item: $cropRequest, onDismiss: {
                if !cropAccepted { isDocumentPickerPresented = true }
            }) { request in
                CardPhotoCropView(image: request.image) { croppedImage in
                    cropAccepted = true
                    assignImage(croppedImage, to: request.target)
                    activePicker = nil
                }
            }
            .alert(language.text("wallet.error.load_photo_title"), isPresented: $photoLoadFailed) {
                Button(language.text("wallet.common.ok"), role: .cancel) { }
            } message: {
                Text(language.text("wallet.error.load_photo_message"))
            }
            .alert(language.text("wallet.notice_title"), isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )) {
                Button(language.text("wallet.common.ok")) { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "")
            }
            .alert(language.text("wallet.flash.success_title"), isPresented: $store.showFlashAlert) {
                Button(language.text("wallet.common.ok")) {}
            } message: {
                Text(store.flashResultMessage ?? "")
            }
            .confirmationDialog(
                language.text("wallet.pairing.delete_title"),
                isPresented: $showDeletePairingConfirm,
                titleVisibility: .visible
            ) {
                Button(language.text("wallet.pairing.delete_confirm"), role: .destructive) { store.deletePairingFile() }
                Button(language.text("wallet.common.cancel"), role: .cancel) {}
            } message: {
                Text(language.text("wallet.pairing.delete_message"))
            }
        }
    }

    private func assignImage(_ image: UIImage, to target: ActiveCardPicker) {
        switch target {
        case .singleCard(let cardId):
            store.setCardImage(for: cardId, image: image)
        case .bulkAll:
            store.setSkinForAllCards(image: image)
        }
    }

    private func presentPendingCrop() {
        guard !isPhotosPickerPresented, !isDocumentPickerPresented else { return }
        if let request = pendingCrop {
            pendingCrop = nil
            cropAccepted = false
            activePicker = request.target
            cropRequest = request
        } else if pendingLoadError {
            pendingLoadError = false
            photoLoadFailed = true
        }
    }

    // MARK: - Setup: pairing file + VPN + troubleshooting

    @ViewBuilder
    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(language.text("wallet.setup.title"))
                .font(.headline)

            // Pairing status
            HStack(spacing: 10) {
                if store.hasPairingFile {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(language.text("wallet.pairing.ready"))
                            .font(.subheadline.bold())
                        Text("\(store.pairingFileName) (\(store.pairingFileSizeString))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(language.text("wallet.pairing.not_paired"))
                            .font(.subheadline.bold())
                        Text(language.text("wallet.pairing.not_paired_hint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if store.hasPairingFile {
                    Button(role: .destructive) {
                        showDeletePairingConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                }
            }

            if !store.pairingStatus.isEmpty {
                Text(store.pairingStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let pin = store.pairingPIN {
                VStack(alignment: .leading, spacing: 4) {
                    Text(pin)
                        .font(.largeTitle.bold().monospaced())
                    Text(language.text("wallet.pairing.pin_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            // Import pairing file
            Button {
                showPairingFilePicker = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down.fill")
                        .foregroundStyle(.blue)
                    Text(language.text("wallet.pairing.import"))
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Text(language.text("wallet.pairing.import_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)

            if !store.documentsPlistFiles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(language.text("wallet.pairing.discovered"))
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)

                    ForEach(store.documentsPlistFiles, id: \.self) { filename in
                        HStack {
                            Image(systemName: "doc.text.fill")
                                .foregroundStyle(.blue)
                            Text(filename)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button(language.text("wallet.pairing.use")) {
                                store.selectPairingFile(filename: filename)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // On-device pairing (iOS 27+ only — needs Developer Mode pairing)
            if isIOS27OrNewer {
                VStack(alignment: .leading, spacing: 8) {
                    Text(language.text("wallet.pairing.pair_on_device"))
                        .font(.subheadline.bold())
                    if store.pairingPhase == .pairing {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.85)
                            Text(store.pairingStatus.isEmpty ? language.text("wallet.pairing.starting") : store.pairingStatus)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(language.text("wallet.pairing.cancel")) {
                                store.cancelPairing()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    } else {
                        Button(language.text("wallet.pairing.start")) {
                            store.startPairing()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            WalletVPNStatusRow(store: store)

            Divider()

            // Troubleshooting / preconditions
            VStack(alignment: .leading, spacing: 6) {
                Text(language.text("wallet.help.title"))
                    .font(.subheadline.bold())
                ForEach([
                    language.text("wallet.help.vpn"),
                    language.text("wallet.help.books"),
                    language.text("wallet.help.ios"),
                    language.text("wallet.help.refresh"),
                    language.text("wallet.help.applecard")
                ], id: \.self) { line in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                        Text(line)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if isPotentiallyPatchedOS {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(language.text("wallet.help.patched"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    @ViewBuilder
    private var scannerBanner: some View {
        if store.isScanningCards || !store.scanStatusText.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if store.isScanningCards {
                        ProgressView().scaleEffect(0.85)
                        Text(language.text("wallet.scanning_active"))
                            .font(.subheadline.bold())
                            .foregroundStyle(.blue)
                    } else {
                        Image(systemName: "wave.3.left.circle")
                            .foregroundStyle(.secondary)
                        Text(language.text("wallet.scanner_status"))
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.isScanningCards {
                        Button(language.text("wallet.stop")) {
                            store.stopCardScanning()
                        }
                        .font(.caption.bold())
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.small)
                    }
                }
                Text(store.scanStatusText)
                    .font(.caption)
                    .foregroundStyle(store.scanStatusText.contains("Đã dừng") || store.scanStatusText.contains("Lỗi") ? .orange : .secondary)
            }
            .padding(14)
            .background(store.isScanningCards ? Color.blue.opacity(0.12) : Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
            .transaction { $0.animation = nil }
        }
    }

    @ViewBuilder
    private var cardsList: some View {
        VStack(spacing: 16) {
            ForEach(store.cards, id: \.id) { card in
                let cardIndex = store.cards.firstIndex(where: { $0.id == card.id }) ?? 0
                WalletCardView(
                    card: card,
                    cardIndex: cardIndex,
                    onToggleSelected: { isSelected in
                        store.setCardSelected(id: card.id, selected: isSelected)
                    },
                    onPickImage: {
                        activePicker = .singleCard(card.id)
                        showSourceDialog = true
                    },
                    onClearImage: { store.clearCardImage(for: card.id) },
                    onDelete: {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        store.deleteCard(id: card.id)
                    },
                    onRename: { newName in
                        store.updateCardName(id: card.id, newName: newName)
                    }
                )
                .id(card.id)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.95).combined(with: .opacity),
                    removal: .scale(scale: 0.85).combined(with: .opacity)
                ))
            }

            if !store.cardFlashLog.isEmpty {
                CompactLogView(
                    title: language.text("wallet.flash_log", store.cardFlashLog.count),
                    lines: store.cardFlashLog,
                    onClear: { store.cardFlashLog.removeAll() }
                )
                .padding(.top, 8)
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private var flashButton: some View {
        Button {
            store.flashCards()
        } label: {
            HStack(spacing: 6) {
                if case .running = store.cardFlashPhase {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.75)
                    Text(language.text("wallet.flashing"))
                        .font(.system(size: 13, weight: .semibold))
                } else if case .done(let ok) = store.cardFlashPhase, !ok {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                    Text(language.text("wallet.retry"))
                        .font(.system(size: 13, weight: .semibold))
                } else {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text(language.text("wallet.flash"))
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .padding(.horizontal, 4)
            .frame(minHeight: 28)
        }
        .buttonStyle(.borderedProminent)
        .tint({
            if case .done(let ok) = store.cardFlashPhase, !ok {
                return Color.orange
            }
            return Color.blue
        }())
        .disabled(!store.canFlashCards || store.cardFlashPhase == .running)
        .animation(.easeInOut(duration: 0.2), value: store.cardFlashPhase)
    }

    private var walletEmptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "creditcard.viewfinder")
                .font(.system(size: 56))
                .foregroundStyle(.blue.opacity(0.8))

            Text(language.text("wallet.empty.title"))
                .font(.title3.bold())

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Text("1.")
                        .bold()
                        .foregroundStyle(.blue)
                    Text(language.text("wallet.empty.step1"))
                }
                HStack(alignment: .top, spacing: 10) {
                    Text("2.")
                        .bold()
                        .foregroundStyle(.blue)
                    Text(language.text("wallet.empty.step2"))
                }
                HStack(alignment: .top, spacing: 10) {
                    Text("3.")
                        .bold()
                        .foregroundStyle(.blue)
                    Text(language.text("wallet.empty.step3"))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Button {
                    store.toggleCardScanning()
                } label: {
                    HStack(spacing: 6) {
                        Spacer()
                        Image(systemName: store.isScanningCards ? "stop.circle.fill" : "wave.3.left.circle")
                        Text(store.isScanningCards ? language.text("wallet.stop_scan") : language.text("wallet.scan"))
                        Spacer()
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                }
                .buttonStyle(.borderedProminent)
                .tint(store.isScanningCards ? .red : .blue)
                .transaction { $0.animation = nil }

                Button {
                    showAddSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Spacer()
                        Image(systemName: "plus")
                        Text(language.text("wallet.empty.add_manually"))
                        Spacer()
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                }
                .buttonStyle(.bordered)
                .transaction { $0.animation = nil }
            }
            .padding(.horizontal, 24)
            .transaction { $0.animation = nil }
        }
        .frame(maxWidth: .infinity)
        .transaction { $0.animation = nil }
    }
}

// MARK: - Add Card Sheet

struct AddCardSheet: View {
    @Environment(\.appLanguage) private var language
    @Binding var hashText: String
    let onAdd: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(language.text("wallet.add.hash_section")) {
                    TextField(language.text("wallet.add.hash_placeholder"), text: $hashText, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(4...8)
                }
                Section {
                    Text(language.text("wallet.add.hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(language.text("wallet.add.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(language.text("wallet.common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(language.text("wallet.common.add")) { onAdd() }
                        .disabled(hashText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .bold()
                }
            }
        }
    }
}
