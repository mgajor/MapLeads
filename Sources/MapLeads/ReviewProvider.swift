import Foundation

// MARK: - Result models

/// Outcome of one completed Google-reviews check against DataForSEO.
///
/// `latestReview` is the publication date of the newest review retrieved.
/// It is asserted only when the completed task is confirmed to have been run
/// newest-first AND every retrieved item carried a readable, non-future
/// date; otherwise it is `nil` (unknown) or the call threw. `reviewCount`
/// is the total Google reports for the listing; it is `nil` unless Google
/// reported a count, so an empty batch is never mistaken for "zero reviews".
struct ReviewCheck: Codable {
    var checkedAt: Date
    var latestReview: Date?
    var reviewCount: Int?
    var evidence: String
}

/// A reviews task submitted to DataForSEO. Persist `id` right away and poll
/// `DataForSEOClient.result(_:)`; tasks are never resubmitted automatically.
struct ReviewTask: Codable {
    var id: String
}

// MARK: - Errors

enum DataForSEOError: LocalizedError {
    case missingCredentials
    case missingIdentity
    case missingLocation(unsupportedCountry: String?)
    case invalidTaskID(String)
    case http(status: Int, body: String?)
    case api(code: Int, message: String?)
    case identityMismatch(field: String, requested: String, returned: String)
    case notOrderedByNewest
    case unreadableTimestamp(item: Int, raw: String?)
    case futureTimestamp(item: Int, date: Date)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "No DataForSEO API login or password is configured. Add both in Settings before checking reviews."
        case .missingIdentity:
            return "This lead has no Google place ID or CID in its saved listing data, so its reviews cannot be checked without risking a mismatch. Re-import the lead from a Google Maps search so its place ID is saved, then try again."
        case .missingLocation(let unsupportedCountry):
            if let unsupportedCountry {
                return "This lead has no saved coordinates, and there is no known DataForSEO location for country code \(unsupportedCountry). Re-import the lead so its latitude and longitude are saved, then try again."
            }
            return "This lead has no saved coordinates or country code, and DataForSEO requires a location for every reviews task. Re-import the lead so its location is saved, then try again."
        case .invalidTaskID(let value):
            return "“\(value)” is not a valid DataForSEO task ID; refusing to use it in a request path."
        case .http(let status, let body):
            var text = "DataForSEO request failed (HTTP \(status))."
            if let body, !body.isEmpty { text += " \(body)" }
            switch status {
            case 401:
                text += " Check that the DataForSEO API login and password in Settings are correct."
            case 402:
                text += " The DataForSEO account could not be billed; check its balance."
            case 300..<400:
                text += " The API tried to redirect away from api.dataforseo.com, so the request was stopped to protect your credentials."
            default:
                break
            }
            return text
        case .api(let code, let message):
            var text = "DataForSEO returned error \(code)"
            if let message, !message.isEmpty { text += " — \(message)" }
            text += "."
            if let hint = DataForSEOError.hint(for: code) { text += " \(hint)" }
            return text
        case .identityMismatch(let field, let requested, let returned):
            return "DataForSEO returned reviews for a different Google listing (\(field) “\(returned)” instead of “\(requested)”). The result was discarded. Start a new check for this lead."
        case .notOrderedByNewest:
            return "The saved task's results were not confirmed to be sorted newest-first, so no latest-review date can be trusted from them. Start a new check for this lead."
        case .unreadableTimestamp(let item, let raw):
            var text = "Review \(item)'s publication date could not be read"
            if let raw, !raw.isEmpty { text += " (received “\(raw)”)" }
            text += ". The result was discarded rather than risk misjudging the latest review. Start a new check for this lead."
            return text
        case .futureTimestamp(let item, let date):
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .none
            return "Review \(item) is dated \(display.string(from: date)), in the future, which the reviews API should never return. The result was discarded. Start a new check for this lead."
        case .malformed(let detail):
            return "Could not read the DataForSEO response: \(detail)"
        }
    }

    private static func hint(for code: Int) -> String? {
        switch code {
        case 40100:
            return "Check that the DataForSEO API login and password in Settings are correct."
        case 40102:
            return "No Google reviews were found for this listing; verify it on Google Maps."
        case 40103:
            return "The task could not be executed. Start a new check to try again; failed tasks are never resubmitted automatically."
        case 40200, 40210:
            return "The DataForSEO account balance is too low; top it up before checking reviews."
        case 40201, 40203, 40204:
            return "The DataForSEO account's access is currently restricted; see its dashboard for details."
        case 40202:
            return "The DataForSEO rate limit was hit; wait a minute before checking more leads."
        case 40205, 40206:
            return "The DataForSEO duplicate-task limit was hit; wait before checking this lead again."
        case 40401:
            return "The saved task ID is not known to DataForSEO; start a new check for this lead."
        case 40403:
            return "The task's results expired (DataForSEO keeps them for 30 days); start a new check."
        case 40505:
            return "The location parameters were rejected as outdated; re-import the lead with coordinates."
        default:
            return nil
        }
    }
}

// MARK: - Client

/// Native URLSession client for the DataForSEO Google Reviews API
/// (`business_data/google/reviews/task_post` + `task_get`), authenticated with
/// HTTP Basic using the API login and password.
///
/// One `start` call submits exactly one billable task and returns its ID;
/// nothing here retries or resubmits. Poll `result` — it returns `nil` while
/// the task is still in flight — and persist whatever comes back.
final class DataForSEOClient {
    private static let baseURL = URL(string: "https://api.dataforseo.com/v3/business_data/google/reviews")!

    /// Envelope and task statuses meaning the request itself succeeded
    /// (20000 "ok", 20100 "task created").
    private static let okStatusCodes: Set<Int> = [20000, 20100]
    /// The documented in-flight statuses — the only cases where `result`
    /// returns `nil` (40601 "task handed", 40602 "task in queue").
    private static let pendingStatusCodes: Set<Int> = [40601, 40602]

    private static let depth = 10
    /// Docs: the `location_coordinate` radius must be at least 199.9.
    private static let coordinateRadius = 200

    /// DataForSEO task IDs are UUID-shaped; anything that could alter the
    /// request path is rejected.
    private static let taskIDPattern = try! NSRegularExpression(pattern: "^[0-9A-Fa-f-]{8,64}$")

    /// Country-level location codes for the business_data Google API,
    /// verified against DataForSEO's published locations CSV
    /// (locations_business_data_google_2026_09_01.csv: code = ISO 3166-1
    /// numeric + 2000, e.g. US 2840 as in the API docs). Saved coordinates
    /// are always preferred; this table is only the fallback.
    private static let countryLocationCodes: [String: Int] = [
        "AE": 2784, "AR": 2032, "AT": 2040, "AU": 2036, "BD": 2050, "BE": 2056,
        "BG": 2100, "BH": 2048, "BR": 2076, "CA": 2124, "CH": 2756, "CL": 2152,
        "CN": 2156, "CO": 2170, "CZ": 2203, "DE": 2276, "DK": 2208, "EG": 2818,
        "ES": 2724, "FI": 2246, "FR": 2250, "GB": 2826, "GR": 2300, "HK": 2344,
        "HR": 2191, "HU": 2348, "ID": 2360, "IE": 2372, "IL": 2376, "IN": 2356,
        "IT": 2380, "JP": 2392, "KE": 2404, "KR": 2410, "KW": 2414, "LK": 2144,
        "MA": 2504, "MX": 2484, "MY": 2458, "NG": 2566, "NL": 2528, "NO": 2578,
        "NZ": 2554, "OM": 2512, "PE": 2604, "PH": 2608, "PK": 2586, "PL": 2616,
        "PT": 2620, "QA": 2634, "RO": 2642, "SA": 2682, "SE": 2752, "SG": 2702,
        "SK": 2703, "TH": 2764, "TR": 2792, "TW": 2158, "US": 2840, "UY": 2858,
        "VN": 2704, "ZA": 2710,
    ]

    private let login: String
    private let password: String
    private let session: URLSession

    init(login: String, password: String, session: URLSession = .shared) {
        self.login = login
        self.password = password
        self.session = session
    }

    // MARK: Task lifecycle

    /// Submits one reviews task for the lead and returns its ID. Single
    /// attempt: every accepted task is billed, so nothing here retries or
    /// resubmits.
    ///
    /// Identity comes from the saved listing — place ID first, then CID,
    /// never the business name alone. Location comes from the saved
    /// coordinates, or from the listing's country code when coordinates are
    /// missing.
    func start(_ lead: Lead) async throws -> ReviewTask {
        try requireCredentials()

        let object = Self.jsonObject(from: lead.rawJSON) ?? [:]

        var placeID = Self.field(object, keys: ["placeId", "place_id", "googleId"])
        let cid = Self.field(object, keys: ["cid", "googleCid", "google_cid"])
        // A lead whose ID is not a "local-" content hash is the place ID
        // itself (see Lead parsing), so it is a valid last resort.
        if placeID == nil, cid == nil, let savedID = lead.id.trimmedNonEmpty, !savedID.hasPrefix("local-") {
            placeID = savedID
        }
        guard placeID != nil || cid != nil else { throw DataForSEOError.missingIdentity }

        var locationCode: Int?
        var locationCoordinate: String?
        if let coordinate = Self.locationCoordinate(for: object) {
            locationCoordinate = coordinate
        } else if let code = Self.locationCode(for: object) {
            locationCode = code
        } else {
            throw DataForSEOError.missingLocation(
                unsupportedCountry: Self.field(object, keys: ["countryCode", "country_code"])?.uppercased()
            )
        }

        var request = URLRequest(url: Self.baseURL.appendingPathComponent("task_post"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            TaskBody(
                placeID: placeID,
                cid: cid,
                locationCode: locationCode,
                locationCoordinate: locationCoordinate,
                languageCode: "en",
                depth: Self.depth,
                sortBy: "newest",
                priority: 1
            ),
        ])

        let data = try await send(request)

        let envelope: Envelope<PostTask>
        do {
            envelope = try JSONDecoder().decode(Envelope<PostTask>.self, from: data)
        } catch {
            throw DataForSEOError.malformed("task_post response could not be decoded (\(error.localizedDescription))")
        }

        // Check the envelope AND the task's own status before trusting the ID.
        guard Self.okStatusCodes.contains(envelope.statusCode) else {
            throw DataForSEOError.api(code: envelope.statusCode, message: envelope.statusMessage.map(redacted))
        }
        guard let task = envelope.tasks?.first else {
            throw DataForSEOError.malformed("task_post response contained no task")
        }
        guard let taskStatus = task.statusCode else {
            throw DataForSEOError.malformed("task_post response did not include a task status")
        }
        guard Self.okStatusCodes.contains(taskStatus) else {
            throw DataForSEOError.api(code: taskStatus, message: task.statusMessage.map(redacted))
        }
        guard let id = task.id?.trimmedNonEmpty else {
            throw DataForSEOError.malformed("task_post response did not include a task ID")
        }
        return ReviewTask(id: id)
    }

    /// Fetches the outcome of a submitted task.
    ///
    /// - Returns `nil` while DataForSEO still has the task in flight (the
    ///   documented "task handed" / "task in queue" statuses); poll again.
    /// - Returns the check once the task completed.
    /// - Throws for every real error: bad credentials, billing problems,
    ///   unknown or expired tasks, no matching reviews, a listing mismatch,
    ///   results not confirmed newest-first, or any review item whose date
    ///   is unreadable or in the future. Nothing is resubmitted.
    func result(_ taskID: String) async throws -> ReviewCheck? {
        try requireCredentials()
        let id = try validated(taskID)

        var request = URLRequest(
            url: Self.baseURL.appendingPathComponent("task_get").appendingPathComponent(id)
        )
        request.httpMethod = "GET"

        let data = try await send(request)

        let envelope: Envelope<GetTask>
        do {
            envelope = try JSONDecoder().decode(Envelope<GetTask>.self, from: data)
        } catch {
            throw DataForSEOError.malformed("task_get response could not be decoded (\(error.localizedDescription))")
        }

        if Self.pendingStatusCodes.contains(envelope.statusCode) { return nil }
        guard envelope.statusCode == 20000 else {
            throw DataForSEOError.api(code: envelope.statusCode, message: envelope.statusMessage.map(redacted))
        }
        guard let task = envelope.tasks?.first else {
            throw DataForSEOError.malformed("task_get response contained no task")
        }
        guard let taskStatus = task.statusCode else {
            throw DataForSEOError.malformed("task_get response did not include a task status")
        }
        if Self.pendingStatusCodes.contains(taskStatus) { return nil }
        guard taskStatus == 20000 else {
            throw DataForSEOError.api(code: taskStatus, message: task.statusMessage.map(redacted))
        }
        guard let result = task.result?.first else {
            throw DataForSEOError.malformed("completed task returned no results")
        }

        // Never save reviews that belong to a different listing.
        let identity = try Self.identityVerification(echoed: task.data, result: result)

        // Dates come from review items only — owner replies
        // (`owner_timestamp`) are deliberately not even decoded.
        //
        // The latest-review date is asserted only when the task's own echoed
        // parameters prove the items are sorted newest-first; with that
        // proof the FIRST item is the newest. Without it no ordering is
        // assumed — no max fallback, no guess: the date stays unknown.
        let orderedByNewest = task.data?.sortBy?.value?.trimmedNonEmpty == "newest"
        let items = result.items ?? []
        var latest: Date? = nil
        if orderedByNewest {
            if items.isEmpty {
                latest = nil
            } else {
                let dates = try Self.reviewDates(from: items)
                latest = dates.first
            }
        }
        let retrieved = items.count

        return ReviewCheck(
            checkedAt: Date(),
            latestReview: latest,
            reviewCount: result.reviewsCount,
            evidence: Self.evidence(
                for: result,
                latest: latest,
                retrieved: retrieved,
                orderedByNewest: orderedByNewest,
                identity: identity
            )
        )
    }

    // MARK: Listing field extraction

    private static func jsonObject(from rawJSON: String) -> [String: Any]? {
        guard let data = rawJSON.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// First present, non-null value among `keys`, trimmed. Numbers are
    /// accepted too (CIDs arrive both as strings and as numbers).
    private static func field(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key], !(value is NSNull) else { continue }
            if let string = value as? String, let trimmed = string.trimmedNonEmpty { return trimmed }
            if let number = value as? NSNumber, let trimmed = number.stringValue.trimmedNonEmpty { return trimmed }
        }
        return nil
    }

    private static func number(_ object: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            guard let value = object[key], !(value is NSNull) else { continue }
            if let number = value as? NSNumber { return number.doubleValue }
            if let string = value as? String,
               let double = Double(string.trimmingCharacters(in: .whitespaces)) {
                return double
            }
        }
        return nil
    }

    /// `"latitude,longitude,radius"` per the docs, with at most 7 decimal
    /// digits and the documented minimum radius. Returns nil unless both
    /// saved coordinates are present and in range.
    private static func locationCoordinate(for object: [String: Any]) -> String? {
        let nested = (object["location"] as? [String: Any])
            ?? (object["coordinates"] as? [String: Any])
        let latitude = number(object, keys: ["latitude", "lat"])
            ?? nested.flatMap { number($0, keys: ["latitude", "lat"]) }
        let longitude = number(object, keys: ["longitude", "lng", "long"])
            ?? nested.flatMap { number($0, keys: ["longitude", "lng", "long"]) }
        guard let latitude, let longitude,
              latitude.isFinite, longitude.isFinite,
              (-90.0...90.0).contains(latitude),
              (-180.0...180.0).contains(longitude)
        else { return nil }
        return String(format: "%.7f,%.7f,\(coordinateRadius)", latitude, longitude)
    }

    /// Country-level DataForSEO location code for the listing's ISO
    /// alpha-2 country code, when the table covers it.
    private static func locationCode(for object: [String: Any]) -> Int? {
        guard let code = field(object, keys: ["countryCode", "country_code"])?.uppercased() else { return nil }
        return countryLocationCodes[code]
    }

    // MARK: Result shaping

    /// How the completed result's listing identity relates to the one that
    /// was asked about. A mismatch always throws; "confirmed" requires the
    /// response to carry the SAME identifier back, not merely that one was
    /// requested.
    private enum IdentityVerification {
        case confirmedPlaceID
        case confirmedCID
        case unverified
    }

    private static func identityVerification(
        echoed: EchoedRequest?,
        result: ReviewsResult
    ) throws -> IdentityVerification {
        if let requested = echoed?.placeID?.value?.trimmedNonEmpty,
           let returned = result.placeID?.value?.trimmedNonEmpty {
            guard requested == returned else {
                throw DataForSEOError.identityMismatch(field: "place ID", requested: requested, returned: returned)
            }
            return .confirmedPlaceID
        }
        if let requested = echoed?.cid?.value?.trimmedNonEmpty,
           let returned = result.cid?.value?.trimmedNonEmpty {
            guard requested == returned else {
                throw DataForSEOError.identityMismatch(field: "CID", requested: requested, returned: returned)
            }
            return .confirmedCID
        }
        return .unverified
    }

    /// Parses the publication timestamp of every retrieved review item.
    /// All of them must parse — with newest-first ordering a single
    /// unreadable date (the newest one, say) would silently turn a stale
    /// maximum into a false "latest". Any unreadable or future date is an
    /// error, never a guess.
    private static func reviewDates(from items: [ReviewItem]) throws -> [Date] {
        let parsers = Self.timestampParsers()
        let now = Date()
        return try items.enumerated().map { index, item in
            guard let raw = item.timestamp?.trimmedNonEmpty else {
                throw DataForSEOError.unreadableTimestamp(item: index + 1, raw: nil)
            }
            for parser in parsers {
                if let date = parser.date(from: raw) {
                    guard date <= now else {
                        throw DataForSEOError.futureTimestamp(item: index + 1, date: date)
                    }
                    return date
                }
            }
            throw DataForSEOError.unreadableTimestamp(item: index + 1, raw: raw)
        }
    }

    /// Parsers for the documented timestamp format
    /// ("2019-11-15 12:57:46 +00:00"), plus the same format without the
    /// offset's colon or without an offset at all. Built once per call and
    /// reused across the batch.
    private static func timestampParsers() -> [DateFormatter] {
        ["yyyy-MM-dd HH:mm:ss XXX", "yyyy-MM-dd HH:mm:ss XX", "yyyy-MM-dd HH:mm:ss"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = format
            return formatter
        }
    }

    private static func evidence(
        for result: ReviewsResult,
        latest: Date?,
        retrieved: Int,
        orderedByNewest: Bool,
        identity: IdentityVerification
    ) -> String {
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .none

        let who = result.title?.trimmedNonEmpty ?? "the listing"
        var sentences: [String] = []

        if let count = result.reviewsCount {
            sentences.append(count == 1
                ? "Google reports 1 review for \(who)."
                : "Google reports \(count) reviews for \(who).")
        } else {
            sentences.append("Google did not report a total review count for \(who).")
        }

        if let latest {
            sentences.append("Newest review (first of \(retrieved) retrieved, sorted newest-first) was left on \(display.string(from: latest)).")
        } else if !orderedByNewest {
            sentences.append("The task's results could not be confirmed as sorted newest-first, so the latest review date is unknown.")
        } else if retrieved > 0 {
            sentences.append("\(retrieved) reviews were retrieved, so the latest review date is unknown.")
        } else if result.reviewsCount == nil {
            // An explicit zero already says everything; absence says nothing.
            sentences.append("No review items were returned, so the latest review date is unknown.")
        }

        switch identity {
        case .confirmedPlaceID:
            sentences.append("Listing identity confirmed by matching place ID.")
        case .confirmedCID:
            sentences.append("Listing identity confirmed by matching CID.")
        case .unverified:
            sentences.append("Listing identity could not be confirmed from the response.")
        }

        return sentences.joined(separator: " ")
    }

    // MARK: Request plumbing

    private func requireCredentials() throws {
        guard login.trimmedNonEmpty != nil, password.trimmedNonEmpty != nil else {
            throw DataForSEOError.missingCredentials
        }
    }

    /// Rejects task IDs that could alter the request path (injection guard).
    private func validated(_ id: String) throws -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard !trimmed.isEmpty, Self.taskIDPattern.firstMatch(in: trimmed, range: range) != nil else {
            throw DataForSEOError.invalidTaskID(id)
        }
        return trimmed
    }

    private func authorized(_ request: inout URLRequest) {
        let credentials = Data("\(login):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    /// Strips the login, password, and Basic token from any text before it
    /// reaches an error message.
    private func redacted(_ text: String) -> String {
        var redacted = text
        for secret in [login, password, Data("\(login):\(password)".utf8).base64EncodedString()]
        where !secret.isEmpty {
            redacted = redacted.replacingOccurrences(of: secret, with: "[redacted]")
        }
        return String(redacted.prefix(300))
    }

    private func send(_ request: URLRequest) async throws -> Data {
        var request = request
        authorized(&request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: RedirectGuard(url: request.url))
        } catch {
            throw DataForSEOError.malformed("network request failed (\(error.localizedDescription))")
        }
        guard let http = response as? HTTPURLResponse else {
            throw DataForSEOError.malformed("response was not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            // Prefer the API's own code and message when the body carries them.
            if let envelope = try? JSONDecoder().decode(Envelope<PostTask>.self, from: data),
               !Self.okStatusCodes.contains(envelope.statusCode) {
                throw DataForSEOError.api(code: envelope.statusCode, message: envelope.statusMessage.map(redacted))
            }
            let body = String(data: data, encoding: .utf8).map { redacted($0) }
            throw DataForSEOError.http(status: http.statusCode, body: body)
        }
        return data
    }

    /// Keeps the HTTP Basic credentials on api.dataforseo.com: a cross-origin
    /// redirect is cancelled (the redirect response then surfaces as an
    /// error) while same-origin redirects proceed normally.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        private let host: String

        init(url: URL?) {
            host = url?.host?.lowercased() ?? ""
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            if let newHost = request.url?.host?.lowercased(), !newHost.isEmpty, newHost == host {
                completionHandler(request)
            } else {
                completionHandler(nil)
            }
        }
    }

    // MARK: Wire types

    private struct TaskBody: Encodable {
        var placeID: String?
        var cid: String?
        var locationCode: Int?
        var locationCoordinate: String?
        var languageCode: String?
        var depth: Int
        var sortBy: String
        var priority: Int

        enum CodingKeys: String, CodingKey {
            case placeID = "place_id", cid
            case locationCode = "location_code", locationCoordinate = "location_coordinate"
            case languageCode = "language_code"
            case depth, sortBy = "sort_by", priority
        }
    }

    private struct Envelope<Task: Decodable>: Decodable {
        let statusCode: Int
        let statusMessage: String?
        let tasks: [Task]?

        enum CodingKeys: String, CodingKey {
            case statusCode = "status_code", statusMessage = "status_message", tasks
        }
    }

    private struct PostTask: Decodable {
        let id: String?
        let statusCode: Int?
        let statusMessage: String?

        enum CodingKeys: String, CodingKey {
            case id
            case statusCode = "status_code", statusMessage = "status_message"
        }
    }

    private struct GetTask: Decodable {
        let statusCode: Int?
        let statusMessage: String?
        let data: EchoedRequest?
        let result: [ReviewsResult]?

        enum CodingKeys: String, CodingKey {
            case data, result
            case statusCode = "status_code", statusMessage = "status_message"
        }
    }

    /// The task parameters echoed back by task_get, used to confirm the
    /// result belongs to the listing that was asked about and that the items
    /// are sorted newest-first.
    private struct EchoedRequest: Decodable {
        let placeID: LenientString?
        let cid: LenientString?
        let sortBy: LenientString?

        enum CodingKeys: String, CodingKey {
            case placeID = "place_id", cid
            case sortBy = "sort_by"
        }
    }

    private struct ReviewsResult: Decodable {
        let title: String?
        let placeID: LenientString?
        let cid: LenientString?
        /// The total number of reviews Google reports — the only source for
        /// `reviewCount`; nil stays unknown rather than zero.
        let reviewsCount: Int?
        let itemsCount: Int?
        let items: [ReviewItem]?

        enum CodingKeys: String, CodingKey {
            case title
            case placeID = "place_id", cid
            case reviewsCount = "reviews_count", itemsCount = "items_count", items
        }
    }

    private struct ReviewItem: Decodable {
        /// Publication date of the review itself. Owner replies live in
        /// `owner_timestamp`, which is deliberately not decoded.
        let timestamp: String?
    }

    /// A JSON string or number read as its string form; `value` is nil for
    /// JSON null. CIDs, for instance, arrive both ways — integers keep full
    /// precision by decoding the widest integer types before falling back.
    private struct LenientString: Decodable {
        let value: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                value = nil
            } else if let string = try? container.decode(String.self) {
                value = string
            } else if let int = try? container.decode(Int64.self) {
                value = String(int)
            } else if let uint = try? container.decode(UInt64.self) {
                value = String(uint)
            } else {
                value = nil
            }
        }
    }
}

// MARK: - String helpers

private extension String {
    /// Trimmed, or nil when the result would be empty.
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
