import UIKit
import CoreGraphics
import ImageIO

// MARK: - Wallet card model (Wallet slice extracted from upstream Models.swift)

struct CardItem: Identifiable, Equatable {
    let id: String
    var isSelected: Bool = true
    var displayName: String? = nil
    var paymentNetwork: String? = nil
    var isVerified: Bool = true
    var customImageData: Data? = nil  // Primary PNG data (1536x969)
    var customImage: UIImage? = nil   // Fast cached UIImage for display

    init(
        id: String,
        displayName: String? = nil,
        paymentNetwork: String? = nil,
        isSelected: Bool = true,
        isVerified: Bool = true,
        customImageData: Data? = nil,
        customImage: UIImage? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.paymentNetwork = paymentNetwork
        self.isSelected = isSelected
        self.isVerified = isVerified
        self.customImageData = customImageData
        self.customImage = customImage
    }

    var uiImage: UIImage? {
        customImage ?? (customImageData.flatMap { UIImage(data: $0) })
    }

    var title: String {
        if let name = displayName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }
        if let net = paymentNetwork, !net.isEmpty {
            // Tên hãng (Visa, Mastercard…) giữ nguyên; tên loại thẻ dịch sang tiếng Việt.
            if net.hasSuffix("Card") || net.hasPrefix("Thẻ") { return net }
            return "Thẻ \(net)"
        }
        return "Thẻ thanh toán"
    }

    /// Normalizes and cleans a card identifier, stripping paths, extensions (.pkpass, .cache),
    /// quotes, and whitespace. Validates length and format.
    static func cleanCardId(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "'\",()<>;[]{}"))
        if s.contains("/") {
            s = (s as NSString).lastPathComponent
        }
        for ext in [".pkpass", ".cache", ".pkcache"] {
            if s.hasSuffix(ext) {
                s = String(s.dropLast(ext.count))
            }
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "'\",()<>;[]{}. "))
        if s.count >= 20 && s.count <= 64 && !s.contains("/") {
            if s.count == 36 && s.filter({ $0 == "-" }).count == 4 {
                return nil // UUID format, not a card hash
            }
            return s
        }
        return nil
    }

    static func == (lhs: CardItem, rhs: CardItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.isSelected == rhs.isSelected &&
        lhs.displayName == rhs.displayName &&
        lhs.paymentNetwork == rhs.paymentNetwork &&
        lhs.isVerified == rhs.isVerified &&
        lhs.customImage === rhs.customImage &&
        (lhs.customImageData?.count == rhs.customImageData?.count)
    }
}

/// Flash progress state for the Wallet card apply flow.
enum FlashPhase: Equatable {
    case idle, running, done(ok: Bool)
}

// MARK: - Safe Image Engine (Wallet slice only — extracted from upstream Models.swift)

enum ImageEngine {

    /// Decodes image data directly at reduced dimensions using ImageIO.
    /// Never loads the full uncompressed 48MP bitmap into memory, preventing Jetsam OOM crashes.
    static func safeImageFromData(_ data: Data, maxDimension: CGFloat = 2048) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            return UIImage(data: data).map { normalizeAndDownsample($0, maxDimension: maxDimension) }
        }
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ] as CFDictionary
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) {
            return UIImage(cgImage: cgImage)
        }
        return UIImage(data: data).map { normalizeAndDownsample($0, maxDimension: maxDimension) }
    }

    /// Normalizes image orientation and downsamples huge camera images (48MP/RAW)
    /// to avoid Jetsam OOM crashes on iOS.
    static func normalizeAndDownsample(_ image: UIImage, maxDimension: CGFloat = 2048) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }

        let scale = min(1.0, maxDimension / max(size.width, size.height))
        let targetSize = CGSize(width: max(1, floor(size.width * scale)),
                                height: max(1, floor(size.height * scale)))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    /// Resize image to specific size.
    static func resizeImage(_ image: UIImage, targetSize: CGSize) -> Data? {
        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0 else { return nil }
        let scale = max(targetSize.width / imgSize.width, targetSize.height / imgSize.height)
        let scaledSize = CGSize(width: imgSize.width * scale, height: imgSize.height * scale)
        let origin = CGPoint(x: (targetSize.width - scaledSize.width) / 2,
                             y: (targetSize.height - scaledSize.height) / 2)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let out = renderer.image { _ in
            image.draw(in: CGRect(origin: origin, size: scaledSize))
        }
        return out.pngData()
    }

    /// Resize image to exactly 1536×969 PNG — for Wallet card skin preview and primary storage.
    static func prepareCardImage(from image: UIImage) -> Data? {
        let normalized = normalizeAndDownsample(image, maxDimension: 2560)
        return resizeImage(normalized, targetSize: CGSize(width: 1536, height: 969))
    }

    /// Prepares all exact resolution files for Apple Wallet pass skins.
    /// Perfectly fits standard, Plus, Pro, and Pro Max screens.
    /// Emits cardBackgroundCombined, diffuse, background, and strip so all Apple Pay passes are covered.
    static func prepareAllCardSkins(from image: UIImage) -> [String: Data] {
        let normalized = normalizeAndDownsample(image, maxDimension: 2560)
        var skins: [String: Data] = [:]

        let bg3x = resizeImage(normalized, targetSize: CGSize(width: 1536, height: 969))
        let bg2x = resizeImage(normalized, targetSize: CGSize(width: 1024, height: 646))

        if let data3x = bg3x {
            skins["cardBackgroundCombined@3x.png"] = data3x
            skins["diffuse@3x.png"] = data3x
            skins["background@3x.png"] = data3x
            skins["strip@3x.png"] = data3x
        }
        if let data2x = bg2x {
            skins["cardBackgroundCombined@2x.png"] = data2x
            skins["diffuse@2x.png"] = data2x
            skins["background@2x.png"] = data2x
            skins["strip@2x.png"] = data2x
        }

        // Vector PDF variants for Suica, Pasmo, ICOCA, and transit/transport passes
        let pdfRect = CGRect(origin: .zero, size: CGSize(width: 1536, height: 969))
        let pdfRenderer = UIGraphicsPDFRenderer(bounds: pdfRect)
        let pdfData = pdfRenderer.pdfData { ctx in
            ctx.beginPage()
            normalized.draw(in: pdfRect)
        }
        skins["cardBackgroundCombined.pdf"] = pdfData
        skins["background.pdf"] = pdfData
        skins["strip.pdf"] = pdfData

        return skins
    }
}
