import SwiftUI
import ImageIO
import AVFoundation

/// A master artwork image loaded off the main thread and downsampled (the NAS originals can be large).
struct ArtImage: View {
    let url: URL?
    var maxPixel: Int = 900
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Rectangle().fill(Color.black.opacity(0.35)) }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            let size = maxPixel
            image = await Task.detached(priority: .utility) { Self.load(url, maxPixel: size) }.value
        }
    }

    nonisolated static func load(_ url: URL, maxPixel: Int) -> NSImage? {
        if url.pathExtension.lowercased() == "mp4" { return frame(of: url, maxPixel: maxPixel) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// A video snap shown as one still frame from its first seconds.
    nonisolated static func frame(of url: URL, maxPixel: Int) -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        for seconds in [2.0, 0.5, 0.0] {
            if let cg = try? generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil) {
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
        return nil
    }
}
