import Foundation
import UIKit
import SwiftUI
import AirliftFFI

// MARK: - PasscodeThemeStore
//
// Apply + Theme Creator slice of AirCard's passcode flow
// (AppViewModel.swift flashPassthm / loadPassthm, AirCard-iOS v1.3.2
// MIT). Apply mode flashes keys read from a .passthm file the user
// imported; creator mode flashes keys built in-app from a poster photo
// or per-key photos (see "Theme Creator" below), and can export them
// as a .passthm file via PasscodeThemePackager.
//
// Pairing / VPN infrastructure is NOT duplicated here: the store holds the
// shared WalletCardStore (injected by the App) and reads its
// hasPairingFile / vpnUp, and calls its syncTargetHostsToRust().
//
// BACKUP: there is no read-back FFI in AirliftFFI (airlift.h exposes
// al_exploit_write_dir / al_exploit_inject_folder but no al_exploit_read*),
// so the stock TelephonyUI cache cannot be read back and restored.
// Fallback instead: (a) the view shows a confirmation alert before
// flashing, stating the lock-screen keypad cache is overwritten and cannot
// be undone without a stock .passthm; (b) after a successful flash the
// applied .passthm file is kept at Documents/passcode-last-applied.passthm
// so it can be re-flashed; (c) the help section states the same.

@MainActor
final class PasscodeThemeStore: ObservableObject {

    static weak var shared: PasscodeThemeStore? = nil

    /// File name of the last successfully applied theme, kept in Documents
    /// so it can be re-flashed (see the BACKUP note above).
    static let lastAppliedFileName = "passcode-last-applied.passthm"
    private static let lastAppliedNameDefaultsKey = "passcode.lastAppliedThemeName"

    let walletStore: WalletCardStore

    // MARK: - Loaded theme

    @Published var loadedTheme: PasscodeThemeInfo? = nil
    @Published var documentsThemes: [String] = []
    @Published var lastAppliedThemeName: String? = nil

    // MARK: - Theme Creator

    @Published var passcodeMode: CreatorMode = .applyTheme
    @Published var sliceMode: SliceMode = .posterSlice

    // Poster slice
    @Published var posterImage: UIImage? = nil
    @Published var posterZoom: CGFloat = 1.0
    @Published var posterOffset: CGPoint = .zero
    @Published var maskToCircles: Bool = false
    @Published var slicedKeys: [String: UIImage] = [:]

    // Individual keys
    @Published var customKeys: [String: UIImage] = [:]
    @Published var rawIndividualImages: [String: UIImage] = [:]
    // NOTE: individualOffsets / individualZooms have no UI mutating them
    // in AirCard either (no per-key zoom/offset slider or drag) — they
    // are state only, kept so updateIndividualKey stays faithful.
    @Published var individualOffsets: [String: CGPoint] = [:]
    @Published var individualZooms: [String: CGFloat] = [:]
    @Published var selectedKeyDigit: String? = nil

    @Published var exportedThemeURL: URL? = nil
    @Published var showShareSheet: Bool = false

    // MARK: - Flash state (FlashPhase is shared with the Wallet flow)

    @Published var passthmFlashPhase: FlashPhase = .idle
    @Published var passthmFlashProgress: Double = 0
    @Published var passthmFlashLog: [String] = []

    // MARK: - Targets

    @Published var targetTelephonyVersion: String = "TelephonyUI-10"
    @Published var passcodeLanguageTarget: PasscodeLanguageTarget = PasscodeThemeStore.detectedDeviceLanguage
    @Published var passcodeBoldTarget: PasscodeBoldTarget = .both

    // MARK: - Shared

    @Published var errorMessage: String? = nil
    @Published var flashResultMessage: String? = nil
    @Published var showFlashAlert: Bool = false

    static var detectedDeviceLanguage: PasscodeLanguageTarget {
        let code = Locale.preferredLanguages.first?.components(separatedBy: "-").first?.lowercased() ?? "en"
        for target in PasscodeLanguageTarget.allCases {
            if target.code == code {
                return target
            }
        }
        return .en
    }

    init(walletStore: WalletCardStore) {
        self.walletStore = walletStore
        Self.shared = self
        if FileManager.default.fileExists(atPath: Self.lastAppliedFileURL.path) {
            lastAppliedThemeName = UserDefaults.standard.string(forKey: Self.lastAppliedNameDefaultsKey)
        }
        scanDocumentsDirectory()
    }

    // MARK: - Documents directory

    /// Directory where imported .passthm copies are kept (Files app:
    /// "On My iPhone › NVD 1506 › PasscodeThemes").
    static var themesDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PasscodeThemes", isDirectory: true)
    }

    static var lastAppliedFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(lastAppliedFileName)
    }

    /// Scans the app's Documents folder for .passthm themes dropped by the user.
    func scanDocumentsDirectory() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: docs.path) else { return }
        documentsThemes = items.filter { $0.lowercased().hasSuffix(".passthm") }.sorted()
    }

    // MARK: - Passthm Load

    /// Loads a .passthm file. The file is first copied into
    /// Documents/PasscodeThemes so it survives the security-scoped / tmp
    /// lifetime of a Files-picker pick or an OpenURL inbox copy; the
    /// caller must hold security-scoped access for the duration of this
    /// (synchronous) call. Inspection itself runs off the main thread.
    func loadPassthm(url: URL) {
        let fileName = url.lastPathComponent
        let destDir = Self.themesDirectory
        let dest = destDir.appendingPathComponent(fileName)
        var sourceURL = url
        if url.path != dest.path {
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
                if (try? data.write(to: dest, options: .atomic)) != nil {
                    sourceURL = dest
                }
            }
        }

        Task.detached {
            let result = PasscodeThemeReader.inspect(url: sourceURL)
            await MainActor.run {
                if let (keys, rawData, count) = result {
                    self.loadedTheme = PasscodeThemeInfo(
                        name: sourceURL.deletingPathExtension().lastPathComponent,
                        filePath: sourceURL.path,
                        fileCount: count,
                        keysPreview: keys,
                        rawKeyData: rawData
                    )
                    self.errorMessage = nil
                    self.passthmFlashPhase = .idle
                    self.passthmFlashProgress = 0
                    self.passthmFlashLog.removeAll()
                    self.scanDocumentsDirectory()
                    log("passcode: đã tải theme \(sourceURL.lastPathComponent) (\(count) tệp, \(keys.count) phím)")
                } else {
                    self.errorMessage = AppLanguage.vietnamese.text("passcode.error.load_failed")
                }
            }
        }
    }

    func loadPassthmFromDocuments(filename: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent(filename)
        loadPassthm(url: url)
    }

    func clearLoadedTheme() {
        loadedTheme = nil
        passthmFlashPhase = .idle
        passthmFlashProgress = 0
        passthmFlashLog.removeAll()
    }

    /// Keys that preview / flash / export right now. Apply mode uses the
    /// loaded .passthm file; creator mode uses the sliced poster keys or
    /// the per-key custom images, depending on the slice mode.
    var effectiveKeys: [String: UIImage] {
        if passcodeMode == .themeCreator {
            return sliceMode == .posterSlice ? slicedKeys : customKeys
        }
        return loadedTheme?.keysPreview ?? [:]
    }

    // MARK: - Theme Creator

    func setPosterImage(_ img: UIImage) {
        posterImage = img
        posterZoom = 1.0
        posterOffset = .zero
        updatePosterSlicing()
    }

    func updatePosterSlicing() {
        guard let img = posterImage else { slicedKeys = [:]; return }
        slicedKeys = ImageEngine.slicePoster(
            image: img,
            zoom: posterZoom,
            offset: posterOffset,
            maskToCircles: maskToCircles
        )
    }

    func setIndividualKey(digit: String, image: UIImage) {
        rawIndividualImages[digit] = image
        individualOffsets[digit] = .zero
        individualZooms[digit] = 1.0
        selectedKeyDigit = digit
        updateIndividualKey(digit: digit)
    }

    func updateIndividualKey(digit: String) {
        guard let raw = rawIndividualImages[digit] else { return }
        let offset = individualOffsets[digit] ?? .zero
        let zoom   = individualZooms[digit] ?? 1.0
        if let cropped = ImageEngine.cropToCircle(
            image: raw,
            targetSize: CGSize(width: 225, height: 225),
            circleDiameter: 222.0,
            zoom: zoom,
            offset: offset
        ) {
            customKeys[digit] = cropped
        }
    }

    func clearIndividualKey(digit: String) {
        customKeys.removeValue(forKey: digit)
        rawIndividualImages.removeValue(forKey: digit)
        individualOffsets.removeValue(forKey: digit)
        individualZooms.removeValue(forKey: digit)
        if selectedKeyDigit == digit { selectedKeyDigit = nil }
    }

    func clearAllCreator() {
        posterImage = nil
        posterZoom = 1.0
        posterOffset = .zero
        slicedKeys.removeAll()
        customKeys.removeAll()
        rawIndividualImages.removeAll()
        individualOffsets.removeAll()
        individualZooms.removeAll()
        selectedKeyDigit = nil
    }

    /// Exports the creator keys as a .passthm file into tmp/ and opens
    /// the share sheet for it. No pairing/VPN needed for export. The
    /// file stays in tmp/ only (AirCard behavior) — it is NOT copied to
    /// Documents automatically.
    func exportPassthm() -> URL? {
        let keys = effectiveKeys
        guard !keys.isEmpty else {
            errorMessage = AppLanguage.vietnamese.text("passcode.creator.export_no_keys")
            return nil
        }
        do {
            let zipData = try PasscodeThemePackager.buildPassthm(
                keys: keys,
                telephonyVersion: targetTelephonyVersion,
                language: passcodeLanguageTarget,
                bold: passcodeBoldTarget
            )
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("NVD1506_Custom_\(Int(Date().timeIntervalSince1970)).passthm")
            try zipData.write(to: tempURL)
            self.exportedThemeURL = tempURL
            self.showShareSheet = true
            return tempURL
        } catch {
            errorMessage = AppLanguage.vietnamese.text("passcode.creator.export_failed", error.localizedDescription)
            return nil
        }
    }

    func resetPosterPosition() {
        posterZoom = 1.0
        posterOffset = .zero
        updatePosterSlicing()
    }

    /// Copies the loaded theme's preview images into the creator as
    /// per-key images (merges per digit — pre-existing custom keys for
    /// other digits are kept). Uses the 512px-downsampled preview
    /// UIImages, not full-res data; only one image per digit survives
    /// (the reader keeps the first per digit; *# never survive).
    func adoptThemeIntoCreator() {
        guard let theme = loadedTheme else { return }
        for (digit, img) in theme.keysPreview {
            customKeys[digit] = img
            rawIndividualImages[digit] = img
            individualOffsets[digit] = .zero
            individualZooms[digit] = 1.0
        }
        selectedKeyDigit = nil
        sliceMode = .individualKeys
        passcodeMode = .themeCreator
    }

    // MARK: - Passthm Flash

    var canFlashPassthm: Bool {
        guard walletStore.hasPairingFile, passthmFlashPhase != .running else { return false }
        switch passcodeMode {
        case .applyTheme:
            return loadedTheme != nil && !(loadedTheme?.keysPreview.isEmpty ?? true)
        case .themeCreator:
            return !effectiveKeys.isEmpty
        }
    }

    func flashPassthm() {
        guard canFlashPassthm else { return }

        let isCreator = (passcodeMode == .themeCreator)
        let keys: [String: UIImage]
        let rawKeys: [String: Data]
        let themeFilePath: String
        let themeName: String

        if isCreator {
            keys = effectiveKeys
            // CRITICAL: Never use rawKeyData from a previously loaded zip in creator mode!
            rawKeys = [:]
            // Creator keys have no source .passthm file, so the
            // last-applied save below no-ops (empty path reads nothing).
            themeFilePath = ""
            themeName = ""
        } else if let theme = loadedTheme {
            keys = theme.keysPreview
            rawKeys = theme.rawKeyData
            themeFilePath = theme.filePath
            themeName = theme.name
        } else {
            return
        }

        guard !keys.isEmpty else {
            errorMessage = AppLanguage.vietnamese.text("passcode.flash.no_keys")
            return
        }

        passthmFlashPhase = .running
        passthmFlashProgress = 0
        passthmFlashLog.removeAll()
        errorMessage = nil
        walletStore.syncTargetHostsToRust()

        if !walletStore.vpnUp {
            passthmFlashLog.append(AppLanguage.vietnamese.text("passcode.flash.vpn_notice"))
        }

        let pairingPath = PairingController.pairingFilePath()
        let targetVer = targetTelephonyVersion
        let targetLang = passcodeLanguageTarget
        let targetBold = passcodeBoldTarget
        let detected = Self.detectedDeviceLanguage.code

        Task.detached { [weak self] in
            guard let self = self else { return }

            let stageThemeDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("airlift_passthm_\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: stageThemeDir, withIntermediateDirectories: true)

            let langs: [String]
            if targetLang == .all {
                langs = KeypadLocales.all
            } else {
                var l = [targetLang.code]
                if targetLang.code != "other" {
                    l.append("other")
                }
                if targetLang.code != detected && detected != "other" && !l.contains(detected) {
                    l.append(detected)
                }
                langs = l
            }
            let boldSuffixes: [String]
            switch targetBold {
            case .both: boldSuffixes = ["", "-bold"]
            case .boldOnly: boldSuffixes = ["-bold"]
            case .regularOnly: boldSuffixes = [""]
            }

            // Stage keypad images with all configured language & weight variants
            for (digit, image) in keys {
                let imgData: Data
                if let raw = rawKeys[digit] {
                    imgData = raw
                } else if let png = image.pngData() {
                    imgData = png
                } else {
                    continue
                }
                let stdSubtext = KeypadLayout.subtexts[digit] ?? ""

                for lang in langs {
                    for bld in boldSuffixes {
                        if digit == "0" {
                            // Blank variant: lang-0---white[-bold].png
                            try? imgData.write(to: stageThemeDir.appendingPathComponent("\(lang)-0---white\(bld).png"))
                            // Plus variant: lang-0-+--white[-bold].png
                            try? imgData.write(to: stageThemeDir.appendingPathComponent("\(lang)-0-+--white\(bld).png"))
                        } else if digit == "1" {
                            // Blank variant: lang-1---white[-bold].png
                            try? imgData.write(to: stageThemeDir.appendingPathComponent("\(lang)-1---white\(bld).png"))
                        } else {
                            // 1. Blank subtext
                            try? imgData.write(to: stageThemeDir.appendingPathComponent("\(lang)-\(digit)---white\(bld).png"))

                            // 2. Standard Latin subtext
                            if !stdSubtext.isEmpty {
                                try? imgData.write(to: stageThemeDir.appendingPathComponent("\(lang)-\(digit)-\(stdSubtext)--white\(bld).png"))
                                let noSpace = stdSubtext.replacingOccurrences(of: " ", with: "")
                                if noSpace != stdSubtext {
                                    try? imgData.write(to: stageThemeDir.appendingPathComponent("\(lang)-\(digit)-\(noSpace)--white\(bld).png"))
                                }
                            }

                            // 3. Cyrillic subtexts
                            if (lang == "ru" || targetLang == .all), let ruSub = KeypadLocales.cyrillicRU[digit] {
                                try? imgData.write(to: stageThemeDir.appendingPathComponent("\(lang)-\(digit)-\(ruSub)--white\(bld).png"))
                            }
                            if (lang == "uk" || targetLang == .all), let ukSub = KeypadLocales.cyrillicUK[digit] {
                                try? imgData.write(to: stageThemeDir.appendingPathComponent("\(lang)-\(digit)-\(ukSub)--white\(bld).png"))
                            }
                        }
                    }
                }
            }

            // iOS TelephonyUI @3x high-res indicator marker
            try? Data().write(to: stageThemeDir.appendingPathComponent("_big"))

            await MainActor.run {
                self.passthmFlashLog.append(AppLanguage.vietnamese.text(
                    "passcode.flash.staged",
                    targetVer,
                    langs.joined(separator: ", ").uppercased(),
                    targetBold.displayName
                ))
                self.passthmFlashProgress = 0.2
            }

            let targetDirs: [String]
            if targetVer == "all" {
                targetDirs = [
                    "/var/mobile/Library/Caches/TelephonyUI-10",
                    "/var/mobile/Library/Caches/TelephonyUI-9",
                    "/var/mobile/Library/Caches/TelephonyUI-8"
                ]
            } else {
                targetDirs = [
                    "/var/mobile/Library/Caches/\(targetVer)"
                ]
            }

            var allOk = true
            var lastErr: String? = nil

            for (idx, targetPath) in targetDirs.enumerated() {
                let targetName = (targetPath as NSString).lastPathComponent
                await MainActor.run {
                    self.passthmFlashLog.append(AppLanguage.vietnamese.text("passcode.flash.writing", targetName))
                }

                var stepOk = false
                await withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        var outError: UnsafeMutablePointer<CChar>? = nil
                        let rc = pairingPath.withCString { pairC in
                            stageThemeDir.path.withCString { srcC in
                                targetPath.withCString { tgtC in
                                    al_exploit_write_dir(pairC, srcC, tgtC, { _, msg in
                                        guard let msg = msg else { return }
                                        let line = String(cString: msg)
                                        DispatchQueue.main.async { PasscodeThemeStore.shared?.passthmFlashLog.append("    " + line) }
                                    }, nil, &outError)
                                }
                            }
                        }
                        if let p = outError {
                            lastErr = String(validatingUTF8: p)
                            al_string_free(p)
                        }
                        stepOk = (rc == 0)
                        cont.resume()
                    }
                }

                if !stepOk {
                    allOk = false
                    await MainActor.run {
                        self.passthmFlashLog.append(AppLanguage.vietnamese.text("passcode.flash.write_failed", targetName, lastErr ?? "lỗi không xác định"))
                    }
                } else {
                    await MainActor.run {
                        self.passthmFlashLog.append(AppLanguage.vietnamese.text("passcode.flash.injected", targetName))
                    }
                }

                await MainActor.run {
                    self.passthmFlashProgress = 0.2 + Double(idx + 1) * 0.25
                }
            }

            try? FileManager.default.removeItem(at: stageThemeDir)

            // Keep the applied theme so it can be re-flashed (no stock
            // backup exists — see the BACKUP note at the top of this file).
            var savedLastApplied = false
            if allOk, let data = try? Data(contentsOf: URL(fileURLWithPath: themeFilePath)), !data.isEmpty {
                if (try? data.write(to: await Self.lastAppliedFileURL, options: .atomic)) != nil {
                    savedLastApplied = true
                }
            }
            let didSaveLastApplied = savedLastApplied

            await MainActor.run {
                if allOk {
                    self.passthmFlashProgress = 1.0
                    self.passthmFlashPhase = .done(ok: true)
                    self.passthmFlashLog.append(AppLanguage.vietnamese.text("passcode.flash.done_success"))
                    if didSaveLastApplied {
                        self.lastAppliedThemeName = themeName
                        UserDefaults.standard.set(themeName, forKey: Self.lastAppliedNameDefaultsKey)
                        self.scanDocumentsDirectory()
                    }
                    self.flashResultMessage = AppLanguage.vietnamese.text("passcode.flash.success_alert")
                    self.showFlashAlert = true
                    if isCreator {
                        log("passcode: đã áp theme tự tạo")
                    } else {
                        log("passcode: đã áp theme \(themeName)")
                    }
                } else {
                    self.passthmFlashPhase = .done(ok: false)
                    self.passthmFlashLog.append(AppLanguage.vietnamese.text("passcode.flash.done_failed"))
                }
            }
        }
    }
}
