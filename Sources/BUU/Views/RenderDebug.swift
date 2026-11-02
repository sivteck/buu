import SwiftUI

/// Debug-only instrumentation.
///
/// Enable with the environment variable `BUU_RENDER_DEBUG=1`:
///
///     BUU_RENDER_DEBUG=1 swift run BUU
///
/// In Xcode: *Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Arguments ▸ Environment
/// Variables*.
enum RenderDebug {

    static var isEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["BUU_RENDER_DEBUG"] == "1"
        #else
        false
        #endif
    }

    /// Measures the cost of building a view body and prints when it is slow.
    static func timed<T>(
        _ label: @autoclosure () -> String,
        threshold: Double = 1.0,
        _ work: () -> T
    ) -> T {
        guard isEnabled else { return work() }

        let start = CFAbsoluteTimeGetCurrent()
        let result = work()
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        if elapsed >= threshold {
            print(String(format: "[BUU] %@ body took %.2f ms", label(), elapsed))
        }
        return result
    }

    static func logFirstLayout(id: UUID, height: CGFloat) {
        guard isEnabled else { return }
        print("[BUU] row \(shortID(id)) first layout \(Int(height.rounded())) pt")
    }

    static func logHeightChange(id: UUID, from old: CGFloat, to new: CGFloat) {
        guard isEnabled else { return }
        print(String(
            format: "[BUU] ⚠️ row %@ height changed AFTER first layout: %.1f → %.1f pt",
            shortID(id), old, new
        ))
    }

    static func logScroll(_ message: String) {
        guard isEnabled else { return }
        print("[BUU] scroll: \(message)")
    }

    private static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }
}

/// Reports when a row's height changes after it was first laid out — the exact
/// symptom of the scroll jump. No-op unless `BUU_RENDER_DEBUG=1`.
struct RenderProbeModifier: ViewModifier {
    let id: UUID

    @State private var lastHeight: CGFloat?

    func body(content: Content) -> some View {
        content.background {
            if RenderDebug.isEnabled {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { record(geometry.size.height) }
                        .onChange(of: geometry.size.height) { _, newHeight in
                            record(newHeight)
                        }
                }
            }
        }
    }

    private func record(_ height: CGFloat) {
        guard height > 0 else { return }

        if let lastHeight {
            if abs(lastHeight - height) > 0.5 {
                RenderDebug.logHeightChange(id: id, from: lastHeight, to: height)
            }
        } else {
            RenderDebug.logFirstLayout(id: id, height: height)
        }

        lastHeight = height
    }
}
