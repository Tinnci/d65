#if DEBUG
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Debug-only: records the app's own window to Documents/<name>.gif for the README
/// (`-record <seconds> <name>`), so no Mac-side screen-capture permission is needed.
@MainActor final class DemoRecorder {
    private static var current: DemoRecorder?
    private let encoder: GIFEncoder
    private let width: CGFloat, interval: Double, duration: Double
    private var link: CADisplayLink?
    private var started = 0.0, lastFrame = 0.0

    static func start(seconds: Double, name: String, width: CGFloat = 360, fps: Double = 24) {
        let url = URL.documentsDirectory.appending(path: "\(name).gif")
        guard let encoder = GIFEncoder(url: url) else { return }
        current = DemoRecorder(encoder: encoder, width: width, interval: 1 / fps, duration: seconds)
    }

    private init(encoder: GIFEncoder, width: CGFloat, interval: Double, duration: Double) {
        self.encoder = encoder; self.width = width; self.interval = interval; self.duration = duration
        started = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if now - started >= duration {
            link.invalidate(); self.link = nil
            encoder.finish(at: now); Self.current = nil
            return
        }
        guard now - lastFrame >= interval * 0.95,
              let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow) else { return }
        lastFrame = now
        let format = UIGraphicsImageRendererFormat()
        format.scale = width / window.bounds.width
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        if let cgImage = image.cgImage { encoder.add(cgImage, at: now) }
    }
}

/// Encodes on its own queue. A frame is written once the next different one arrives, so its delay
/// covers every identical frame in between.
private final class GIFEncoder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "demo-recorder")
    private let url: URL
    private let destination: CGImageDestination
    private var pending: (image: CGImage, bytes: Data, time: Double)?
    private var written = 0

    init?(url: URL) {
        try? FileManager.default.removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 100_000, nil) else { return nil }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        self.url = url; self.destination = destination
    }

    func add(_ image: CGImage, at time: Double) {
        queue.async { [self] in
            let bytes = image.dataProvider?.data as Data? ?? Data()
            if let pending, pending.bytes == bytes { return }
            flush(until: time)
            pending = (image, bytes, time)
        }
    }

    func finish(at time: Double) {
        queue.async { [self] in
            flush(until: time)
            let ok = CGImageDestinationFinalize(destination)
            print("[record] \(ok ? "saved" : "failed") \(written) frames to \(url.lastPathComponent)")
        }
    }

    private func flush(until time: Double) {
        guard let pending else { return }
        let delay = max(0.02, time - pending.time)
        CGImageDestinationAddImage(destination, pending.image, [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay,
        ]] as CFDictionary)
        written += 1
        self.pending = nil
    }
}
#endif
