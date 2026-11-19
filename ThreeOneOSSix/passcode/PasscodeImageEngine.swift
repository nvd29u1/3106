import UIKit
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers

// MARK: - ImageEngine: Theme Creator slicing (AirCard Models.swift)
//
// Ported from AirCard-iOS v1.3.2 (Mak5er/AirCard-iOS, MIT). The base
// ImageEngine (safeImageFromData / normalizeAndDownsample / resizeImage /
// prepareCardImage(s)) lives in wallet/WalletModels.swift; only the
// passcode Theme Creator helpers are added here as an extension:
// slicePoster cuts one poster photo into per-key tiles, cropToCircle
// crops one photo into a single round key tile.

extension ImageEngine {

    /// Slice a poster image into per-button tiles safely using UIGraphicsImageRenderer.
    /// Never crashes on color spaces, orientations, or memory limits.
    static func slicePoster(
        image: UIImage,
        zoom: CGFloat = 1.0,
        offset: CGPoint = .zero,
        maskToCircles: Bool = false
    ) -> [String: UIImage] {
        let normalized = normalizeAndDownsample(image, maxDimension: 2048)
        let imgW = normalized.size.width
        let imgH = normalized.size.height
        guard imgW > 0, imgH > 0 else { return [:] }

        let gridW: CGFloat = 915.0
        let gridH: CGFloat = 1148.0
        let colW: CGFloat  = 305.0
        let rowH: CGFloat  = 287.0

        let imgAspect  = imgW / imgH
        let gridAspect = gridW / gridH

        let safeZoom = max(0.2, min(5.0, zoom))
        let scaledW: CGFloat
        let scaledH: CGFloat
        if imgAspect > gridAspect {
            scaledH = gridH * safeZoom
            scaledW = scaledH * imgAspect
        } else {
            scaledW = gridW * safeZoom
            scaledH = scaledW / imgAspect
        }

        let imageX = (gridW - scaledW) / 2.0 + offset.x * 3.0
        let imageY = (gridH - scaledH) / 2.0 + offset.y * 3.0

        var results: [String: UIImage] = [:]

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false

        for btn in KeypadLayout.allButtons {
            if maskToCircles {
                // Circle Buttons mode: Exact circular button tile (225×225) matching button diameter exactly
                let cellX: CGFloat = CGFloat(btn.col) * colW
                let cellY: CGFloat = CGFloat(btn.row) * rowH
                let btnCenterX = cellX + colW / 2.0
                let btnCenterY = cellY + rowH / 2.0
                let d: CGFloat = 225.0
                let circleOriginX = btnCenterX - d / 2.0
                let circleOriginY = btnCenterY - d / 2.0

                let tileSize = CGSize(width: d, height: d)
                let destX = imageX - circleOriginX
                let destY = imageY - circleOriginY

                let renderer = UIGraphicsImageRenderer(size: tileSize, format: format)
                let tile = autoreleasepool {
                    renderer.image { _ in
                        let circlePath = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: d, height: d))
                        circlePath.addClip()
                        normalized.draw(in: CGRect(x: destX, y: destY, width: scaledW, height: scaledH))
                    }
                }
                results[btn.digit] = tile
            } else {
                // Seamless Poster mode: Unclipped cell tile (305×287 or 915×287 for key 0)
                let isZeroSeamless = (btn.digit == "0")
                let tileW: CGFloat = isZeroSeamless ? gridW : colW
                let tileH: CGFloat = rowH
                let tileSize = CGSize(width: tileW, height: tileH)

                let cellX: CGFloat = isZeroSeamless ? 0.0 : CGFloat(btn.col) * colW
                let cellY: CGFloat = CGFloat(btn.row) * rowH

                let destX = imageX - cellX
                let destY = imageY - cellY

                let renderer = UIGraphicsImageRenderer(size: tileSize, format: format)
                let tile = autoreleasepool {
                    renderer.image { _ in
                        normalized.draw(in: CGRect(x: destX, y: destY, width: scaledW, height: scaledH))
                    }
                }
                results[btn.digit] = tile
            }
        }

        return results
    }

    /// Crop image into a circle safely (for individual key mode).
    static func cropToCircle(
        image: UIImage,
        targetSize: CGSize = CGSize(width: 225, height: 225),
        circleDiameter: CGFloat = 222.0,
        zoom: CGFloat = 1.0,
        offset: CGPoint = .zero
    ) -> UIImage? {
        let normalized = normalizeAndDownsample(image, maxDimension: 1024)
        let imgW = normalized.size.width
        let imgH = normalized.size.height
        guard imgW > 0, imgH > 0 else { return nil }

        let safeZoom = max(0.2, min(5.0, zoom))
        let baseScale = max(circleDiameter / imgW, circleDiameter / imgH) * safeZoom
        let scaledW = imgW * baseScale
        let scaledH = imgH * baseScale

        let circleX = (targetSize.width  - circleDiameter) / 2.0
        let circleY = (targetSize.height - circleDiameter) / 2.0

        let destX = circleX + (circleDiameter - scaledW) / 2.0 + offset.x * 3.0
        let destY = circleY + (circleDiameter - scaledH) / 2.0 + offset.y * 3.0

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { ctx in
            let circlePath = UIBezierPath(ovalIn: CGRect(x: circleX, y: circleY,
                                                         width: circleDiameter, height: circleDiameter))
            circlePath.addClip()
            normalized.draw(in: CGRect(x: destX, y: destY, width: scaledW, height: scaledH))
        }
    }

    static func pngData(from image: UIImage) -> Data? {
        image.pngData()
    }
}

// MARK: - PhotosPickerItem Universal Image Loader

extension PhotosPickerItem {
    /// Loads a UIImage from the photo picker item, handling HEIC, Live Photos, ProRAW, and iCloud downloads safely.
    func loadUIImage(maxDimension: CGFloat = 2048) async -> UIImage? {
        // 1. Transferable DataRepresentation (automatic conversion to standard format)
        struct ImageTransferable: Transferable {
            let data: Data
            static var transferRepresentation: some TransferRepresentation {
                DataRepresentation(importedContentType: .image) { data in
                    ImageTransferable(data: data)
                }
            }
        }
        if let result = try? await self.loadTransferable(type: ImageTransferable.self) {
            if let img = ImageEngine.safeImageFromData(result.data, maxDimension: maxDimension) {
                return img
            }
        }

        // 2. Direct raw data
        if let data = try? await self.loadTransferable(type: Data.self) {
            if let img = ImageEngine.safeImageFromData(data, maxDimension: maxDimension) {
                return img
            }
        }

        // 3. File representation fallback (ideal for large camera roll photos)
        struct FileImageTransferable: Transferable {
            let url: URL
            static var transferRepresentation: some TransferRepresentation {
                FileRepresentation(importedContentType: .image) { received in
                    let tmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + "_" + received.file.lastPathComponent)
                    try? FileManager.default.copyItem(at: received.file, to: tmp)
                    return FileImageTransferable(url: tmp)
                }
            }
        }
        if let fileResult = try? await self.loadTransferable(type: FileImageTransferable.self) {
            defer { try? FileManager.default.removeItem(at: fileResult.url) }
            if let data = try? Data(contentsOf: fileResult.url),
               let img = ImageEngine.safeImageFromData(data, maxDimension: maxDimension) {
                return img
            }
        }

        return nil
    }
}
