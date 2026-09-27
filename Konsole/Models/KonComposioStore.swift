import Foundation
import Observation
import Security

/// Composio integration state: whether it's on, which toolkits Kon may use,
/// the API key (Keychain) and the cached session whose MCP endpoint is passed
/// to the claude CLI on every request.
@MainActor
@Observable
final class KonComposioStore {
    static let shared = KonComposioStore()

    private enum Key {
        static let isEnabled = "composioEnabled"
        static let selectedToolkits = "composioSelectedToolkits"
        static let userId = "composioUserId"
        static let session = "composioSession"
        static let sessionSignature = "composioSessionSignature"
    }

    private let defaults: UserDefaults

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.isEnabled) }
    }
    /// Toolkit slugs, in the order the user added them.
    private(set) var selectedToolkits: [String] {
        didSet { defaults.set(selectedToolkits, forKey: Key.selectedToolkits) }
    }
    /// Composio's per-user scope for connected accounts. Kon is single-user,
    /// so one fixed id is enough.
    var userId: String {
        didSet { defaults.set(userId, forKey: Key.userId) }
    }

    private(set) var hasAPIKey: Bool
    private(set) var catalog: [ComposioToolkit] = []
    private(set) var isLoadingCatalog = false
    private(set) var statuses: [String: ComposioConnectionStatus] = [:]
    private(set) var isRefreshingStatuses = false
    var lastError: String?

    private var session: ComposioSession?
    private var sessionSignature: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.userId: "konsole"])
        isEnabled = defaults.bool(forKey: Key.isEnabled)
        selectedToolkits = defaults.stringArray(forKey: Key.selectedToolkits) ?? []
        userId = defaults.string(forKey: Key.userId) ?? "konsole"
        hasAPIKey = KonKeychain.read(account: KonKeychain.composioAPIKey) != nil
        if let data = defaults.data(forKey: Key.session) {
            session = try? JSONDecoder().decode(ComposioSession.self, from: data)
        }
        sessionSignature = defaults.string(forKey: Key.sessionSignature)
    }

    var isReady: Bool { isEnabled && hasAPIKey && !selectedToolkits.isEmpty }

    // MARK: - API key

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        KonKeychain.save(trimmed, account: KonKeychain.composioAPIKey)
        hasAPIKey = true
        invalidateSession()
        catalog = []
        lastError = nil
    }

    func removeAPIKey() {
        KonKeychain.delete(account: KonKeychain.composioAPIKey)
        hasAPIKey = false
        invalidateSession()
        catalog = []
        statuses = [:]
    }

    private var client: KonComposioClient? {
        KonKeychain.read(account: KonKeychain.composioAPIKey).map(KonComposioClient.init(apiKey:))
    }

    // MARK: - Toolkit selection

    func toolkit(for slug: String) -> ComposioToolkit? {
        catalog.first { $0.slug == slug }
    }

    func addToolkit(_ slug: String) {
        guard !selectedToolkits.contains(slug) else { return }
        selectedToolkits.append(slug)
        invalidateSession()
        Task { await refreshStatuses() }
    }

    func removeToolkit(_ slug: String) {
        selectedToolkits.removeAll { $0 == slug }
        statuses[slug] = nil
        invalidateSession()
    }

    func loadCatalogIfNeeded() async {
        guard catalog.isEmpty, !isLoadingCatalog, let client else { return }
        isLoadingCatalog = true
        defer { isLoadingCatalog = false }
        do {
            catalog = try await client.listToolkits()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Connections

    func refreshStatuses() async {
        guard hasAPIKey, !selectedToolkits.isEmpty, let client else { return }
        isRefreshingStatuses = true
        defer { isRefreshingStatuses = false }
        do {
            let session = try await ensureSession(client: client)
            statuses = try await client.connectionStatuses(sessionId: session.id, toolkits: selectedToolkits)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Returns the browser URL that finishes connecting `slug` to Composio.
    func connectURL(for slug: String) async -> URL? {
        guard let client else { return nil }
        do {
            let session = try await ensureSession(client: client)
            return try await client.connectURL(sessionId: session.id, toolkit: slug)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Session / MCP

    /// `--mcp-config` JSON for the claude CLI, or nil when Composio is off or
    /// unusable (Kon then simply runs without external services).
    func mcpConfigJSON() async -> String? {
        guard isReady, let client else { return nil }
        do {
            let session = try await ensureSession(client: client)
            let config: [String: Any] = [
                "mcpServers": [
                    "composio": [
                        "type": "http",
                        "url": session.mcpURL.absoluteString,
                        "headers": ["x-api-key": client.apiKey]
                    ]
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: config, options: [.withoutEscapingSlashes])
            return String(data: data, encoding: .utf8)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Reuses the stored session while user id and toolkit set are unchanged,
    /// so connected accounts and the MCP URL stay stable across launches.
    private func ensureSession(client: KonComposioClient) async throws -> ComposioSession {
        let signature = currentSignature
        if let session, sessionSignature == signature {
            return session
        }
        let created = try await client.createSession(userId: userId, toolkits: selectedToolkits)
        session = created
        sessionSignature = signature
        defaults.set(try? JSONEncoder().encode(created), forKey: Key.session)
        defaults.set(signature, forKey: Key.sessionSignature)
        return created
    }

    private var currentSignature: String {
        "\(userId)|\(selectedToolkits.sorted().joined(separator: ","))"
    }

    private func invalidateSession() {
        session = nil
        sessionSignature = nil
        defaults.removeObject(forKey: Key.session)
        defaults.removeObject(forKey: Key.sessionSignature)
    }
}

/// Minimal generic-password Keychain access for secrets like API keys.
enum KonKeychain {
    static let composioAPIKey = "composio-api-key"
    private static let service = "Konsole"

    static func save(_ value: String, account: String) {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8)
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
