import CoreGraphics
import Foundation
import ImageIO

/// 256-bit difference hash (dHash on a 17×16 grayscale thumbnail).
/// Similarity cut-off: 15 differing bits out of 256.
struct ImageHash: Sendable, Hashable {
    let words: [UInt64]
    let width: Int
    let height: Int

    static let threshold = 15

    func distance(to other: ImageHash) -> Int {
        zip(words, other.words).reduce(0) { $0 + ($1.0 ^ $1.1).nonzeroBitCount }
    }

    /// Nil for unreadable images or images under 128×32 px.
    init?(url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              max(w, h) >= 128, min(w, h) >= 32,
              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 256,
              ] as CFDictionary)
        else { return nil }
        self.init(image: thumb, width: w, height: h)
    }

    init?(image: CGImage, width: Int? = nil, height: Int? = nil) {
        let cols = 17, rows = 16
        var px = [UInt8](repeating: 0, count: cols * rows)
        let drawn = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: cols,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: cols, height: rows))
            return true
        }
        guard drawn else { return nil }
        var words = [UInt64](repeating: 0, count: 4)
        for y in 0..<rows {
            for x in 0..<(cols - 1) where px[y * cols + x] > px[y * cols + x + 1] {
                let bit = y * (cols - 1) + x
                words[bit / 64] |= 1 << UInt64(bit % 64)
            }
        }
        self.words = words
        self.width = width ?? image.width
        self.height = height ?? image.height
    }

    /// Clusters around a pivot: each group holds images within `threshold` of its first member,
    /// which avoids chains where A~B and B~C but A and C differ.
    static func clusters(_ hashes: [ImageHash], threshold: Int = threshold) -> [[Int]] {
        var assigned = [Bool](repeating: false, count: hashes.count)
        var out: [[Int]] = []
        for i in hashes.indices where !assigned[i] {
            var group = [i]
            for j in (i + 1)..<hashes.count where !assigned[j] && hashes[i].distance(to: hashes[j]) <= threshold {
                group.append(j)
                assigned[j] = true
            }
            if group.count > 1 { assigned[i] = true; out.append(group) }
        }
        return out
    }
}
