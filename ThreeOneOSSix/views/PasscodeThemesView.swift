import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Passcode Themes (apply .passthm only)
//
// Hub entry + section host for the passcode-theme apply flow ported from
// AirCard-iOS v1.3.2 (MIT). Theme Creator is intentionally NOT here:
// this view only loads a local .passthm file and flashes it via Airlift.
// Pairing / VPN UI is reused from the Wallet flow (WalletVPNStatusRow +
// the shared WalletCardStore) — only a compact pairing row lives here.

struct PasscodeThemesView: View {
    @Environment(\.appLanguage) private var language
    @EnvironmentObject var store: PasscodeThemeStore
    @EnvironmentObject var walletStore: WalletCardStore
    @State private var showDocumentPicker = false
    @State private var showFlashConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                pairingSection

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
                    }

                    targetSection

                    Section {
                        VStack(spacing: 12) {
                            flashButton

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
                        .listRowInsets(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
                    }

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

// MARK: - Static lock-screen keypad preview
//
// Simplified from AirCard's KeypadPreviewView: apply-only, so there is no
// poster slicing, no drag gesture, no creator state — just the 10 digit
// circles with the theme artwork (or the default iOS dialer look when a
// digit has no image).

struct PasscodeKeypadPreviewView: View {
    let keys: [String: UIImage]

    var body: some View {
        let scale: CGFloat = 0.68
        let btnD: CGFloat = KeypadLayout.buttonDiameter * scale
        let colW: CGFloat = KeypadLayout.colWidth * scale
        let rowH: CGFloat = KeypadLayout.rowHeight * scale
        let gridW: CGFloat = KeypadLayout.gridWidth * scale
        let gridH: CGFloat = KeypadLayout.gridHeight * scale

        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(red: 0.07, green: 0.07, blue: 0.09))

            LinearGradient(
                colors: [Color.white.opacity(0.06), Color.clear, Color.black.opacity(0.35)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

            ZStack {
                ForEach(KeypadLayout.allButtons) { btn in
                    let cx = CGFloat(btn.col) * colW + colW / 2
                    let cy = CGFloat(btn.row) * rowH + rowH / 2
                    keypadButton(btn: btn, btnD: btnD, scale: scale)
                        .position(x: cx, y: cy)
                }
            }
            .frame(width: gridW, height: gridH)
            .clipped()
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 295)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func keypadButton(btn: KeypadButtonGeometry, btnD: CGFloat, scale: CGFloat) -> some View {
        ZStack {
            if let img = keys[btn.digit] {
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
