import Foundation
import UIKit

// MARK: - PasscodeThemePackager (native Swift zip via Foundation)
//
// Ported from AirCard-iOS v1.3.2 (Mak5er/AirCard-iOS, MIT), Models.swift.
// Builds a .passthm file: a plain ZIP with STORED (method 0,
// uncompressed) entries and no manifest. Entry names look like
// "<TelephonyUI-N>/<lang>-<digit>-<subtext>--white[-bold].png" plus one
// empty marker "<TelephonyUI-N>/_big" per version folder.
//
// Upstream quirks kept as-is:
// - Digits 0 and 1 get only the blank-subtext variant (no "+"/letters
//   variant — unlike the flash staging path, which also writes the "+"
//   variant for digit 0).
// - When language == .all, the Cyrillic RU/UK subtexts are emitted under
//   EVERY language, not just ru/uk.
// - centralDirCount is UInt16; universal settings produce ~4,389 entries,
//   which still fits.

enum PasscodeThemePackager {

    /// Build a .passthm zip archive in memory and return its Data.
    static func buildPassthm(
        keys: [String: UIImage],
        telephonyVersion: String = "all",
        language: PasscodeLanguageTarget = .all,
        bold: PasscodeBoldTarget = .both
    ) throws -> Data {
        var zipData = Data()
        var centralDirectory = Data()
        var centralDirCount: UInt16 = 0

        func addEntry(name: String, content: Data) {
            guard let nameData = name.data(using: .utf8) else { return }
            let crc = crc32(content)
            let localHeader = makeLocalFileHeader(name: nameData, content: content, crc: crc)
            let offset = UInt32(zipData.count)
            zipData.append(localHeader)
            zipData.append(content)
            centralDirectory.append(
                makeCentralDirEntry(name: nameData, content: content, crc: crc, offset: offset))
            centralDirCount += 1
        }

        let targetVers: [String]
        if telephonyVersion == "all" || telephonyVersion.isEmpty {
            targetVers = ["TelephonyUI-10", "TelephonyUI-9", "TelephonyUI-8"]
        } else {
            targetVers = [telephonyVersion]
        }

        let langs: [String]
        if language == .all {
            langs = KeypadLocales.all
        } else {
            langs = language.code == "other" ? ["other"] : [language.code, "other"]
        }

        let boldSuffixes: [String]
        switch bold {
        case .both: boldSuffixes = ["", "-bold"]
        case .boldOnly: boldSuffixes = ["-bold"]
        case .regularOnly: boldSuffixes = [""]
        }

        for ver in targetVers {
            addEntry(name: "\(ver)/_big", content: Data())

            for (digit, image) in keys {
                guard let pngData = image.pngData() else { continue }
                let stdSubtext = KeypadLayout.subtexts[digit] ?? ""

                for lang in langs {
                    for bld in boldSuffixes {
                        // 1. Blank subtext
                        addEntry(name: "\(ver)/\(lang)-\(digit)---white\(bld).png", content: pngData)

                        // 2. Standard Latin subtext
                        if !stdSubtext.isEmpty {
                            addEntry(name: "\(ver)/\(lang)-\(digit)-\(stdSubtext)--white\(bld).png", content: pngData)
                            let noSpace = stdSubtext.replacingOccurrences(of: " ", with: "")
                            if noSpace != stdSubtext {
                                addEntry(name: "\(ver)/\(lang)-\(digit)-\(noSpace)--white\(bld).png", content: pngData)
                            }
                        }

                        // 3. Cyrillic subtexts
                        if (lang == "ru" || language == .all), let ruSub = KeypadLocales.cyrillicRU[digit] {
                            addEntry(name: "\(ver)/\(lang)-\(digit)-\(ruSub)--white\(bld).png", content: pngData)
                        }
                        if (lang == "uk" || language == .all), let ukSub = KeypadLocales.cyrillicUK[digit] {
                            addEntry(name: "\(ver)/\(lang)-\(digit)-\(ukSub)--white\(bld).png", content: pngData)
                        }
                    }
                }
            }
        }

        // End of central directory record
        let cdOffset = UInt32(zipData.count)
        let cdSize   = UInt32(centralDirectory.count)
        zipData.append(centralDirectory)
        zipData.append(makeEndRecord(count: centralDirCount, size: cdSize, offset: cdOffset))
        return zipData
    }

    static func buildPassthm(keys: [String: UIImage]) throws -> Data {
        try buildPassthm(keys: keys, telephonyVersion: "all", language: .all, bold: .both)
    }

    // MARK: - Zip primitives

    private static func makeLocalFileHeader(name: Data, content: Data, crc: UInt32) -> Data {
        var d = Data()
        d.appendLE32(0x04034b50)   // Local file header signature
        d.appendLE16(20)           // Version needed: 2.0
        d.appendLE16(0x0800)       // Flags: UTF-8 file names (bit 11)
        d.appendLE16(0)            // Compression: stored
        d.appendLE16(0)            // Last mod time
        d.appendLE16(0)            // Last mod date
        d.appendLE32(crc)
        d.appendLE32(UInt32(content.count))   // Compressed size
        d.appendLE32(UInt32(content.count))   // Uncompressed size
        d.appendLE16(UInt16(name.count))
        d.appendLE16(0)            // Extra field length
        d.append(name)
        return d
    }

    private static func makeCentralDirEntry(
        name: Data, content: Data, crc: UInt32, offset: UInt32
    ) -> Data {
        var d = Data()
        d.appendLE32(0x02014b50)   // Central dir file header signature
        d.appendLE16(20)           // Version made by
        d.appendLE16(20)           // Version needed
        d.appendLE16(0x0800)       // Flags: UTF-8 file names (bit 11)
        d.appendLE16(0)            // Compression: stored
        d.appendLE16(0)            // Last mod time
        d.appendLE16(0)            // Last mod date
        d.appendLE32(crc)
        d.appendLE32(UInt32(content.count))
        d.appendLE32(UInt32(content.count))
        d.appendLE16(UInt16(name.count))
        d.appendLE16(0)            // Extra field length
        d.appendLE16(0)            // File comment length
        d.appendLE16(0)            // Disk number start
        d.appendLE16(0)            // Internal file attributes
        d.appendLE32(0)            // External file attributes
        d.appendLE32(offset)       // Relative offset of local header
        d.append(name)
        return d
    }

    private static func makeEndRecord(count: UInt16, size: UInt32, offset: UInt32) -> Data {
        var d = Data()
        d.appendLE32(0x06054b50)   // End of central directory signature
        d.appendLE16(0)            // Disk number
        d.appendLE16(0)            // Disk with start of central directory
        d.appendLE16(count)
        d.appendLE16(count)
        d.appendLE32(size)
        d.appendLE32(offset)
        d.appendLE16(0)            // Comment length
        return d
    }

    /// CRC-32 (ISO 3309 / ITU-T V.42).
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            var b = UInt32(byte)
            for _ in 0..<8 {
                let mixed = (crc ^ b) & 1
                crc >>= 1
                if mixed != 0 { crc ^= 0xEDB8_8320 }
                b >>= 1
            }
        }
        return ~crc
    }
}

private extension Data {
    mutating func appendLE16(_ v: UInt16) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
    mutating func appendLE32(_ v: UInt32) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
}
