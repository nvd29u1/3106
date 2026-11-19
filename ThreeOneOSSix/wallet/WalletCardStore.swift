import Foundation
import UIKit
import SwiftUI
import AirliftFFI

// MARK: - WalletCardStore
//
// Wallet-only slice extracted from the upstream monolithic AppViewModel
// (pairing + network + card scan/flash). Passcode themes live in
// passcode/PasscodeThemeStore.swift (apply-only), which holds a reference
// to this store for pairing/VPN. Tendies wallpapers and the tab state
// were NOT copied. Rust log lines are routed by ThreeOneOSSixApp into
// the shared log() sink instead of a local array.

@MainActor
final class WalletCardStore: ObservableObject {

    static weak var shared: WalletCardStore? = nil

    // MARK: - Pairing
    @Published var pairingStatus: String = ""
    @Published var pairingPIN: String? = nil
    @Published var hasPairingFile: Bool = false
    @Published var pairingFileName: String = ""
    @Published var pairingPhase: PairingPhase = .idle
    @Published var documentsPlistFiles: [String] = []

    enum PairingPhase: Equatable {
        case idle, pairing
    }

    // MARK: - VPN / Network
    @Published var vpnUp: Bool = false
    @Published var wifiUp: Bool = false
    @Published var networkDetail: String = ""
    @Published var deviceIP: String = "10.7.0.1" {
        didSet {
            syncTargetHostsToRust()
        }
    }

    // MARK: - Wallet Cards
    @Published var cards: [CardItem] = []
    @Published var cardFlashPhase: FlashPhase = .idle
    @Published var cardFlashProgress: Double = 0
    @Published var cardFlashLog: [String] = []

    // MARK: - Shared
    @Published var errorMessage: String? = nil
    @Published var flashResultMessage: String? = nil
    @Published var showFlashAlert: Bool = false

    private let storageKeys = [
        "aircard.cards",
        "aircard-ios.cards",
        "airlift.cards",
        "mak5er.savedCards",
        "LumiCards.savedCards",
        "savedCards"
    ]

    init() {
        Self.shared = self
        refreshPairingFile()
        loadSavedCards()
        refreshNetworkStatus()
        scanDocumentsDirectory()
    }

    // MARK: - Documents directory scanner

    /// Scans the app's Documents folder (accessible via Files app:
    /// "On My iPhone › NVD 1506") for any pairing plists dropped by the user.
    func scanDocumentsDirectory() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: docs.path) else { return }

        // Find plists (exclude internal canonical copies)
        documentsPlistFiles = items.filter { item in
            let lower = item.lowercased()
            let isPairingExt = lower.hasSuffix(".plist") || lower.hasSuffix(".mobiledevicepairing") || lower.hasSuffix(".mobilepair")
            let isCanonical = item == "aircard_pairing.plist" || item == "airlift_pairing.plist" || item == "Info.plist"
            return isPairingExt && !isCanonical
        }.sorted()
    }

    @discardableResult
    func importPairingFile(from sourceURL: URL, originalName: String? = nil) -> Bool {
        let isSecured = sourceURL.startAccessingSecurityScopedResource()
        defer { if isSecured { sourceURL.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: sourceURL), !data.isEmpty else {
            errorMessage = AppLanguage.vietnamese.text("wallet.error.import_empty")
            return false
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let aircardURL = docs.appendingPathComponent("aircard_pairing.plist")
        let airliftURL = docs.appendingPathComponent("airlift_pairing.plist")

        do {
            try data.write(to: aircardURL, options: .atomic)
            try data.write(to: airliftURL, options: .atomic)

            if let orig = originalName, !orig.isEmpty,
               orig != "aircard_pairing.plist" && orig != "airlift_pairing.plist" {
                let origURL = docs.appendingPathComponent(orig)
                if origURL.path != sourceURL.path {
                    try? data.write(to: origURL, options: .atomic)
                }
            }

            PairingController.customPairingFilePath = aircardURL.path
            refreshPairingFile()
            let display = originalName ?? sourceURL.lastPathComponent
            pairingStatus = AppLanguage.vietnamese.text("wallet.pairing.loaded", display)
            log("wallet: đã nhập tệp ghép nối \(display) (\(data.count) byte)")
            return true
        } catch {
            errorMessage = AppLanguage.vietnamese.text("wallet.error.import_save_failed", error.localizedDescription)
            return false
        }
    }

    func selectPairingFile(filename: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let path = docs.appendingPathComponent(filename).path
        let canonical = PairingController.syncCanonicalPairingFile(from: path)
        let exists = FileManager.default.fileExists(atPath: canonical) &&
            ((try? FileManager.default.attributesOfItem(atPath: canonical)[.size] as? Int) ?? 0) > 0
        hasPairingFile = exists
        pairingFileName = exists ? (path as NSString).lastPathComponent : ""
        if exists {
            pairingStatus = AppLanguage.vietnamese.text("wallet.pairing.active", pairingFileName)
            log("wallet: đã chọn tệp ghép nối \(pairingFileName)")
        }
        scanDocumentsDirectory()
    }

    // MARK: - Pairing File

    func refreshPairingFile() {
        let path = PairingController.pairingFilePath()
        let exists = FileManager.default.fileExists(atPath: path) &&
            ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0) > 0
        hasPairingFile = exists
        pairingFileName = exists ? (path as NSString).lastPathComponent : ""
        scanDocumentsDirectory()
    }

    var pairingFileSizeString: String {
        let path = PairingController.pairingFilePath()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    func startPairing() {
        pairingPhase = .pairing
        pairingPIN = nil
        pairingStatus = AppLanguage.vietnamese.text("wallet.pairing.starting")
        errorMessage = nil

        let ctrl = PairingController.shared

        Task {
            do {
                let path = try await ctrl.startAndWait()
                await MainActor.run {
                    self.pairingPhase = .idle
                    self.refreshPairingFile()
                    self.pairingStatus = AppLanguage.vietnamese.text("wallet.pairing.success")
                    log("wallet: ghép nối xong \(path)")
                }
            } catch is CancellationError {
                self.pairingPhase = .idle
                self.pairingStatus = AppLanguage.vietnamese.text("wallet.pairing.cancelled")
            } catch {
                self.pairingPhase = .idle
                self.pairingStatus = ""
                self.errorMessage = AppLanguage.vietnamese.text("wallet.error.pairing_failed", error.localizedDescription)
            }
        }

        // Poll PairingController status every 0.2s while pairing
        Task {
            while pairingPhase == .pairing {
                try? await Task.sleep(nanoseconds: 200_000_000)
                await MainActor.run {
                    guard self.pairingPhase == .pairing else { return }
                    self.pairingStatus = ctrl.pairingStatus
                    self.pairingPIN   = ctrl.pairingPIN
                }
            }
        }
    }

    func cancelPairing() {
        PairingController.shared.softCancel()
        pairingPhase = .idle
        pairingStatus = ""
    }

    func deletePairingFile() {
        PairingController.deleteStoredPairingCredentials()
        hasPairingFile = false
        pairingFileName = ""
        pairingStatus = AppLanguage.vietnamese.text("wallet.pairing.deleted")
        log("wallet: đã xóa thông tin ghép nối")
        scanDocumentsDirectory()
    }

    // MARK: - Network

    func refreshNetworkStatus() {
        let ip = deviceIP
        let (vpn, wifi, detail) = NetworkStatus.summarize(deviceIP: ip)
        vpnUp = vpn
        wifiUp = wifi
        networkDetail = detail
        syncTargetHostsToRust()
    }

    /// Synchronizes the active device IP and candidate host addresses to the Rust core
    /// so the RSD tunnel connects over the non-loopback VPN interface rather than 127.0.0.1.
    func syncTargetHostsToRust() {
        let ip = deviceIP.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ip.isEmpty {
            ip.withCString { _ = al_set_target_host($0) }
        } else {
            _ = al_set_target_host(nil)
        }

        var candidates: [String] = []
        if !ip.isEmpty {
            candidates.append(ip)
        }
        for cand in NetworkStatus.tunnelHostCandidates() {
            if !candidates.contains(cand) {
                candidates.append(cand)
            }
        }
        let cStrings = candidates.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var ptrs = cStrings.map { UnsafePointer($0) }
        ptrs.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                _ = al_set_target_hosts(base, buf.count)
            }
        }
    }

    // MARK: - Card management & Live Scanner

    @Published var isScanningCards: Bool = false
    @Published var scanStatusText: String = ""
    private var lastObservedNetwork: PaymentNetwork? = nil

    nonisolated static let cardRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: "/(?:Cards|Passes/Cards)/([-A-Za-z0-9_+=]{20,44})(?:\\.pkpass|\\.cache|\\.pkcache|/|\\s|\"|'|\\)|,|$)"),
        try! NSRegularExpression(pattern: "/([-A-Za-z0-9_+=]{20,44})\\.(?:pkpass|cache|pkcache)"),
        try! NSRegularExpression(pattern: "(?<![A-Za-z0-9+/_-])([A-Za-z0-9+/_-]{27}=)(?![A-Za-z0-9+/_-])"),
        try! NSRegularExpression(pattern: #"PDCardFileManager: writing card\s+([A-Za-z0-9+/_-]+={0,2})(?=\s|\)|,|$)"#),
        try! NSRegularExpression(pattern: #"PDPassLibrary: wrote pass\s+([A-Za-z0-9+/_-]+={0,2})(?=\s|\)|,|$)"#),
        try! NSRegularExpression(pattern: #"VerificationCheck\.([A-Za-z0-9+/_-]+={0,2})(?=\s|\)|,|$)"#)
    ]

    func toggleCardScanning() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            if isScanningCards {
                stopCardScanning()
            } else {
                startCardScanning()
            }
        }
    }

    private static let dummyCardHashes: Set<String> = [
        "OM6NYhwXMZrAw0sRUjR62wmF4ZQ=",
        "M6nDwZrkYbFlsodLgCbvyFZQ1cc=",
        "kJL-D0rr-SZhbj2c8nK-OQ9hCMY=",
        "hwAtAmHKYwsQrJbT5cTNDsaxVME="
    ]

    func startCardScanning() {
        guard !isScanningCards else { return }
        guard hasPairingFile else {
            errorMessage = AppLanguage.vietnamese.text("wallet.error.pairing_required")
            return
        }
        syncTargetHostsToRust()

        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            isScanningCards = true
            scanStatusText = AppLanguage.vietnamese.text("wallet.scan.start_status")
        }
        log("wallet: bắt đầu quét thẻ trực tiếp…")

        let pairingPath = PairingController.pairingFilePath()

        let thread = Thread {
            var outError: UnsafeMutablePointer<CChar>? = nil

            let rc = pairingPath.withCString { pairC in
                al_syslog_stream_start(
                    pairC,
                    { _, line in
                        guard let line = line else { return }
                        let lineStr = String(cString: line)
                        let lower = lineStr.lowercased()
                        // Pre-filter on background thread to prevent flooding the main runloop
                        if lower.contains("pass") ||
                           lower.contains("card") ||
                           lower.contains("stockholm") ||
                           lower.contains("wallet") ||
                           lower.contains("nanopass") ||
                           lower.contains("verificationcheck") ||
                           lower.contains("nfcd") ||
                           lower.contains("dashboard") ||
                           lower.contains("activation") ||
                           lower.contains("setactivepaymentapplet") {
                            DispatchQueue.main.async {
                                WalletCardStore.shared?.processSyslogLine(lineStr)
                            }
                        }
                    },
                    nil,
                    &outError
                )
            }

            let errStr = outError.flatMap { String(validatingUTF8: $0) }
            if let p = outError { al_string_free(p) }

            DispatchQueue.main.async {
                guard let vm = WalletCardStore.shared else { return }
                vm.isScanningCards = false
                if rc != 0 {
                    let msg = errStr ?? "rc=\(rc)"
                    vm.scanStatusText = AppLanguage.vietnamese.text("wallet.scan.stopped_error", msg)
                    log("wallet: lỗi quét \(msg)")
                    vm.errorMessage = AppLanguage.vietnamese.text("wallet.error.scanner", msg)
                } else {
                    vm.scanStatusText = AppLanguage.vietnamese.text("wallet.scan.stopped_total", vm.cards.count)
                    log("wallet: đã dừng quét, tổng số thẻ \(vm.cards.count)")
                }
            }
        }
        thread.name = "NVD1506.WalletSyslogScanner"
        thread.stackSize = 4 * 1024 * 1024 // 4 MB stack
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stopCardScanning() {
        al_syslog_stream_stop()
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            isScanningCards = false
            scanStatusText = AppLanguage.vietnamese.text("wallet.scan.stopped_total", cards.count)
        }
        saveCards()
    }

    func processSyslogLine(_ line: String) {
        let lower = line.lowercased()
        let isWalletSubsystem = lower.contains("passd") ||
                                lower.contains("passbook") ||
                                lower.contains("passkit") ||
                                lower.contains("stockholm") ||
                                lower.contains("nanopassd") ||
                                lower.contains("wallet") ||
                                lower.contains("pdcardfilemanager") ||
                                lower.contains("pdpasslibrary") ||
                                lower.contains("verificationcheck") ||
                                lower.contains("/cards/") ||
                                lower.contains("nfcd") ||
                                lower.contains("dashboard") ||
                                lower.contains("activation")

        guard isWalletSubsystem else { return }

        let isWalletContext = lower.contains("card") ||
                              lower.contains("pass") ||
                              lower.contains("payment") ||
                              lower.contains("pkpass") ||
                              lower.contains("uniqueid") ||
                              lower.contains("identifier") ||
                              lower.contains("face") ||
                              lower.contains("cache") ||
                              lower.contains("stockholm") ||
                              lower.contains("pdcardfilemanager") ||
                              lower.contains("pdpasslibrary") ||
                              lower.contains("verificationcheck") ||
                              lower.contains("/cards/") ||
                              lower.contains("dashboard loading") ||
                              lower.contains("passids") ||
                              lower.contains("applet") ||
                              lower.contains("nfexpressmodemanager")

        guard isWalletContext else { return }

        // 1. Process activations / AIDs to track payment network & instant card ID
        let activations = WalletScanParser.activationIDs(in: line)
        for act in activations {
            if let net = act.network {
                self.lastObservedNetwork = net
            }
            if let id = act.id, let clean = CardItem.cleanCardId(id), !Self.dummyCardHashes.contains(clean) {
                self.registerDiscoveredCard(id: clean, network: act.network ?? self.lastObservedNetwork)
            }
        }

        // 2. High-confidence regex extraction
        let candidates = WalletScanParser.cardIDs(in: line)
        var foundAny = false
        for cand in candidates {
            if let clean = CardItem.cleanCardId(cand), !Self.dummyCardHashes.contains(clean) {
                foundAny = true
                self.registerDiscoveredCard(id: clean, network: self.lastObservedNetwork)
            }
        }

        // 3. Fallback token extraction if no cards matched yet
        if !foundAny && candidates.isEmpty {
            let fallbacks = WalletScanParser.fallbackCardIDs(in: line)
            for cand in fallbacks {
                if let clean = CardItem.cleanCardId(cand), !Self.dummyCardHashes.contains(clean) {
                    self.registerDiscoveredCard(id: clean, network: self.lastObservedNetwork)
                }
            }
        }
    }

    private func registerDiscoveredCard(id: String, network: PaymentNetwork? = nil) {
        if let existingIdx = self.cards.firstIndex(where: { $0.id == id }) {
            if self.cards[existingIdx].paymentNetwork == nil, let net = network {
                self.cards[existingIdx].paymentNetwork = net.displayName
                self.saveCards()
            }
            return
        }
        let newCard = CardItem(
            id: id,
            displayName: nil,
            paymentNetwork: network?.displayName,
            isSelected: true,
            isVerified: true
        )
        self.cards.append(newCard)
        self.saveCards()
        if let network {
            self.scanStatusText = AppLanguage.vietnamese.text("wallet.scan.found_card_network", id, network.displayName)
        } else {
            self.scanStatusText = AppLanguage.vietnamese.text("wallet.scan.found_card", id)
        }
        log("wallet: đã tìm thấy thẻ \(id)")
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }

    nonisolated static func cardImagePath(for cardId: String) -> URL {
        let safeId = cardId.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let cardsDir = docDir.appendingPathComponent("WalletCards", isDirectory: true)
        if !FileManager.default.fileExists(atPath: cardsDir.path) {
            try? FileManager.default.createDirectory(at: cardsDir, withIntermediateDirectories: true)
        }
        return cardsDir.appendingPathComponent("card_\(safeId).png")
    }

    func loadSavedCards() {
        var foundHashes: [String] = []
        for key in storageKeys {
            if let saved = UserDefaults.standard.stringArray(forKey: key), !saved.isEmpty {
                foundHashes = saved
                break
            }
        }
        var unique: [String] = []
        for raw in foundHashes {
            if let clean = CardItem.cleanCardId(raw), !unique.contains(clean) {
                unique.append(clean)
            }
        }
        let displayNames = UserDefaults.standard.dictionary(forKey: "aircard.cardDisplayNames") as? [String: String] ?? [:]
        let networks = UserDefaults.standard.dictionary(forKey: "aircard.cardPaymentNetworks") as? [String: String] ?? [:]

        cards = unique.filter { !Self.dummyCardHashes.contains($0) }.map { id in
            let path = Self.cardImagePath(for: id)
            let data = try? Data(contentsOf: path)
            // Downsampled thumbnail keeps RAM minimal, preventing Jetsam OOM kills
            let img = data.flatMap { ImageEngine.safeImageFromData($0, maxDimension: 512) }
            return CardItem(
                id: id,
                displayName: displayNames[id],
                paymentNetwork: networks[id],
                isSelected: true,
                isVerified: true,
                customImageData: data,
                customImage: img
            )
        }
    }

    func clearAllCards() {
        for card in cards {
            let path = Self.cardImagePath(for: card.id)
            try? FileManager.default.removeItem(at: path)
        }
        cards.removeAll()
        saveCards()
    }

    func saveCards() {
        let hashes = cards.map(\.id)
        UserDefaults.standard.set(hashes, forKey: "aircard.cards")
        UserDefaults.standard.set(hashes, forKey: "airlift.cards")
        UserDefaults.standard.set(hashes, forKey: "mak5er.savedCards")

        var displayNames: [String: String] = [:]
        var networks: [String: String] = [:]
        for card in cards {
            if let d = card.displayName, !d.isEmpty {
                displayNames[card.id] = d
            }
            if let n = card.paymentNetwork, !n.isEmpty {
                networks[card.id] = n
            }
        }
        UserDefaults.standard.set(displayNames, forKey: "aircard.cardDisplayNames")
        UserDefaults.standard.set(networks, forKey: "aircard.cardPaymentNetworks")
    }

    func updateCardName(id: String, newName: String) {
        guard let idx = cards.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        cards[idx].displayName = trimmed.isEmpty ? nil : trimmed
        saveCards()
    }

    func setSkinForAllCards(image: UIImage) {
        for card in cards where card.isSelected {
            setCardImage(for: card.id, image: image)
        }
    }

    func selectAllCards(_ selected: Bool) {
        guard !cards.isEmpty else { return }
        cards = cards.map {
            var c = $0
            c.isSelected = selected
            return c
        }
    }

    func addCardHash(_ raw: String) {
        let parts = raw.components(separatedBy: CharacterSet(charactersIn: " \n\r\t,;"))
        var added = 0
        for p in parts {
            if let clean = CardItem.cleanCardId(p),
               !cards.contains(where: { $0.id == clean }) {
                cards.append(CardItem(id: clean, displayName: nil, paymentNetwork: nil, isSelected: true, isVerified: true))
                added += 1
            }
        }
        if added > 0 { saveCards() }
    }

    func setCardSelected(id: String, selected: Bool) {
        if let idx = cards.firstIndex(where: { $0.id == id }) {
            cards[idx].isSelected = selected
        }
    }

    func deleteCard(id: String) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            cards.removeAll { $0.id == id }
        }
        saveCards()
        let path = Self.cardImagePath(for: id)
        try? FileManager.default.removeItem(at: path)
    }

    func clearCardImage(for cardId: String) {
        if let idx = cards.firstIndex(where: { $0.id == cardId }) {
            cards[idx].customImage = nil
            cards[idx].customImageData = nil
        }
        let path = Self.cardImagePath(for: cardId)
        try? FileManager.default.removeItem(at: path)
    }

    func setCardImage(for cardId: String, image: UIImage) {
        guard let idx = cards.firstIndex(where: { $0.id == cardId }) else { return }
        // Keep a lightweight thumbnail in memory for responsive UI & OOM protection
        let thumb = ImageEngine.normalizeAndDownsample(image, maxDimension: 512)
        cards[idx].customImage = thumb

        let actualId = cards[idx].id
        let path = Self.cardImagePath(for: actualId)
        // Generate full resolution PNG data asynchronously in background
        Task.detached(priority: .userInitiated) {
            let data = ImageEngine.prepareCardImage(from: image)
            if let data = data {
                try? data.write(to: path)
            }
            await MainActor.run {
                if let i = WalletCardStore.shared?.cards.firstIndex(where: { $0.id == actualId }) {
                    WalletCardStore.shared?.cards[i].customImageData = data
                }
            }
        }
    }

    // MARK: - Card Flash (via Airlift exploit)

    var canFlashCards: Bool {
        hasPairingFile &&
        cardFlashPhase != .running &&
        cards.contains { $0.isSelected && ($0.customImage != nil || $0.customImageData != nil) }
    }

    func flashCards() {
        guard canFlashCards else { return }
        let selected = cards.filter { $0.isSelected && ($0.customImage != nil || $0.customImageData != nil) }
        guard !selected.isEmpty else { return }

        syncTargetHostsToRust()

        cardFlashPhase    = .running
        cardFlashProgress = 0
        cardFlashLog.removeAll()
        errorMessage = nil

        if !vpnUp {
            cardFlashLog.append(AppLanguage.vietnamese.text("wallet.flash.vpn_notice"))
        }

        let pairingPath = PairingController.pairingFilePath()

        Task.detached { [weak self] in
            guard let self = self else { return }
            let total = Double(selected.count)
            var successCount = 0
            for (i, card) in selected.enumerated() {
                let cleanId = CardItem.cleanCardId(card.id) ?? card.id
                let safeCardId = cleanId.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")

                await MainActor.run {
                    self.cardFlashLog.append(AppLanguage.vietnamese.text("wallet.flash.flashing_card", i + 1, selected.count, String(cleanId.prefix(12))))
                    self.cardFlashProgress = Double(i) / total
                }

                // Load source image at full resolution on demand to save memory
                let sourceImg: UIImage? = {
                    if let d = card.customImageData, let img = UIImage(data: d) { return img }
                    let p = Self.cardImagePath(for: cleanId)
                    if let d = try? Data(contentsOf: p), let img = UIImage(data: d) { return img }
                    return card.customImage
                }()

                guard let sourceImg = sourceImg else {
                    await MainActor.run { self.cardFlashLog.append(AppLanguage.vietnamese.text("wallet.flash.no_image", String(cleanId.prefix(8)))) }
                    continue
                }

                // 1. Prepare multi-resolution skins
                let allSkins = ImageEngine.prepareAllCardSkins(from: sourceImg)
                guard !allSkins.isEmpty else {
                    await MainActor.run { self.cardFlashLog.append(AppLanguage.vietnamese.text("wallet.flash.skins_failed")) }
                    continue
                }

                let stageCardDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("airlift_card_\(safeCardId)_\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: stageCardDir, withIntermediateDirectories: true)

                for (name, data) in allSkins {
                    try? data.write(to: stageCardDir.appendingPathComponent(name))
                }

                let pkpassTarget = "/var/mobile/Library/Passes/Cards/\(cleanId).pkpass"

                await MainActor.run {
                    self.cardFlashLog.append(AppLanguage.vietnamese.text("wallet.flash.injecting", String(cleanId.prefix(10))))
                }

                var writeOk = false
                var errDesc: String? = nil
                await withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        var outError: UnsafeMutablePointer<CChar>? = nil
                        let rc = pairingPath.withCString { pairC in
                            stageCardDir.path.withCString { srcC in
                                pkpassTarget.withCString { tgtC in
                                    al_exploit_write_dir(pairC, srcC, tgtC, { _, msg in
                                        guard let msg = msg else { return }
                                        let line = String(cString: msg)
                                        DispatchQueue.main.async { WalletCardStore.shared?.cardFlashLog.append("    " + line) }
                                    }, nil, &outError)
                                }
                            }
                        }
                        if let p = outError {
                            errDesc = String(validatingUTF8: p)
                            al_string_free(p)
                        }
                        writeOk = (rc == 0)
                        cont.resume()
                    }
                }

                try? FileManager.default.removeItem(at: stageCardDir)

                if !writeOk {
                    await MainActor.run {
                        self.cardFlashLog.append(AppLanguage.vietnamese.text("wallet.flash.write_failed", errDesc ?? "lỗi không xác định"))
                    }
                    continue
                }

                await MainActor.run {
                    self.cardFlashLog.append(AppLanguage.vietnamese.text("wallet.flash.applied_cache"))
                }

                // 2. Invalidate cache leaves (best effort: some iOS versions don't have .cache or .pkcache folders)
                let stageInvDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("airlift_inv_\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: stageInvDir, withIntermediateDirectories: true)
                for leaf in ["FrontFace", "Preview", "PlaceHolder"] {
                    try? Data("corrupted".utf8).write(to: stageInvDir.appendingPathComponent(leaf))
                }

                for ext in [".cache", ".pkcache"] {
                    let cacheTarget = "/var/mobile/Library/Passes/Cards/\(cleanId)\(ext)"
                    await withCheckedContinuation { cont in
                        DispatchQueue.global(qos: .userInitiated).async {
                            var outError: UnsafeMutablePointer<CChar>? = nil
                            _ = pairingPath.withCString { pairC in
                                stageInvDir.path.withCString { srcC in
                                    cacheTarget.withCString { tgtC in
                                        al_exploit_write_dir(pairC, srcC, tgtC, nil, nil, &outError)
                                    }
                                }
                            }
                            if let p = outError { al_string_free(p) }
                            cont.resume()
                        }
                    }
                }
                try? FileManager.default.removeItem(at: stageInvDir)

                successCount += 1
                await MainActor.run {
                    self.cardFlashLog.append(AppLanguage.vietnamese.text("wallet.flash.cache_done"))
                    self.cardFlashProgress = Double(i + 1) / total
                }
            }

            await MainActor.run {
                if successCount > 0 {
                    self.cardFlashPhase = .done(ok: true)
                    self.cardFlashProgress = 1.0
                    self.cardFlashLog.append(AppLanguage.vietnamese.text("wallet.flash.done_success", successCount, selected.count))
                    self.flashResultMessage = AppLanguage.vietnamese.text("wallet.flash.success_alert", successCount)
                    self.showFlashAlert = true
                } else {
                    self.cardFlashPhase = .done(ok: false)
                    self.cardFlashLog.append(AppLanguage.vietnamese.text("wallet.flash.done_failed"))
                }
            }
        }
    }
}
