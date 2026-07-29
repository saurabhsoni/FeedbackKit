import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Downscales and re-encodes an image picked from the photo library.
///
/// ImageIO rather than `UIGraphicsImageRenderer` for two reasons, one of them a
/// correctness bug rather than just performance:
///
/// * The renderer needs a fully decoded `UIImage` first. A 48 MP HEIC decodes to
///   roughly 190 MB of RGBA, plus a second buffer to draw into — enough to get
///   the app jetsammed on an older phone.
/// * The renderer path needs manual EXIF-orientation handling, and getting it
///   wrong silently rotates every photo shot in landscape.
///
/// `CGImageSourceCreateThumbnailAtIndex` decodes straight to the target size and
/// bakes in the orientation transform.
enum ImagePrep {
    /// The bucket's hard limit is 5 MB; aim well under it so a slow connection
    /// isn't uploading megabytes of screenshot for a one-line bug report.
    nonisolated static func downscaleAndEncode(
        _ data: Data,
        maxPixel: CGFloat = 2048,
        targetBytes: Int = 1_500_000
    ) -> Data? {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                // Bakes the EXIF orientation into the pixels.
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ] as CFDictionary)
        else { return nil }
        // `source` must not escape this function — CGImageSource is not Sendable.

        var quality: CGFloat = 0.8
        var best: Data?
        // A bounded ramp, not a binary search: each encode costs real time and
        // being a little over target is harmless.
        for _ in 0 ..< 6 {
            guard let encoded = encode(thumbnail, quality: quality) else { break }
            best = encoded
            if encoded.count <= targetBytes || quality < 0.35 {
                break
            }
            quality -= 0.12
        }
        return best
    }

    private nonisolated static func encode(_ image: CGImage, quality: CGFloat) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }

        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
