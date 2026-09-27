import Foundation

enum KonComposioError: Error, LocalizedError {
    case invalidResponse
    case api(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Composioの応答を解析できませんでした。"
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

/// Whether a toolkit in the session has a usable connected account.
enum ComposioConnectionStatus: Hashable {
    case connected
    case pending
    case notConnected
    case noAuthRequired
}

/// Thin wrapper over Composio REST API v3.1 (https://docs.composio.dev/reference).
/// Uses the session ("tool router") endpoints so Composio handles tool
/// discovery and auth; Kon only picks which toolkits are allowed.
struct KonComposioClient {
    static let baseURL = URL(string: "https://backend.composio.dev/api/v3.1")!

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
            var query = ["sort_by": "usage", "limit": "1000"]
            query["cursor"] = cursor
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
            "toolkits": toolkits.joined(separator: ","),
            "limit": "50"
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

    /// Starts an OAuth (or API key) connection; the returned URL is opened in the browser.
    func connectURL(sessionId: String, toolkit: String) async throws -> URL {
        struct Response: Decodable { let redirect_url: URL }
        let response: Response = try await request("POST", "tool_router/session/\(sessionId)/link", body: ["toolkit": toolkit])
        return response.redirect_url
    }

    // MARK: - HTTP

    private func request<T: Decodable>(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        body: [String: Any]? = nil
    ) async throws -> T {
        var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
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
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw KonComposioError.invalidResponse
        }
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
