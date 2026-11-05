import Accelerate
import CoreGraphics
import Foundation
import ImageIO

/// "Meilleure à garder" metrics on a grayscale thumbnail: sharpness as the variance of the Laplacian,
/// noise as the spread of (image − blur) in flat areas, dynamic range as the 1st–99th luminance percentile span.
struct ImageQuality: Sendable, Equatable {
    let sharpness: Double
    let noise: Double
    let dynamicRange: Double

    static let side = 512

    init(sharpness: Double, noise: Double, dynamicRange: Double) {
        self.sharpness = sharpness; self.noise = noise; self.dynamicRange = dynamicRange
    }

    init?(url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: Self.side,
              ] as CFDictionary)
        else { return nil }
        self.init(image: thumb)
    }

    init?(image: CGImage) {
        let scale = min(1, Double(Self.side) / Double(max(image.width, image.height)))
        let w = max(3, Int(Double(image.width) * scale)), h = max(3, Int(Double(image.height) * scale))
        var bytes = [UInt8](repeating: 0, count: w * h)
        let drawn = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        let n = w * h
        var lum = [Float](repeating: 0, count: n)
        vDSP_vfltu8(bytes, 1, &lum, 1, vDSP_Length(n))
        var div: Float = 255
        vDSP_vsdiv(lum, 1, &div, &lum, 1, vDSP_Length(n))

        let laplacian: [Float] = [0, 1, 0, 1, -4, 1, 0, 1, 0]
        let gaussian: [Float] = [1, 2, 1, 2, 4, 2, 1, 2, 1].map { $0 / 16 }
        guard let lap = Self.convolve(lum, w, h, laplacian), let blur = Self.convolve(lum, w, h, gaussian),
              let blurLap = Self.convolve(blur, w, h, laplacian) else { return nil }

        var mean: Float = 0, std: Float = 0
        vDSP_normalize(lap, 1, nil, 1, &mean, &std, vDSP_Length(n))
        sharpness = Double(std * std)

        // Flat areas: the half of the pixels where the blurred image has the least detail.
        var residual = [Float](repeating: 0, count: n)
        vDSP_vsub(blur, 1, lum, 1, &residual, 1, vDSP_Length(n))
        let detail = blurLap.map(abs)
        let cut = detail.sorted()[n / 2]
        let flat = residual.indices.filter { detail[$0] <= cut }.map { Double(residual[$0]) }
        let m = flat.reduce(0, +) / Double(max(flat.count, 1))
        noise = (flat.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(max(flat.count, 1))).squareRoot()

        var histogram = [Int](repeating: 0, count: 256)
        for b in bytes { histogram[Int(b)] += 1 }
        func percentile(_ p: Double) -> Int {
            var count = 0
            let target = Int(Double(n) * p)
            for (v, c) in histogram.enumerated() { count += c; if count > target { return v } }
            return 255
        }
        dynamicRange = Double(percentile(0.99) - percentile(0.01)) / 255
    }

    static func convolve(_ src: [Float], _ w: Int, _ h: Int, _ kernel: [Float]) -> [Float]? {
        var input = src
        var out = [Float](repeating: 0, count: src.count)
        let err = input.withUnsafeMutableBytes { i in
            out.withUnsafeMutableBytes { o in
                var s = vImage_Buffer(data: i.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var d = vImage_Buffer(data: o.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                return vImageConvolve_PlanarF(&s, &d, nil, 0, 0, kernel, 3, 3, 0, vImage_Flags(kvImageEdgeExtend))
            }
        }
        return err == kvImageNoError ? out : nil
    }

    /// Index of the best image of a group: z-scores (on a log scale, so one outlier does not flatten the others)
    /// of sharpness, noise (inverted), dynamic range and pixel count.
    static func best(_ qualities: [ImageQuality], pixels: [Int]) -> Int {
        guard qualities.count > 1 else { return 0 }
        func z(_ values: [Double]) -> [Double] {
            let m = values.reduce(0, +) / Double(values.count)
            let sd = (values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count)).squareRoot()
            return values.map { sd > 1e-9 ? ($0 - m) / sd : 0 }
        }
        let sharp = z(qualities.map { log($0.sharpness + 1e-6) }), noise = z(qualities.map { log($0.noise + 1e-4) })
        let range = z(qualities.map(\.dynamicRange)), size = z(pixels.map { log(Double(max($0, 1))) })
        let scores = qualities.indices.map { sharp[$0] - noise[$0] + 0.5 * range[$0] + 0.5 * size[$0] }
        return scores.indices.max { scores[$0] < scores[$1] } ?? 0
    }

    func isNoisy(in group: [ImageQuality]) -> Bool {
        guard let low = group.map(\.noise).min() else { return false }
        return noise > 0.01 && noise > 2 * low
    }

    /// "Floue" / "Bruitée" relative to the rest of the group. Noise inflates the Laplacian, so sharpness is compared
    /// with the images that are not noisy.
    func flaws(in group: [ImageQuality]) -> [String] {
        var out: [String] = []
        let clean = group.filter { !$0.isNoisy(in: group) }
        if let top = clean.map(\.sharpness).max(), top > 0, sharpness < 0.35 * top { out.append("Floue") }
        if isNoisy(in: group) { out.append("Bruitée") }
        return out
    }
}
