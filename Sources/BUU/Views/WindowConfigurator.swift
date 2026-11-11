import AppKit
import SwiftUI

/// Enforces the real content minimum and clamps a restored window frame onto a
/// visible screen. `.windowResizability(.contentMinSize)` alone can be ignored
/// when macOS restores a frame saved before the minimum changed.
struct WindowConfigurator: NSViewRepresentable {
    var minContentSize: CGSize

    func makeNSView(context: Context) -> WindowConfiguringView {
        let view = WindowConfiguringView(frame: .zero)
        view.minContentSize = minContentSize
        return view
    }

    func updateNSView(_ nsView: WindowConfiguringView, context: Context) {
        nsView.minContentSize = minContentSize
        nsView.configureWindow()
    }
}

final class WindowConfiguringView: NSView {
    var minContentSize: CGSize = .zero

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow()
    }

    func configureWindow() {
        guard let window else { return }
        window.contentMinSize = minContentSize

        let minFrameSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: minContentSize)
        ).size
        var frame = window.frame
        frame.size.width = max(frame.size.width, minFrameSize.width)
        frame.size.height = max(frame.size.height, minFrameSize.height)

        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            frame.size.width = min(frame.size.width, visible.width)
            frame.size.height = min(frame.size.height, visible.height)
            frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }

        if frame != window.frame {
            window.setFrame(frame, display: true)
        }
    }
}
