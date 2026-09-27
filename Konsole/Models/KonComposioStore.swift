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
        static let accountProfiles = "composioAccountProfiles"
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
    /// so one fixed id is enough; several Gmail accounts etc. all live under it.
    var userId: String {
        didSet { defaults.set(userId, forKey: Key.userId) }
    }

    private(set) var hasAPIKey: Bool
    private(set) var catalog: [ComposioToolkit] = []
    private(set) var isLoadingCatalog = false
    private(set) var statuses: [String: ComposioConnectionStatus] = [:]
    /// Connected accounts per toolkit slug, oldest first.
    private(set) var accounts: [String: [ComposioConnectedAccount]] = [:]
    /// Owner of each connected account (by account id), for Google accounts.
    /// Cached across launches; looked up once per account.
    private(set) var profiles: [String: ComposioAccountProfile] = [:] {
        didSet { defaults.set(try? JSONEncoder().encode(profiles), forKey: Key.accountProfiles) }
    }
    private(set) var isRefreshingStatuses = false
    /// The API key is scoped without "connected_accounts" access, so accounts
    /// can't be listed, renamed or removed (connecting still works).
    private(set) var lacksAccountPermission = false
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
        if let data = defaults.data(forKey: Key.accountProfiles),
           let profiles = try? JSONDecoder().decode([String: ComposioAccountProfile].self, from: data) {
            self.profiles = profiles
        }
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
        accounts = [:]
        profiles = [:]
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
        accounts[slug] = nil
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

    /// Re-checks every selected toolkit. The account list and the session's
    /// view are fetched independently, so one failing request can't leave a
    /// toolkit stuck at "確認中"; every toolkit ends up with some status.
    /// `reloadProfiles` also re-reads the owner of each Google account.
    func refreshStatuses(reloadProfiles: Bool = false) async {
        guard hasAPIKey, !selectedToolkits.isEmpty, let client else { return }
        isRefreshingStatuses = true
        defer { isRefreshingStatuses = false }
        let toolkits = selectedToolkits

        async let connected = client.connectedAccounts(userId: userId, toolkits: toolkits)
        var sessionStatuses: [String: ComposioConnectionStatus]?
        var errors: [String] = []
        do {
            let session = try await ensureSession(client: client)
            sessionStatuses = try await client.connectionStatuses(sessionId: session.id, toolkits: toolkits)
        } catch {
            errors.append(error.localizedDescription)
        }
        var fetchedAccounts: [ComposioConnectedAccount]?
        do {
            fetchedAccounts = try await connected
            lacksAccountPermission = false
        } catch KonComposioError.api(status: 403, _) {
            // Explained by a dedicated notice in the settings, not as an error.
            lacksAccountPermission = true
        } catch {
            errors.append(error.localizedDescription)
        }

        if let fetchedAccounts {
            // Abandoned OAuth attempts linger as INITIATED; only show accounts
            // that are usable or still need finishing.
            let visible = fetchedAccounts.filter { $0.isActive || $0.status.uppercased() == "INITIATED" }
            accounts = Dictionary(grouping: visible, by: \.toolkitSlug)
            let ids = Set(visible.map(\.id))
            profiles = profiles.filter { ids.contains($0.key) }
        }

        var statuses: [String: ComposioConnectionStatus] = [:]
        for slug in toolkits {
            let list = accounts[slug] ?? []
            let fromSession = sessionStatuses?[slug]
            if list.contains(where: \.isActive) {
                statuses[slug] = .connected
            } else if fromSession == .noAuthRequired {
                statuses[slug] = .noAuthRequired
            } else if !list.isEmpty {
                statuses[slug] = .pending
            } else if let fromSession {
                // The account list is authoritative; the session may still
                // point at an account that has since been removed.
                statuses[slug] = fetchedAccounts == nil ? fromSession : (fromSession == .connected ? .notConnected : fromSession)
            } else if fetchedAccounts != nil || sessionStatuses != nil {
                statuses[slug] = .notConnected
            } else {
                statuses[slug] = self.statuses[slug] ?? .unknown
            }
        }
        self.statuses = statuses
        lastError = errors.first
        errors.forEach { print("[Composio] refresh failed — \($0)") }

        await loadProfiles(reload: reloadProfiles, client: client)
    }

    private func loadProfiles(reload: Bool, client: KonComposioClient) async {
        let targets = accounts.values.joined().filter {
            $0.isActive && KonComposioClient.isGoogleToolkit($0.toolkitSlug) && (reload || profiles[$0.id] == nil)
        }
        guard !targets.isEmpty else { return }
        await withTaskGroup(of: (String, ComposioAccountProfile?).self) { group in
            for account in targets {
                group.addTask {
                    (account.id, await client.googleProfile(accountId: account.id, toolkit: account.toolkitSlug))
                }
            }
            for await (id, profile) in group {
                if let profile { profiles[id] = profile }
            }
        }
    }

    func profile(for account: ComposioConnectedAccount) -> ComposioAccountProfile? {
        profiles[account.id]
    }

    /// Returns the browser URL that finishes connecting `slug` to Composio.
    /// Calling it for an already connected toolkit adds another account.
    func connectURL(for slug: String, alias: String? = nil) async -> URL? {
        guard let client else { return nil }
        let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let session = try await ensureSession(client: client)
            return try await client.connectURL(sessionId: session.id, toolkit: slug, alias: alias)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func canAddAccount(to slug: String) -> Bool {
        (accounts[slug]?.count ?? 0) < KonComposioClient.maxAccountsPerToolkit
    }

    func renameAccount(_ account: ComposioConnectedAccount, to alias: String) async {
        let alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, alias != (account.alias ?? "") else { return }
        do {
            try await client.setAlias(alias, accountId: account.id)
            await refreshStatuses()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func removeAccount(_ account: ComposioConnectedAccount) async {
        guard let client else { return }
        do {
            try await client.deleteAccount(account.id)
            await refreshStatuses()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Tells Kon which accounts exist, so "仕事のメール" maps to the right
    /// `account` argument. Nil when no toolkit has more than one account.
    var accountsPromptSummary: String? {
        let lines = selectedToolkits.compactMap { slug -> String? in
            let active = accounts[slug]?.filter(\.isActive) ?? []
            guard active.count > 1 else { return nil }
            let name = toolkit(for: slug)?.name ?? slug
            let described = active.map { account in
                profiles[account.id]?.email.map { "\(account.handle)（\($0)）" } ?? account.handle
            }
            return "- \(name): \(described.joined(separator: "、"))"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
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
        // "multi": sessions created before multi-account support must be replaced.
        "\(userId)|multi|\(selectedToolkits.sorted().joined(separator: ","))"
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
