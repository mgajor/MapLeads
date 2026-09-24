import Foundation
import Security

// MARK: - Keychain token storage

enum KeychainError: LocalizedError {
    case unexpectedData
    case status(OSStatus, operation: String)

    var errorDescription: String? {
        switch self {
        case .unexpectedData:
            return "The stored Apify token is not valid UTF-8 text."
        case .status(let code, let operation):
            let message = SecCopyErrorMessageString(code, nil) as String? ?? "Unknown keychain error."
            return "Keychain \(operation) failed (OSStatus \(code)): \(message)"
        }
    }
}

/// Stores the Apify API token in the macOS Keychain.
/// Service `local.MapLeads`, account `apify`. Saving an empty string deletes the token.
enum KeychainToken {
    private static let service = "local.MapLeads"
    private static let account = "apify"

    /// Loads the stored token; returns an empty string when none is saved yet
    /// (normal on first launch, not an error).
    static func load() throws -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { return "" }
        guard status == errSecSuccess else {
            throw KeychainError.status(status, operation: "read")
        }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        return token
    }

    /// Saves the token, or deletes it when `token` is empty.
    static func save(_ token: String) throws {
        guard !token.isEmpty else {
            try delete()
            return
        }

        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = Data(token.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw KeychainError.status(status, operation: "save")
        }
    }

    /// Removes the token; succeeds when there is nothing stored.
    static func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status, operation: "delete")
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

// MARK: - Errors

enum ApifyError: LocalizedError {
    case missingToken
    case invalidID(kind: String, value: String)
    case http(status: Int, type: String?, message: String?)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "No Apify API token is configured. Add your token (Apify Console → Settings → Integrations) and try again."
        case .invalidID(let kind, let value):
            return "“\(value)” is not a valid Apify \(kind) ID; refusing to use it in a request path."
        case .http(let status, let type, let message):
            var text = "Apify request failed (HTTP \(status))"
            if let type, !type.isEmpty { text += ": \(type)" }
            if let message, !message.isEmpty { text += " — \(message)" }
            if status == 401 || status == 403 {
                text += " Check that your Apify API token is valid (Apify Console → Settings → Integrations)."
            }
            return text
        case .malformed(let detail):
            return "Could not read the Apify response: \(detail)"
        }
    }
}

// MARK: - Run model

struct ActorRun: Codable, Equatable {
    let id: String
    let status: String
    let defaultDatasetId: String
    let statusMessage: String?

    /// True once the run can no longer change state.
    var terminal: Bool {
        switch status.uppercased() {
        case "SUCCEEDED", "FAILED", "ABORTED", "TIMED-OUT":
            return true
        default:
            return false
        }
    }

    init(id: String, status: String, defaultDatasetId: String, statusMessage: String? = nil) {
        self.id = id
        self.status = status
        self.defaultDatasetId = defaultDatasetId
        self.statusMessage = statusMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        status = try container.decode(String.self, forKey: .status)
        defaultDatasetId = try container.decodeIfPresent(String.self, forKey: .defaultDatasetId) ?? ""
        statusMessage = try container.decodeIfPresent(String.self, forKey: .statusMessage)
    }

    static func == (lhs: ActorRun, rhs: ActorRun) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status
            && lhs.defaultDatasetId == rhs.defaultDatasetId
            && lhs.statusMessage == rhs.statusMessage
    }
}

// MARK: - Client

/// Native URLSession client for the `kaix~google-maps-places-scraper` Actor.
/// All requests authenticate with `Authorization: Bearer <token>`.
final class ApifyClient {
    private static let actorID = "kaix~google-maps-places-scraper"
    private static let baseURL = URL(string: "https://api.apify.com/v2")!
    private static let runTimeoutSeconds = 1800
    private static let pageSize = 500

    /// Run and dataset IDs used in request paths; must stay path-safe.
    private static let idPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{1,64}$")

    let token: String
    private let session: URLSession

    init(token: String) {
        self.token = token
        self.session = URLSession(configuration: .ephemeral)
    }

    // MARK: Actor run

    /// Starts a paid area-search run with a hard charge cap. Single attempt — never retried
    /// automatically, because each attempt can cost money.
    func start(
        query: String,
        location: String,
        radius: Double,
        maxResults: Int,
        mode: String,
        budget: Double
    ) async throws -> ActorRun {
        try requireToken()

        let url = endpoint(
            "actors/\(Self.actorID)/runs",
            query: [
                URLQueryItem(name: "maxTotalChargeUsd", value: String(format: "%.2f", budget)),
                URLQueryItem(name: "timeout", value: String(Self.runTimeoutSeconds)),
            ]
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RunInput(query: query, location: location, radius: radius, maxResults: maxResults, mode: mode)
        )

        return try await decodeRun(request)
    }

    /// Fetches the current state of a run. Does not wait; call repeatedly to poll.
    func getRun(_ id: String) async throws -> ActorRun {
        try requireToken()
        let runID = try validated(id, kind: "run")
        var request = URLRequest(url: endpoint("actor-runs/\(runID)"))
        request.httpMethod = "GET"
        return try await decodeRun(request)
    }

    /// Aborts a run. Succeeds when the abort was accepted; the run reaches
    /// `ABORTED` asynchronously.
    func abort(_ id: String) async throws {
        try requireToken()
        let runID = try validated(id, kind: "run")
        var request = URLRequest(url: endpoint("actor-runs/\(runID)/abort"))
        request.httpMethod = "POST"
        _ = try await send(request)
    }

    // MARK: Dataset

    /// Downloads every page of the dataset and parses the combined item array into leads.
    func results(_ datasetID: String) async throws -> [Lead] {
        try requireToken()
        let datasetID = try validated(datasetID, kind: "dataset")

        var items: [Any] = []
        var offset = 0
        while true {
            let url = endpoint(
                "datasets/\(datasetID)/items",
                query: [
                    URLQueryItem(name: "skipHidden", value: "true"),
                    URLQueryItem(name: "format", value: "json"),
                    URLQueryItem(name: "offset", value: String(offset)),
                    URLQueryItem(name: "limit", value: String(Self.pageSize)),
                ]
            )
            var request = URLRequest(url: url)
            request.httpMethod = "GET"

            let (data, response) = try await send(request)
            let page: [Any]
            do {
                guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
                    throw ApifyError.malformed("dataset page at offset \(offset) is not a JSON array")
                }
                page = array
            } catch let error as ApifyError {
                throw error
            } catch {
                throw ApifyError.malformed("dataset page at offset \(offset) is not valid JSON (\(error.localizedDescription))")
            }
            items.append(contentsOf: page)
            offset += page.count

            // Prefer the platform's total when present; otherwise stop on a short page.
            if let total = response.value(forHTTPHeaderField: "x-apify-pagination-total").flatMap(Int.init) {
                if offset >= total { break }
            } else if page.count < Self.pageSize {
                break
            }
            if page.isEmpty { break }
        }

        let combined: Data
        do {
            combined = try JSONSerialization.data(withJSONObject: items, options: [.withoutEscapingSlashes])
        } catch {
            throw ApifyError.malformed("could not reassemble dataset items (\(error.localizedDescription))")
        }
        return try Lead.parse(combined)
    }

    // MARK: Internals

    private struct RunInput: Encodable {
        let query: String
        let location: String
        let radius: Double
        let radiusUnit = "mi"
        let maxResults: Int
        let mode: String
        let searchType = "area"
    }

    private struct RunEnvelope: Decodable {
        let data: ActorRun
    }

    private struct APIErrorBody: Decodable {
        struct Payload: Decodable {
            let type: String?
            let message: String?
        }
        let error: Payload?
    }

    private func requireToken() throws {
        guard !token.isEmpty else { throw ApifyError.missingToken }
    }

    /// Rejects IDs that could alter the request path (injection guard).
    private func validated(_ id: String, kind: String) throws -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard !trimmed.isEmpty, Self.idPattern.firstMatch(in: trimmed, range: range) != nil else {
            throw ApifyError.invalidID(kind: kind, value: id)
        }
        return trimmed
    }

    private func endpoint(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty {
            components.queryItems = query
        }
        return components.url!
    }

    private func authorized(_ request: inout URLRequest) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        authorized(&request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ApifyError.malformed("network request failed (\(error.localizedDescription))")
        }
        guard let http = response as? HTTPURLResponse else {
            throw ApifyError.malformed("response was not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw apiError(status: http.statusCode, data: data)
        }
        return (data, http)
    }

    private func decodeRun(_ request: URLRequest) async throws -> ActorRun {
        let (data, _) = try await send(request)
        do {
            return try JSONDecoder().decode(RunEnvelope.self, from: data).data
        } catch {
            throw ApifyError.malformed("run object could not be decoded (\(error.localizedDescription))")
        }
    }

    private func apiError(status: Int, data: Data) -> ApifyError {
        let body = try? JSONDecoder().decode(APIErrorBody.self, from: data)
        return .http(status: status, type: body?.error?.type, message: body?.error?.message)
    }
}
