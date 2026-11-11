import Foundation

/// Thread-safe sink for messages emitted by the embedded VM runtime.
///
/// The storage layer (`VirtualMacKit`) writes through this instead of only
/// stderr, so BUU can show and export installation/runtime logs.
public enum VirtualMacLog {
    private static let lock = NSLock()
    private static var sink: ((String) -> Void)?

    public static func setSink(_ sink: ((String) -> Void)?) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }

    public static func record(_ message: String) {
        lock.lock()
        let sink = sink
        lock.unlock()
        sink?(message)
    }
}
