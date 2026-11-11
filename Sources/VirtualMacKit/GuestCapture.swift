import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import VirtualMacCore

/// A long-lived ScreenCaptureKit stream of the guest display. macOS only delivers a frame when
/// something on screen changed, so an idle desktop costs nothing and the viewer can long-poll.
/// Frames are captured at the size the viewer draws (never above the native pixels), so the
/// terminal shows them 1:1 instead of resampling a low-resolution image.
final class DesktopStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Frame { let buffer: CVPixelBuffer; let sequence: Int }
    private let queue = DispatchQueue(label: "buu.virtualmac.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var latest: Frame?
    private var sequence = 0
    private var failure: Error?
    // Only touched on the main actor.
    private var stream: SCStream?
    private var size = (0, 0)
    private(set) var lastUsed = Date()

    var current: Frame? { lock.withLock { latest } }

    /// Starts the stream, or resizes it when the viewer's drawing area changed.
    @MainActor func prepare(maxWidth: Int, maxHeight: Int) async throws {
        lastUsed = Date()
        if let failure = lock.withLock({ failure }) { lock.withLock { self.failure = nil }; stream = nil; throw failure }
        let displayID = CGMainDisplayID()
        let points = CGDisplayBounds(displayID).size
        let mode = CGDisplayCopyDisplayMode(displayID)
        let native = (Double(mode?.pixelWidth ?? Int(points.width)), Double(mode?.pixelHeight ?? Int(points.height)))
        let scale = min(1, Double(maxWidth) / native.0, Double(maxHeight) / native.1)
        let wanted = (max(2, Int(native.0 * scale) & ~1), max(2, Int(native.1 * scale) & ~1))
        if stream != nil, wanted == size { return }
        let config = SCStreamConfiguration()
        config.width = wanted.0; config.height = wanted.1
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.queueDepth = 4
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        if let stream {
            try await stream.updateConfiguration(config)
        } else {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { throw Failure("No guest display is available") }
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            self.stream = stream
        }
        size = wanted
    }
    /// Waits up to `timeout` for a frame newer than `sequence`.
    @MainActor func frame(after sequence: Int, timeout: TimeInterval) async throws -> Frame? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let frame = current, frame.sequence != sequence { return frame }
            if Date() >= deadline { return nil }
            try await Task.sleep(nanoseconds: 4_000_000)
        }
    }
    /// Stops capturing after the viewer goes away, so the guest is not recording an unwatched screen.
    @MainActor func stopIfIdle() {
        guard let stream, Date().timeIntervalSince(lastUsed) > 15 else { return }
        self.stream = nil; size = (0, 0)
        lock.withLock { latest = nil }
        Task { try? await stream.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid, let buffer = sample.imageBuffer,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        lock.withLock { sequence += 1; latest = Frame(buffer: buffer, sequence: sequence) }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { lock.withLock { failure = error; latest = nil } }

    /// BGRA rows, lz4-compressed. Desktops compress very well and lz4 costs a few milliseconds.
    static func encode(_ frame: Frame) throws -> (data: Data, width: Int, height: Int, bytesPerRow: Int) {
        let buffer = frame.buffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure("Cannot read the captured frame") }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = NSData(bytesNoCopy: base, length: bytesPerRow * height, freeWhenDone: false)
        return (try pixels.compressed(using: .lz4) as Data, width, height, bytesPerRow)
    }
}
