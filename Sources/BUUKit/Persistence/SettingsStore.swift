import Foundation
#if canImport(Security)
import Security
#endif

/// Global application settings.
public struct AppSettings: Codable, Sendable, Equatable {
    public var endpoints: [ProviderEndpoint]
    public var activeEndpointID: UUID?
    public var selectedModel: String
    /// Show the "thinking"/reasoning blocks of models that provide them.
    public var showReasoning: Bool
    /// Send the endpoint's system prompt with every request.
    public var sendSystemPrompt: Bool
    /// Preferred appearance: `system`, `light` or `dark`.
    public var appearance: Appearance
    /// Named virtual-Mac recipes.
    public var macTaskConfigurations: [MacTaskConfiguration]?
    public var activeMacTaskConfigurationID: UUID?
    /// User-created Agentic task lanes.
    public var agenticTasks: [AgenticTaskRecord]?
    public var activeAgenticTaskID: UUID?
    /// Destination for automatically archived Mac task traces.
    public var macTraceAutosavePath: String?
    public var macTraceAutosaveBookmark: Data?

    public enum Appearance: String, Codable, Sendable, CaseIterable {
        case system
        case light
        case dark

        public var displayName: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }

    public init(
        endpoints: [ProviderEndpoint] = EndpointPresets.all,
        activeEndpointID: UUID? = nil,
        selectedModel: String = "",
        showReasoning: Bool = true,
        sendSystemPrompt: Bool = true,
        appearance: Appearance = .system,
        macTaskConfigurations: [MacTaskConfiguration]? = nil,
        activeMacTaskConfigurationID: UUID? = nil,
        agenticTasks: [AgenticTaskRecord]? = nil,
        activeAgenticTaskID: UUID? = nil,
        macTraceAutosavePath: String? = nil,
        macTraceAutosaveBookmark: Data? = nil
    ) {
        self.endpoints = endpoints
        self.activeEndpointID = activeEndpointID ?? endpoints.first?.id
        self.selectedModel = selectedModel
        self.showReasoning = showReasoning
        self.sendSystemPrompt = sendSystemPrompt
        self.appearance = appearance
        self.macTaskConfigurations = macTaskConfigurations
        self.activeMacTaskConfigurationID = activeMacTaskConfigurationID
        self.agenticTasks = agenticTasks
        self.activeAgenticTaskID = activeAgenticTaskID
        self.macTraceAutosavePath = macTraceAutosavePath
        self.macTraceAutosaveBookmark = macTraceAutosaveBookmark
    }

    public var activeEndpoint: ProviderEndpoint? {
        if let activeEndpointID, let match = endpoints.first(where: { $0.id == activeEndpointID }) {
            return match
        }
        return endpoints.first
    }
}

/// Loads and stores ``AppSettings``.
public actor SettingsStore {
    private let fileStore: FileStore

    public init(fileStore: FileStore = FileStore()) {
        self.fileStore = fileStore
    }

    public func load() async -> AppSettings {
        try? await fileStore.prepare()
        guard await fileStore.fileExists(at: await fileStore.settingsURL) else {
            let defaults = AppSettings()
            await save(defaults)
            return defaults
        }
        do {
            let settings = try await fileStore.readJSON(AppSettings.self, from: await fileStore.settingsURL)
            return settings
        } catch {
            return AppSettings()
        }
    }

    public func save(_ settings: AppSettings) async {
        try? await fileStore.prepare()
        try? await fileStore.writeJSON(settings, to: await fileStore.settingsURL)
    }
}

/// Stores API keys in the system keychain (falls back to no-op on platforms
/// without a keychain).
public enum KeychainStore {
    private static let service = "com.buu.app.apikeys"

    public static func set(_ value: String, for account: String) throws {
        #if canImport(Security)
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        // The app is a foreground only tool, so the key only has to be readable
        // while the user is logged in.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError("Keychain write failed with status \(status)")
        }
        #else
        throw KeychainError.unsupported
        #endif
    }

    public static func get(for account: String) -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }

    public static func delete(for account: String) throws {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError("Keychain delete failed with status \(status)")
        }
        #endif
    }

    /// A keychain operation failed.
    ///
    /// Deliberately a struct with an explicit initializer: building the error
    /// from a plain message keeps the description meaningful on every SDK and
    /// avoids depending on how `OSStatus` is spelled by the platform.
    public struct KeychainError: LocalizedError, Sendable {
        public let message: String

        public init(_ message: String) {
            self.message = message
        }

        public var errorDescription: String? { message }

        public static var unsupported: KeychainError {
            KeychainError("Keychain is not available on this platform")
        }
    }
}
