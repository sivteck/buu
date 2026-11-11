import Foundation

/// Formats VM/Virtualization failures with the details needed to act on them.
///
/// `VZMacOSInstaller` often reports only "an error occurred during installation".
/// The useful information is usually in the NSError domain/code, failure reason,
/// recovery suggestion, debug description or an underlying error.
public enum VirtualMacDiagnostics {
    public static func describe(_ error: Error, context: String? = nil) -> String {
        if let failure = error as? Failure {
            guard let context, !context.isEmpty, !failure.message.hasPrefix(context) else {
                return failure.message
            }
            return "\(context): \(failure.message)"
        }

        let nsError = error as NSError
        var lines: [String] = []

        let headline = nsError.localizedDescription
        lines.append(prefixed(headline, context: context))

        if let reason = nsError.localizedFailureReason,
           !reason.isEmpty,
           reason != headline {
            lines.append("Reason: \(reason)")
        }
        if let suggestion = nsError.localizedRecoverySuggestion, !suggestion.isEmpty {
            lines.append("Suggestion: \(suggestion)")
        }

        lines.append("Type: \(String(reflecting: type(of: error)))")
        lines.append("Domain/code: \(nsError.domain) / \(nsError.code)")

        let interestingKeys = [
            NSDebugDescriptionErrorKey,
            NSFilePathErrorKey,
            NSURLErrorKey,
            NSLocalizedRecoveryOptionsErrorKey,
        ]
        for key in interestingKeys {
            guard let value = nsError.userInfo[key] else { continue }
            let text = String(describing: value)
            guard !text.isEmpty, text != headline else { continue }
            lines.append("\(key): \(clip(text))")
        }

        let ignoredKeys: Set<String> = [
            NSLocalizedDescriptionKey,
            NSUnderlyingErrorKey,
            NSRecoveryAttempterErrorKey,
        ]
        let extraKeys = nsError.userInfo.keys
            .map { String(describing: $0) }
            .filter { !ignoredKeys.contains($0) }
            .sorted()
        if !extraKeys.isEmpty {
            let extras = extraKeys.compactMap { key -> String? in
                guard let value = nsError.userInfo[key] else { return nil }
                let text = clip(String(describing: value))
                return text.isEmpty ? nil : "\(key)=\(text)"
            }
            if !extras.isEmpty {
                lines.append("User info: " + extras.joined(separator: "; "))
            }
        }

        var underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        var depth = 0
        while let current = underlying, depth < 4 {
            depth += 1
            lines.append("Underlying \(depth): \(current.domain) / \(current.code) — \(clip(current.localizedDescription))")
            if let reason = current.localizedFailureReason, !reason.isEmpty {
                lines.append("Underlying \(depth) reason: \(clip(reason))")
            }
            if let debug = current.userInfo[NSDebugDescriptionErrorKey] {
                lines.append("Underlying \(depth) debug: \(clip(String(describing: debug)))")
            }
            underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }

        return lines.joined(separator: "\n")
    }

    private static func prefixed(_ message: String, context: String?) -> String {
        guard let context, !context.isEmpty else { return message }
        return "\(context): \(message)"
    }

    private static func clip(_ value: String, limit: Int = 800) -> String {
        value.count <= limit ? value : String(value.prefix(limit)) + "…"
    }
}
