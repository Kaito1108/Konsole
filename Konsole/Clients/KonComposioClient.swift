import Foundation

enum KonComposioError: Error, LocalizedError {
    case invalidResponse
    /// The body didn't match the expected shape; `detail` names the endpoint and field.
    case undecodable(detail: String)
    case api(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Composioの応答を解析できませんでした。"
        case .undecodable(let detail):
            return "Composioの応答を解析できませんでした（\(detail)）"
        case .api(let status, let message):
            return status == 401 ? "APIキーが正しくありません（\(message)）" : "Composioエラー \(status): \(message)"
        }
    }
}

/// An app Composio can connect to (Gmail, Google Calendar, Slack, ...).
struct ComposioToolkit: Identifiable, Hashable, Decodable {
    let slug: String
    let name: String
    let meta: Meta
    let noAuth: Bool?

    var id: String { slug }
    var logoURL: URL? { URL(string: meta.logo) }
    var summary: String { meta.description }

    struct Meta: Hashable, Decodable {
        let logo: String
        let description: String
    }

    enum CodingKeys: String, CodingKey {
        case slug, name, meta
        case noAuth = "no_auth"
    }
}

/// A Composio session scoped to the toolkits Kon may use. Its MCP endpoint is
/// what gets handed to the claude CLI.
struct ComposioSession: Codable, Hashable {
    let id: String
    let mcpURL: URL
}

/// One account connected to a toolkit (e.g. a work and a personal Gmail).
struct ComposioConnectedAccount: Identifiable, Hashable, Decodable {
    let id: String
    let toolkit: Toolkit?
    let alias: String?
    /// Composio's short auto-generated handle, used when there's no alias.
    let wordId: String?
    let status: String
    let isDisabled: Bool?
    let createdAt: String?

    struct Toolkit: Hashable, Decodable {
        let slug: String
    }

    init(from decoder: Decoder) throws {
        // Only the id is essential; the real API leaves fields out or null
        // more often than its spec admits, and one odd account must not hide
        // all the others.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        toolkit = try? container.decodeIfPresent(Toolkit.self, forKey: .toolkit)
        alias = try? container.decodeIfPresent(String.self, forKey: .alias)
        wordId = try? container.decodeIfPresent(String.self, forKey: .wordId)
        status = (try? container.decodeIfPresent(String.self, forKey: .status)) ?? "ACTIVE"
        isDisabled = try? container.decodeIfPresent(Bool.self, forKey: .isDisabled)
        createdAt = try? container.decodeIfPresent(String.self, forKey: .createdAt)
    }

    var toolkitSlug: String { toolkit?.slug.lowercased() ?? "" }
    var isActive: Bool { status.uppercased() == "ACTIVE" && isDisabled != true }
    /// What Kon and the user call this account; also accepted as the `account`
    /// argument when executing a tool.
    var handle: String {
        if let alias, !alias.isEmpty { return alias }
        if let wordId, !wordId.isEmpty { return wordId }
        return id
    }

    enum CodingKeys: String, CodingKey {
        case id, toolkit, alias, status
        case wordId = "word_id"
        case isDisabled = "is_disabled"
        case createdAt = "created_at"
    }
}

/// Who a connected account belongs to. Composio doesn't store this, so it's
/// looked up from the service itself (Google: name, address and photo).
struct ComposioAccountProfile: Codable, Hashable {
    var name: String?
    var email: String?
    var pictureURL: URL?

    var isEmpty: Bool { name == nil && email == nil && pictureURL == nil }
}

/// Whether a toolkit in the session has a usable connected account.
enum ComposioConnectionStatus: Hashable {
    case connected
    case pending
    case notConnected
    case noAuthRequired
    /// Every status request failed; the reason is in the store's `lastError`.
    case unknown
}

/// Thin wrapper over Composio REST API v3.1 (https://docs.composio.dev/reference).
/// Uses the session ("tool router") endpoints so Composio handles tool
/// discovery and auth; Kon only picks which toolkits are allowed.
struct KonComposioClient {
    static let baseURL = URL(string: "https://backend.composio.dev/api/v3.1")!
    static let maxAccountsPerToolkit = 5

    let apiKey: String

    /// Every toolkit, popular first. Follows the cursor since a page caps at 1000.
    func listToolkits() async throws -> [ComposioToolkit] {
        struct Page: Decodable {
            let items: [ComposioToolkit]
            let next_cursor: String?
        }
        var toolkits: [ComposioToolkit] = []
        var cursor: String?
        repeat {
            var query = [URLQueryItem(name: "sort_by", value: "usage"), URLQueryItem(name: "limit", value: "1000")]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page: Page = try await request("GET", "toolkits", query: query)
            toolkits += page.items
            cursor = page.next_cursor.flatMap { $0.isEmpty ? nil : $0 }
        } while cursor != nil && toolkits.count < 20_000
        return toolkits
    }

    func createSession(userId: String, toolkits: [String]) async throws -> ComposioSession {
        struct Response: Decodable {
            struct MCP: Decodable { let url: URL }
            let session_id: String
            let mcp: MCP
        }
        let body: [String: Any] = [
            "user_id": userId,
            "toolkits": ["enable": toolkits],
            // Kon already runs code locally through Claude Code; the remote
            // sandbox would only add tools and latency.
            "workbench": ["enable": false],
            // Lets one toolkit hold several accounts (work + personal Gmail).
            // Kon is told to name the account (by alias) whenever there are several.
            "multi_account": ["enable": true, "max_accounts_per_toolkit": Self.maxAccountsPerToolkit],
            "experimental": [
                "assistive_prompt_config": ["user_timezone": TimeZone.current.identifier]
            ]
        ]
        let response: Response = try await request("POST", "tool_router/session", body: body)
        return ComposioSession(id: response.session_id, mcpURL: response.mcp.url)
    }

    func connectionStatuses(sessionId: String, toolkits: [String]) async throws -> [String: ComposioConnectionStatus] {
        struct Page: Decodable {
            struct Item: Decodable {
                struct Account: Decodable { let status: String? }
                let slug: String
                let is_no_auth: Bool
                let connected_account: Account?
            }
            let items: [Item]
        }
        let page: Page = try await request("GET", "tool_router/session/\(sessionId)/toolkits", query: [
            URLQueryItem(name: "toolkits", value: toolkits.joined(separator: ",")),
            URLQueryItem(name: "limit", value: "50")
        ])
        var statuses: [String: ComposioConnectionStatus] = [:]
        for item in page.items {
            if item.is_no_auth {
                statuses[item.slug] = .noAuthRequired
            } else if let account = item.connected_account {
                let status = account.status?.uppercased() ?? "ACTIVE"
                statuses[item.slug] = status == "ACTIVE" ? .connected : .pending
            } else {
                statuses[item.slug] = .notConnected
            }
        }
        return statuses
    }

    /// Starts an OAuth (or API key) connection; the returned URL is opened in the
    /// browser. Each call creates a new connected account, so calling it again
    /// for a connected toolkit adds a second account.
    func connectURL(sessionId: String, toolkit: String, alias: String?) async throws -> URL {
        struct Response: Decodable { let redirect_url: URL }
        var body: [String: Any] = ["toolkit": toolkit]
        if let alias, !alias.isEmpty { body["alias"] = alias }
        let response: Response = try await request("POST", "tool_router/session/\(sessionId)/link", body: body)
        return response.redirect_url
    }

    /// Every account `userId` has connected to `toolkits`, oldest first.
    func connectedAccounts(userId: String, toolkits: [String]) async throws -> [ComposioConnectedAccount] {
        struct Page: Decodable {
            let items: [Lenient<ComposioConnectedAccount>]
            let next_cursor: String?
        }
        var accounts: [ComposioConnectedAccount] = []
        var cursor: String?
        repeat {
            var query = [
                URLQueryItem(name: "user_ids", value: userId),
                URLQueryItem(name: "order_by", value: "created_at"),
                URLQueryItem(name: "order_direction", value: "asc"),
                URLQueryItem(name: "limit", value: "100")
            ]
            query += toolkits.map { URLQueryItem(name: "toolkit_slugs", value: $0) }
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page: Page = try await request("GET", "connected_accounts", query: query)
            accounts += page.items.compactMap(\.value)
            // Guard against a cursor that never runs out.
            let next = page.next_cursor.flatMap { $0.isEmpty ? nil : $0 }
            cursor = (page.items.isEmpty || next == cursor) ? nil : next
        } while cursor != nil && accounts.count < 1000
        return accounts
    }

    func setAlias(_ alias: String, accountId: String) async throws {
        let _: EmptyResponse = try await request("PATCH", "connected_accounts/\(accountId)", body: ["alias": alias])
    }

    func deleteAccount(_ accountId: String) async throws {
        let _: EmptyResponse = try await request("DELETE", "connected_accounts/\(accountId)")
    }

    /// Toolkits backed by a Google account, whose owner can be looked up.
    static func isGoogleToolkit(_ slug: String) -> Bool {
        slug == "gmail" || slug == "youtube" || slug.hasPrefix("google")
    }

    /// Name, address and photo of the Google account behind `accountId`,
    /// fetched through Composio's proxy with that account's own token. Tries
    /// the most complete sources first and falls back to whatever the granted
    /// scopes allow (Gmail and Calendar always reveal at least the address).
    func googleProfile(accountId: String, toolkit: String) async -> ComposioAccountProfile? {
        var profile = ComposioAccountProfile()

        if let info = try? await proxyGET(accountId: accountId, url: "https://www.googleapis.com/oauth2/v3/userinfo") {
            profile.name = Self.nonEmpty(info["name"])
            profile.email = Self.nonEmpty(info["email"])
            profile.pictureURL = Self.nonEmpty(info["picture"]).flatMap(URL.init(string:))
        }
        if profile.name == nil || profile.pictureURL == nil,
           let person = try? await proxyGET(accountId: accountId, url: "https://people.googleapis.com/v1/people/me?personFields=names,photos,emailAddresses") {
            func first(_ key: String, _ field: String) -> String? {
                ((person[key] as? [[String: Any]])?.first?[field]).flatMap(Self.nonEmpty)
            }
            profile.name = profile.name ?? first("names", "displayName")
            profile.email = profile.email ?? first("emailAddresses", "value")
            profile.pictureURL = profile.pictureURL ?? first("photos", "url").flatMap(URL.init(string:))
        }
        if profile.email == nil {
            switch toolkit {
            case "gmail":
                let gmail = try? await proxyGET(accountId: accountId, url: "https://gmail.googleapis.com/gmail/v1/users/me/profile")
                profile.email = gmail.flatMap { Self.nonEmpty($0["emailAddress"]) }
            case "googlecalendar":
                // The primary calendar's id is the account's address.
                let calendar = try? await proxyGET(accountId: accountId, url: "https://www.googleapis.com/calendar/v3/calendars/primary")
                profile.email = calendar.flatMap { Self.nonEmpty($0["id"]) }
            default:
                break
            }
        }
        return profile.isEmpty ? nil : profile
    }

    /// GET through Composio's proxy, authenticated as the connected account.
    /// Returns the upstream JSON object, or throws if upstream didn't answer 2xx.
    private func proxyGET(accountId: String, url: String) async throws -> [String: Any] {
        let data = try await requestData("POST", "tools/execute/proxy", body: [
            "connected_account_id": accountId,
            "endpoint": url,
            "method": "GET"
        ])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? Int, (200..<300).contains(status),
              let upstream = json["data"] as? [String: Any] else {
            throw KonComposioError.invalidResponse
        }
        return upstream
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    /// Decodes an element, or yields nil instead of failing the whole array.
    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    /// For endpoints whose response body Kon doesn't need.
    private struct EmptyResponse: Decodable {}

    // MARK: - HTTP

    private func request<T: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: [String: Any]? = nil
    ) async throws -> T {
        let data = try await requestData(method, path, query: query, body: body)
        if T.self == EmptyResponse.self, let empty = EmptyResponse() as? T {
            return empty
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let detail = "\(method) \(path): \(Self.describe(error))"
            print("[Composio] decode failed — \(detail)\n\(String(data: data.prefix(2000), encoding: .utf8) ?? "")")
            throw KonComposioError.undecodable(detail: detail)
        }
    }

    private static func describe(_ error: Error) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        switch error as? DecodingError {
        case .keyNotFound(let key, let context):
            return "\(path(context)).\(key.stringValue) がありません"
        case .valueNotFound(_, let context):
            return "\(path(context)) がnullです"
        case .typeMismatch(_, let context):
            return "\(path(context)) の型が違います"
        case .dataCorrupted(let context):
            return "\(path(context)) が壊れています"
        default:
            return error.localizedDescription
        }
    }

    private func requestData(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: [String: Any]? = nil
    ) async throws -> Data {
        var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 20
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KonComposioError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw KonComposioError.api(status: http.statusCode, message: Self.errorMessage(from: data))
        }
        return data
    }

    private static func errorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8)?.prefix(200).description ?? "unknown error"
    }
}
