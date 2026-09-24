import Foundation
import CryptoKit

// MARK: - Parse errors

/// JSON from the actor dataset must be an array of objects. Any row that is
/// structurally wrong throws instead of being silently dropped.
enum LeadParseError: LocalizedError, Equatable {
    case invalidJSON(String)
    case notArray
    case malformedRow(index: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let detail):
            return "The data is not valid JSON (\(detail))."
        case .notArray:
            return "Expected a JSON array of actor items; a single object or envelope is not supported."
        case .malformedRow(let index, let reason):
            return "Item \(index + 1) is malformed and nothing was imported: \(reason)."
        }
    }
}

// MARK: - Lead

struct Lead: Codable, Identifiable {
    var id: String
    var title: String
    var phone: String?
    var website: String?
    /// True when the actor returned the website field in any form (value, null,
    /// or empty). False only when the field was omitted entirely — an omitted
    /// field is *unknown*, never evidence that no website exists.
    var websiteKnown: Bool
    var address: String?
    var categories: [String]
    var businessStatus: String?
    var rating: Double?
    var reviewCount: Int?
    var hours: [String]
    var isClaimed: Bool?
    var isChain: Bool?
    var moved: Bool
    var alert: Bool
    var mapsURL: String?
    var fetchedAt: Date
    var rawJSON: String
    var stage: String
    var notes: String
    var followUp: Date?
    var meeting: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, phone, website, websiteKnown, address, categories
        case businessStatus, rating, reviewCount, hours, isClaimed, isChain
        case moved, alert, mapsURL, fetchedAt, rawJSON, stage, notes
        case followUp, meeting
    }

    init(
        id: String,
        title: String,
        phone: String?,
        website: String?,
        websiteKnown: Bool,
        address: String?,
        categories: [String],
        businessStatus: String?,
        rating: Double?,
        reviewCount: Int?,
        hours: [String],
        isClaimed: Bool?,
        isChain: Bool?,
        moved: Bool,
        alert: Bool,
        mapsURL: String?,
        fetchedAt: Date,
        rawJSON: String,
        stage: String = "New",
        notes: String = "",
        followUp: Date? = nil,
        meeting: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.phone = phone
        self.website = website
        self.websiteKnown = websiteKnown
        self.address = address
        self.categories = categories
        self.businessStatus = businessStatus
        self.rating = rating
        self.reviewCount = reviewCount
        self.hours = hours
        self.isClaimed = isClaimed
        self.isChain = isChain
        self.moved = moved
        self.alert = alert
        self.mapsURL = mapsURL
        self.fetchedAt = fetchedAt
        self.rawJSON = rawJSON
        self.stage = stage
        self.notes = notes
        self.followUp = followUp
        self.meeting = meeting
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        phone = try c.decodeIfPresent(String.self, forKey: .phone)
        website = try c.decodeIfPresent(String.self, forKey: .website)
        websiteKnown = try c.decodeIfPresent(Bool.self, forKey: .websiteKnown) ?? false
        address = try c.decodeIfPresent(String.self, forKey: .address)
        categories = try c.decodeIfPresent([String].self, forKey: .categories) ?? []
        businessStatus = try c.decodeIfPresent(String.self, forKey: .businessStatus)
        rating = try c.decodeIfPresent(Double.self, forKey: .rating)
        reviewCount = try c.decodeIfPresent(Int.self, forKey: .reviewCount)
        hours = try c.decodeIfPresent([String].self, forKey: .hours) ?? []
        isClaimed = try c.decodeIfPresent(Bool.self, forKey: .isClaimed)
        isChain = try c.decodeIfPresent(Bool.self, forKey: .isChain)
        moved = try c.decodeIfPresent(Bool.self, forKey: .moved) ?? false
        alert = try c.decodeIfPresent(Bool.self, forKey: .alert) ?? false
        mapsURL = try c.decodeIfPresent(String.self, forKey: .mapsURL)
        fetchedAt = try c.decode(Date.self, forKey: .fetchedAt)
        rawJSON = try c.decode(String.self, forKey: .rawJSON)
        stage = try c.decodeIfPresent(String.self, forKey: .stage) ?? "New"
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        followUp = try c.decodeIfPresent(Date.self, forKey: .followUp)
        meeting = try c.decodeIfPresent(Date.self, forKey: .meeting)
    }

    // MARK: Qualification, score, evidence

    /// "Call candidates", "Needs verification", or "Excluded".
    var qualification: String { assessment.qualification }

    /// Additive score over the positive signals below; absent data never
    /// contributes and is never read as a negative.
    var score: Int { assessment.score }

    /// Human-readable reasons, one per signal, matching the score exactly.
    var evidence: [String] { assessment.evidence }

    /// Offers grounded in returned fields only.
    var opportunities: [String] { assessment.opportunities }

    private struct Assessment {
        var qualification = "Call candidates"
        var score = 0
        var evidence: [String] = []
        var opportunities: [String] = []
    }

    private var assessment: Assessment {
        var a = Assessment()
        var excluded = false
        var needsVerification = false

        // Hard excludes first; every one is stated as evidence.
        switch stage {
        case "Do not contact", "Not interested":
            a.evidence.append("Marked “\(stage)” during outreach")
            excluded = true
        default:
            break
        }

        switch businessStatus {
        case "OPERATIONAL":
            a.score += 1
            a.evidence.append("+1 · Operating status: OPERATIONAL")
        case "CLOSED_PERMANENTLY":
            a.evidence.append("Permanently closed according to Google")
            excluded = true
        case "CLOSED_TEMPORARILY":
            a.evidence.append("Temporarily closed according to Google")
            excluded = true
        case let status?:
            a.evidence.append("Unrecognized operating status “\(status)” — verify before calling")
            needsVerification = true
        case nil:
            a.evidence.append("Operating status not returned — verify before calling")
            needsVerification = true
        }

        if moved {
            a.evidence.append("Listing points to a newer location (movedPlaceId present)")
            excluded = true
        }
        if alert {
            a.evidence.append("Consumer alert attached to this listing")
            excluded = true
        }

        if let website, !website.isEmpty {
            a.evidence.append("Website already listed: \(website)")
            excluded = true
        } else if websiteKnown {
            a.score += 3
            a.evidence.append("+3 · No website listed on Google Maps")
            a.opportunities.append("No website on the Maps listing — offer a simple professional site.")
        } else {
            a.evidence.append("Website status unknown — the field was not returned; verify before assuming none")
            needsVerification = true
        }

        if let phone, !phone.isEmpty {
            a.score += 2
            a.evidence.append("+2 · Phone number listed: \(phone)")
        } else {
            a.evidence.append("No phone number in the listing data")
            excluded = true
        }

        // Present-but-unknown-safe optional signals.
        if let claimed = isClaimed {
            if claimed {
                a.evidence.append("Listing claimed by the business")
            } else {
                a.score += 2
                a.evidence.append("+2 · Actor reports the listing is unclaimed — verify with the owner")
                a.opportunities.append("Unclaimed Google Business Profile — offer claiming and management.")
            }
        }

        if let chain = isChain {
            if chain {
                a.evidence.append("Part of a chain — decisions may sit elsewhere")
            } else {
                a.score += 1
                a.evidence.append("+1 · Actor reports this is not a chain")
            }
        }

        if let count = reviewCount {
            if count == 0 {
                a.evidence.append("No reviews on this listing yet")
                a.opportunities.append("No reviews yet — offer review-generation setup.")
            } else if let stars = rating {
                a.evidence.append(String(format: "Rated %.1f across %d reviews", stars, count))
                if stars >= 4.0 && count >= 10 {
                    a.score += 1
                    a.evidence.append("+1 · At least 10 reviews and a rating of 4.0 or higher")
                }
            } else {
                a.evidence.append("\(count) reviews; rating not returned")
            }
        }

        if !hours.isEmpty {
            a.score += 1
            a.evidence.append("+1 · Publishes opening hours (\(hours.count) entries)")
        }

        if let address, !address.isEmpty {
            a.score += 1
            a.evidence.append("+1 · Street address listed: \(address)")
        } else {
            a.evidence.append("No street address returned — confirm location or service region")
            needsVerification = true
        }

        if !categories.isEmpty {
            a.evidence.append("Categories: \(categories.joined(separator: ", "))")
        }

        if excluded { a.qualification = "Excluded" }
        else if needsVerification { a.qualification = "Needs verification" }
        return a
    }

    // MARK: Parsing

    /// Parses a JSON array of actor dataset items. Throws `LeadParseError` on
    /// anything structurally wrong; never drops rows silently.
    static func parse(_ data: Data) throws -> [Lead] {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LeadParseError.invalidJSON(error.localizedDescription)
        }
        guard let rows = root as? [Any] else {
            throw LeadParseError.notArray
        }
        return try rows.enumerated().map { index, row in
            guard let dict = row as? [String: Any] else {
                throw LeadParseError.malformedRow(index: index, reason: "item is not a JSON object")
            }
            return try makeLead(row: dict, index: index)
        }
    }

    private static func makeLead(row: [String: Any], index: Int) throws -> Lead {
        func malformed(_ reason: String) -> LeadParseError {
            .malformedRow(index: index, reason: reason)
        }

        guard let rawTitle = try string(row, keys: ["title"], index: index) else {
            throw malformed("missing \"title\"")
        }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw malformed("\"title\" is empty") }

        let phone = try string(row, keys: ["phoneIntl", "phone"], index: index)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let phoneValue = (phone?.isEmpty == true) ? nil : phone

        // Website: a value (or domain) wins; explicit null/empty with no domain
        // counts as known-absent; an entirely omitted field counts as unknown.
        let rawWebsite = try string(row, keys: ["website"], index: index)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawDomain = try string(row, keys: ["websiteDomain"], index: index)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var website: String?
        var websiteKnown = false
        if let w = rawWebsite, !w.isEmpty {
            website = w
            websiteKnown = true
        } else if let d = rawDomain, !d.isEmpty {
            website = d.contains("://") ? d : "https://" + d
            websiteKnown = true
        } else if row.keys.contains("website") || row.keys.contains("websiteDomain") {
            websiteKnown = true
        }

        let address = try string(row, keys: ["formattedAddress", "address"], index: index)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let addressValue = (address?.isEmpty == true) ? nil : address

        var categories: [String] = []
        if let value = row["categories"], !(value is NSNull) {
            guard let array = value as? [Any] else {
                throw malformed("\"categories\" is not an array")
            }
            categories = try array.map { element in
                guard let s = element as? String, !(element is NSNull) else {
                    throw malformed("\"categories\" contains a non-string entry")
                }
                return s
            }
        } else if let single = try string(row, keys: ["categoryName"], index: index), !single.isEmpty {
            categories = [single]
        }

        let status = try string(row, keys: ["businessStatus"], index: index)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let businessStatus = (status?.isEmpty == true) ? nil : status?.uppercased()

        let rating = try number(row, keys: ["rating", "totalScore"], index: index)
        let reviewCount = try integer(row, keys: ["reviewCount", "reviewsCount"], index: index)
        let hours = try hoursList(row, index: index)
        let isClaimed = try boolean(row, keys: ["claimed", "isClaimed"], index: index)
        let isChain = try boolean(row, keys: ["chain", "isChain"], index: index)

        let movedID = try string(row, keys: ["movedPlaceId"], index: index)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let moved = (movedID?.isEmpty == false)

        let alert = try boolean(row, keys: ["consumerAlert"], index: index) ?? false

        let maps = try string(row, keys: ["googleMapsUri", "url"], index: index)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mapsURL = (maps?.isEmpty == true) ? nil : maps

        let placeID = try string(row, keys: ["placeId", "googleId"], index: index)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let id: String
        if let placeID, !placeID.isEmpty {
            id = placeID
        } else {
            // Deterministic content hash so repeated imports dedup identically.
            let identity = [
                title,
                addressValue ?? "",
                phoneValue ?? "",
                website ?? "",
                categories.first ?? "",
            ].joined(separator: "\u{1F}")
            let digest = SHA256.hash(data: Data(identity.utf8))
                .map { String(format: "%02x", $0) }.joined()
            id = "local-" + String(digest.prefix(24))
        }

        let rawJSON: String
        do {
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            rawJSON = String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            throw malformed("row could not be re-serialized")
        }

        return Lead(
            id: id,
            title: title,
            phone: phoneValue,
            website: website,
            websiteKnown: websiteKnown,
            address: addressValue,
            categories: categories,
            businessStatus: businessStatus,
            rating: rating,
            reviewCount: reviewCount,
            hours: hours,
            isClaimed: isClaimed,
            isChain: isChain,
            moved: moved,
            alert: alert,
            mapsURL: mapsURL,
            fetchedAt: Date(),
            rawJSON: rawJSON
        )
    }

    // MARK: Field accessors

    /// First present, non-null value among `keys`. A present value of the wrong
    /// type is a malformed row. Returns nil for absent or JSON-null.
    private static func string(_ row: [String: Any], keys: [String], index: Int) throws -> String? {
        for key in keys {
            guard let value = row[key], !(value is NSNull) else { continue }
            guard let s = value as? String else {
                throw LeadParseError.malformedRow(index: index, reason: "\"\(key)\" is not a string")
            }
            return s
        }
        return nil
    }

    private static func number(_ row: [String: Any], keys: [String], index: Int) throws -> Double? {
        for key in keys {
            guard let value = row[key], !(value is NSNull) else { continue }
            if let n = value as? NSNumber, !isBoolean(value) {
                return n.doubleValue
            }
            if let s = value as? String,
               let d = Double(s.trimmingCharacters(in: .whitespaces)) {
                return d
            }
            throw LeadParseError.malformedRow(index: index, reason: "\"\(key)\" is not a number")
        }
        return nil
    }

    private static func integer(_ row: [String: Any], keys: [String], index: Int) throws -> Int? {
        guard let d = try number(row, keys: keys, index: index) else { return nil }
        guard d.isFinite, d.rounded() == d else {
            throw LeadParseError.malformedRow(index: index, reason: "review count is not a whole number")
        }
        return Int(d)
    }

    private static func boolean(_ row: [String: Any], keys: [String], index: Int) throws -> Bool? {
        for key in keys {
            guard let value = row[key], !(value is NSNull) else { continue }
            if let b = value as? Bool { return b }
            if let s = value as? String {
                switch s.trimmingCharacters(in: .whitespaces).lowercased() {
                case "true": return true
                case "false": return false
                default: break
                }
            }
            throw LeadParseError.malformedRow(index: index, reason: "\"\(key)\" is not a boolean")
        }
        return nil
    }

    private static func hoursList(_ row: [String: Any], index: Int) throws -> [String] {
        guard let value = row["hours"], !(value is NSNull) else { return [] }
        guard let array = value as? [Any] else {
            throw LeadParseError.malformedRow(index: index, reason: "\"hours\" is not an array")
        }
        var out: [String] = []
        for entry in array {
            guard let dict = entry as? [String: Any] else {
                throw LeadParseError.malformedRow(index: index, reason: "\"hours\" contains a non-object entry")
            }
            let day = try string(dict, keys: ["day"], index: index)
            let times = try string(dict, keys: ["hours"], index: index)
            switch (day, times) {
            case let (d?, t?): out.append("\(d): \(t)")
            case let (d?, nil): out.append(d)
            case let (nil, t?): out.append(t)
            case (nil, nil): continue
            }
        }
        return out
    }

    /// JSONSerialization bridges real JSON booleans to NSNumber tagged as
    /// CFBoolean; 0/1 numbers must not pass as booleans (or vice versa).
    private static func isBoolean(_ value: Any) -> Bool {
        (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
    }
}

// MARK: - Store

@MainActor
final class LeadStore: ObservableObject {
    @Published private(set) var leads: [Lead] = []
    @Published var error: String?

    private let fileURL: URL
    /// True when the saved library exists but could not be read (or its folder
    /// could not be created). Mutations are then refused so the damaged file is
    /// never overwritten.
    private var storageBroken = false

    init(directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory()
        fileURL = dir.appendingPathComponent("leads.json", isDirectory: false)

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch let folderError {
            storageBroken = true
            error = "Lead library folder could not be created (\(folderError.localizedDescription)). Nothing will be saved until it is available."
            return
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            leads = try decoder.decode([Lead].self, from: data)
        } catch {
            storageBroken = true
            leads = []
            self.error = "Saved leads could not be read (\(error.localizedDescription)). The file at \(fileURL.path) was left untouched — restore or remove it before importing; nothing will be saved over it."
        }
    }

    nonisolated static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MapLeads", isDirectory: true)
    }

    /// Adds leads, deduplicating by id. Fresh listing data replaces stored
    /// listing data; outreach state (stage, notes, follow-up, meeting) is kept.
    func merge(_ incoming: [Lead]) {
        guard ensureWritable() else { return }
        var byID: [String: Lead] = [:]
        var order: [String] = []
        for lead in leads {
            if byID[lead.id] == nil { order.append(lead.id) }
            byID[lead.id] = lead
        }
        for fresh in incoming {
            if let existing = byID[fresh.id] {
                var refreshed = fresh
                refreshed.stage = existing.stage
                refreshed.notes = existing.notes
                refreshed.followUp = existing.followUp
                refreshed.meeting = existing.meeting
                byID[fresh.id] = refreshed
            } else {
                byID[fresh.id] = fresh
                order.append(fresh.id)
            }
        }
        leads = order.compactMap { byID[$0] }
        persist()
    }

    /// Replaces a lead (or appends it) and persists.
    func update(_ lead: Lead) {
        guard ensureWritable() else { return }
        if let i = leads.firstIndex(where: { $0.id == lead.id }) {
            leads[i] = lead
        } else {
            leads.append(lead)
        }
        persist()
    }

    /// Formula-safe CSV for any selection of leads.
    func exportCSV(_ leads: [Lead]) -> String {
        let header = [
            "Title", "Categories", "Phone", "Website", "Website status", "Address",
            "Business status", "Rating", "Reviews", "Claimed", "Chain", "Hours",
            "Qualification", "Score", "Evidence", "Opportunities", "Stage",
            "Follow-up", "Meeting", "Notes", "Maps URL", "Fetched at",
        ].map(Self.csvField).joined(separator: ",")

        let formatter = ISO8601DateFormatter()
        var lines = [header]
        for lead in leads {
            let websiteStatus: String
            if lead.website != nil {
                websiteStatus = "Listed"
            } else {
                websiteStatus = lead.websiteKnown ? "None listed" : "Unknown"
            }
            var fields: [String] = []
            fields.reserveCapacity(22)
            fields.append(lead.title)
            fields.append(lead.categories.joined(separator: "; "))
            fields.append(lead.phone ?? "")
            fields.append(lead.website ?? "")
            fields.append(websiteStatus)
            fields.append(lead.address ?? "")
            fields.append(lead.businessStatus ?? "")
            if let stars = lead.rating { fields.append(String(format: "%.1f", stars)) } else { fields.append("") }
            if let reviews = lead.reviewCount { fields.append(String(reviews)) } else { fields.append("") }
            fields.append(lead.isClaimed.map { $0 ? "Yes" : "No" } ?? "")
            fields.append(lead.isChain.map { $0 ? "Yes" : "No" } ?? "")
            fields.append(lead.hours.joined(separator: "; "))
            fields.append(lead.qualification)
            fields.append(String(lead.score))
            fields.append(lead.evidence.joined(separator: " | "))
            fields.append(lead.opportunities.joined(separator: " | "))
            fields.append(lead.stage)
            fields.append(lead.followUp.map { formatter.string(from: $0) } ?? "")
            fields.append(lead.meeting.map { formatter.string(from: $0) } ?? "")
            fields.append(lead.notes)
            fields.append(lead.mapsURL ?? "")
            fields.append(formatter.string(from: lead.fetchedAt))
            lines.append(fields.map(Self.csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Internals

    private func ensureWritable() -> Bool {
        guard !storageBroken else {
            error = "Refused: the saved lead library is damaged, so changes cannot be stored. Restore or remove \(fileURL.path) and relaunch."
            return false
        }
        return true
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(leads).write(to: fileURL, options: .atomic)
            error = nil
        } catch {
            self.error = "Leads could not be saved (\(error.localizedDescription)). Changes remain in memory only."
        }
    }

    /// Quotes when needed and neutralizes spreadsheet formula injection —
    /// including payloads hidden behind leading whitespace — by prefixing an
    /// apostrophe when the first non-whitespace character could start a formula.
    private static func csvField(_ raw: String) -> String {
        var value = raw
        if let first = value.first(where: { !$0.isWhitespace }), "=+-@\t\r".contains(first) {
            value = "'" + value
        }
        if value.contains(where: { ",\"\n\r".contains($0) }) {
            value = "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}
