import Foundation
import UIKit
import AirliftFFI

// MARK: - Passcode theme (.passthm) — apply-only slice
//
// Ported from AirCard-iOS v1.3.2 (Mak5er/AirCard-iOS, MIT), Models.swift.
// Only the parts needed to LOAD and APPLY a local .passthm file are kept:
// theme info, language/bold targets, keypad locales + layout, and the
// .passthm reader. NOT ported: Theme Creator (per-key editor,
// exportPassthm, slicePoster/cropToCircle, PasscodeThemePackager),
// PosterBoard wallpapers, Wallet (already in the app), theme store.
//
// A .passthm file is a plain ZIP (STORED entries, no manifest). Entry
// names look like "<TelephonyUI-N>/<lang>-<digit>-<subtext>--white[-bold].png"
// plus one empty marker file "<TelephonyUI-N>/_big" per version folder.
// Versions: TelephonyUI-10/9/8. There is NO "vi" language in themes — the
// device-locale fallback is ".en".

struct PasscodeThemeInfo: Identifiable {
    var id: String { filePath }
    let name: String
    let filePath: String
    let fileCount: Int
    let keysPreview: [String: UIImage]
    var rawKeyData: [String: Data] = [:]
}

enum PasscodeLanguageTarget: String, CaseIterable, Identifiable {
    case all = "All Languages (Universal)"
    case uk = "Ukrainian (uk)"
    case ru = "Russian (ru)"
    case en = "English (en)"
    case other = "Other / Fallback"
    case es = "Spanish (es)"
    case de = "German (de)"
    case fr = "French (fr)"
    case pl = "Polish (pl)"
    case it = "Italian (it)"
    case pt = "Portuguese (pt)"
    case tr = "Turkish (tr)"
    case ja = "Japanese (ja)"
    case ko = "Korean (ko)"
    case zh = "Chinese (zh)"
    case ar = "Arabic (ar)"
    case he = "Hebrew (he)"

    var id: String { rawValue }

    var code: String {
        switch self {
        case .all: return "all"
        case .uk: return "uk"
        case .ru: return "ru"
        case .en: return "en"
        case .other: return "other"
        case .es: return "es"
        case .de: return "de"
        case .fr: return "fr"
        case .pl: return "pl"
        case .it: return "it"
        case .pt: return "pt"
        case .tr: return "tr"
        case .ja: return "ja"
        case .ko: return "ko"
        case .zh: return "zh"
        case .ar: return "ar"
        case .he: return "he"
        }
    }

    /// Vietnamese display name (the rawValue above is the upstream code).
    var displayName: String {
        switch self {
        case .all: return "Tất cả ngôn ngữ"
        case .uk: return "Tiếng Ukraina (uk)"
        case .ru: return "Tiếng Nga (ru)"
        case .en: return "Tiếng Anh (en)"
        case .other: return "Ngôn ngữ khác"
        case .es: return "Tiếng Tây Ban Nha (es)"
        case .de: return "Tiếng Đức (de)"
        case .fr: return "Tiếng Pháp (fr)"
        case .pl: return "Tiếng Ba Lan (pl)"
        case .it: return "Tiếng Ý (it)"
        case .pt: return "Tiếng Bồ Đào Nha (pt)"
        case .tr: return "Tiếng Thổ Nhĩ Kỳ (tr)"
        case .ja: return "Tiếng Nhật (ja)"
        case .ko: return "Tiếng Hàn (ko)"
        case .zh: return "Tiếng Trung (zh)"
        case .ar: return "Tiếng Ả Rập (ar)"
        case .he: return "Tiếng Do Thái (he)"
        }
    }
}

enum PasscodeBoldTarget: String, CaseIterable, Identifiable {
    case both = "Universal (Regular + Bold)"
    case boldOnly = "Bold Text Only (Fast)"
    case regularOnly = "Regular Font Only (Fast)"

    var id: String { rawValue }

    var code: String {
        switch self {
        case .both: return "both"
        case .boldOnly: return "bold"
        case .regularOnly: return "regular"
        }
    }

    /// Vietnamese display name (the rawValue above is the upstream code).
    var displayName: String {
        switch self {
        case .both: return "Thường + Đậm"
        case .boldOnly: return "Chỉ chữ đậm"
        case .regularOnly: return "Chỉ chữ thường"
        }
    }
}

enum KeypadLocales {
    static let all: [String] = [
        "en", "other", "ru", "uk", "es", "fr", "de", "it", "pt", "tr", "pl", "nl", "ja", "ko", "zh", "ar", "he"
    ]

    static let cyrillicRU: [String: String] = [
        "2": "А Б В Г",
        "3": "Д Е Ж З",
        "4": "И Й К Л",
        "5": "М Н О П",
        "6": "Р С Т У",
        "7": "Ф Х Ц Ч",
        "8": "Ш Щ Ъ Ы",
        "9": "Ь Э Ю Я",
    ]

    static let cyrillicUK: [String: String] = [
        "2": "А Б В Г",
        "3": "Д Е Ж З",
        "4": "І Ї Й К",
        "5": "Л М Н О",
        "6": "П Р С Т",
        "7": "У Ф Х Ц",
        "8": "Ч Ш Щ Ь",
        "9": "Ю Я",
    ]
}

// MARK: - Keypad Layout (geometry only; used by the apply flow + preview)

struct KeypadButtonGeometry: Identifiable {
    var id: String { digit }
    let digit: String
    let letters: String
    let row: Int
    let col: Int
}

enum KeypadLayout {
    static let buttonDiameter: CGFloat = 75.0
    static let gridWidth: CGFloat = 305.0
    static let gridHeight: CGFloat = 1148.0 / 3.0   // ≈382.67
    static let colWidth: CGFloat = 305.0 / 3.0        // ≈101.67
    static let rowHeight: CGFloat = 1148.0 / 12.0     // ≈95.67

    static let allButtons: [KeypadButtonGeometry] = [
        KeypadButtonGeometry(digit: "1", letters: "",        row: 0, col: 0),
        KeypadButtonGeometry(digit: "2", letters: "A B C",  row: 0, col: 1),
        KeypadButtonGeometry(digit: "3", letters: "D E F",  row: 0, col: 2),
        KeypadButtonGeometry(digit: "4", letters: "G H I",  row: 1, col: 0),
        KeypadButtonGeometry(digit: "5", letters: "J K L",  row: 1, col: 1),
        KeypadButtonGeometry(digit: "6", letters: "M N O",  row: 1, col: 2),
        KeypadButtonGeometry(digit: "7", letters: "P Q R S",row: 2, col: 0),
        KeypadButtonGeometry(digit: "8", letters: "T U V",  row: 2, col: 1),
        KeypadButtonGeometry(digit: "9", letters: "W X Y Z",row: 2, col: 2),
        KeypadButtonGeometry(digit: "0", letters: "+",      row: 3, col: 1),
    ]

    static let subtexts: [String: String] = [
        "0": "+",  "1": "",      "2": "A B C",  "3": "D E F",
        "4": "G H I", "5": "J K L", "6": "M N O",
        "7": "P Q R S", "8": "T U V", "9": "W X Y Z"
    ]
}

// MARK: - PasscodeThemeReader (.passthm → key images)

enum PasscodeThemeReader {

    /// Extract key-button images from a .passthm zip file.
    /// Returns a dict [digit → UIImage], raw data dict [digit → Data], and the total file count.
    /// First file per digit wins; only .png/.jpg/.jpeg are counted; previews
    /// are downsampled to max 512px.
    static func inspect(url: URL) -> (keys: [String: UIImage], rawData: [String: Data], fileCount: Int)? {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("airlift_inspect_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. Extract zip via Rust al_passthm_extract (handles deflated & stored zip entries)
        let rc = url.path.withCString { arcC in
            tempDir.path.withCString { dstC in
                al_passthm_extract(arcC, dstC)
            }
        }
        guard rc == 0 else { return nil }

        let files = (FileManager.default.subpaths(atPath: tempDir.path) ?? [])
        guard !files.isEmpty else { return nil }

        var keys: [String: UIImage] = [:]
        var rawData: [String: Data] = [:]
        var fileCount = 0

        for file in files {
            guard !file.hasPrefix("."), !file.contains("__MACOSX") else { continue }
            let lower = file.lowercased()
            guard lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") else { continue }

            fileCount += 1
            let filename = (file as NSString).lastPathComponent
            if let digit = extractDigit(from: filename) {
                if keys[digit] == nil {
                    let filePath = tempDir.appendingPathComponent(file).path
                    if let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) {
                        rawData[digit] = data
                        if let img = ImageEngine.safeImageFromData(data, maxDimension: 512) {
                            keys[digit] = img
                        }
                    }
                }
            }
        }

        return keys.isEmpty ? nil : (keys, rawData, fileCount)
    }

    /// Extract digit matching AirCard's regex logic for themes
    static func extractDigit(from filename: String) -> String? {
        let stem = (filename as NSString).deletingPathExtension
        let stemClean = stem
            .replacingOccurrences(of: "--white", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "-white", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "@3x", with: "")
            .replacingOccurrences(of: "@2x", with: "")

        // 1. AirCard pattern: (?:^[a-zA-Z]+-)?([0-9*#])(?:-([^-\n]+))?
        if let regex = try? NSRegularExpression(pattern: #"(?:^[a-zA-Z]+-)?([0-9*#])"#, options: .caseInsensitive) {
            let nsString = stemClean as NSString
            let match = regex.firstMatch(in: stemClean, range: NSRange(location: 0, length: nsString.length))
            if let match = match, match.numberOfRanges > 1 {
                let range = match.range(at: 1)
                if range.location != NSNotFound {
                    let d = nsString.substring(with: range)
                    if "0123456789".contains(d) { return d }
                }
            }
        }

        // 2. Fallback: search for single digit in filename
        for ch in stemClean {
            if "0123456789".contains(ch) { return String(ch) }
        }
        return nil
    }
}
