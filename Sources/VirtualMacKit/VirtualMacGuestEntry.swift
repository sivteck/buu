import AppKit
import Darwin

/// Entry point for the helper app that runs **inside** the virtual Mac.
///
/// The host never calls this path. `GuestGuard` refuses to start unless the
/// machine model identifies a VirtualMac guest, so a copy of this executable
/// accidentally launched on the host exits before touching input or screen APIs.
public enum VirtualMacGuestMain {
    /// Retain the helper for the lifetime of the guest process. NSControl
    /// targets are unowned, so a local GuestRuntime would deallocate after
    /// start() and its permission buttons would silently do nothing.
    @MainActor private static var guestRuntime: GuestRuntime?

    @MainActor
    public static func run() {
        do {
            try GuestGuard.requireVirtualMac()
        } catch {
            stderr("BUU Virtual Mac guest: \(error.localizedDescription)")
            exit(1)
        }

        NSApplication.shared.setActivationPolicy(.accessory)

        Task { @MainActor in
            do {
                if try await GuestBootstrap.installAndRelaunchIfNeeded() {
                    exit(0)
                }
                let exchange = URL(
                    fileURLWithPath: ProcessInfo.processInfo.environment["BUU_VIRTUAL_MAC_EXCHANGE"]
                        ?? "/Volumes/My Shared Files/control"
                )
                let guest = try GuestRuntime(exchange: exchange)
                guestRuntime = guest
                guest.start()
            } catch {
                stderr("BUU Virtual Mac guest: \(error.localizedDescription)")
                let alert = NSAlert()
                alert.messageText = "BUU Virtual Mac guest setup"
                alert.informativeText = error.localizedDescription
                alert.runModal()
                exit(1)
            }
        }

        NSApplication.shared.run()
    }
}
