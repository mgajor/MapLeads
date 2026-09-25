import Foundation

// MARK: - Manual corrections (LeadWorkflow)

/// Manually verified outreach state for one lead, stored under `Lead.id` in
/// `WorkflowData.profiles`.
///
/// Corrections describe what a human learned; they never rewrite the actor's
/// raw facts. `Lead.rawJSON`, the listing phone/address, and the listing
/// website stay exactly as fetched — the correction is an overlay consulted
/// by `WorkflowStore.category` and `WorkflowStore.effective`. `correctedAt`
/// and `correctionNote` timestamp the reason each correction was recorded.
struct LeadWorkflow: Codable, Equatable {
    /// Human-verified website. Must be an http(s) URL on a public host with
    /// no embedded credentials (validated by `WorkflowStore.saveProfile`).
    /// nil means no correction was made; an empty string clears it.
    var verifiedWebsite: String?
    /// "Unchanged" leaves Google's raw status in force; the other values are
    /// human verdicts. See `LeadWorkflow.operatingOverrides`.
    var operatingOverride: String
    /// Why the correction was made, in the operator's words.
    var correctionNote: String
    /// When the correction was recorded.
    var correctedAt: Date?
    /// Done with this lead: removed from the call queue without asserting
    /// anything about its operating status.
    var archived: Bool
    var nextAction: String
    var template: String
    var offer: String
    var deliverables: String
    var assetsAvailable: String
    var assetsNeeded: String
    var questions: String
    var repoURL: String
    var previewURL: String
    var previewStage: String
    var notificationsEnabled: Bool

    /// Every value `operatingOverride` accepts.
    static let operatingOverrides = [
        "Unchanged", "Confirmed operating", "Confirmed closed", "Wrong number", "Not a fit",
    ]

    init(
        verifiedWebsite: String? = nil,
        operatingOverride: String = "Unchanged",
        correctionNote: String = "",
        correctedAt: Date? = nil,
        archived: Bool = false,
        nextAction: String = "",
        template: String = "",
        offer: String = "",
        deliverables: String = "",
        assetsAvailable: String = "",
        assetsNeeded: String = "",
        questions: String = "",
        repoURL: String = "",
        previewURL: String = "",
        previewStage: String = "Not started",
        notificationsEnabled: Bool = false
    ) {
        self.verifiedWebsite = verifiedWebsite
        self.operatingOverride = operatingOverride
        self.correctionNote = correctionNote
        self.correctedAt = correctedAt
        self.archived = archived
        self.nextAction = nextAction
        self.template = template
        self.offer = offer
        self.deliverables = deliverables
        self.assetsAvailable = assetsAvailable
        self.assetsNeeded = assetsNeeded
        self.questions = questions
        self.repoURL = repoURL
        self.previewURL = previewURL
        self.previewStage = previewStage
        self.notificationsEnabled = notificationsEnabled
    }
}

// MARK: - Contact history (ContactEvent)

/// One logged call outcome. The niche/area/offer fields are snapshots taken
/// at call time, so Insights grouping reflects what was true when the call
/// happened even if a later scan refreshes the listing.
struct ContactEvent: Identifiable, Codable, Equatable {
    var id: String
    var leadID: String
    var date: Date
    var outcome: String
    var note: String
    /// Primary business category at call time (first Maps category).
    var niche: String
    /// "City, State, Country" from the raw listing, or the address when the
    /// raw payload carries none of those fields.
    var area: String
    /// Offer recorded on the lead's profile at call time.
    var offer: String

    init(
        id: String = UUID().uuidString,
        leadID: String = "",
        date: Date = Date(),
        outcome: String = "",
        note: String = "",
        niche: String = "",
        area: String = "",
        offer: String = ""
    ) {
        self.id = id
        self.leadID = leadID
        self.date = date
        self.outcome = outcome
        self.note = note
        self.niche = niche
        self.area = area
        self.offer = offer
    }
}

// MARK: - Search history (SearchHistory)

/// One Apify run as seen from MapLeads: what was asked for, what came back,
/// and what it actually cost. `actualCostUSD` stays nil until the real
/// charge is known — nothing is ever estimated into it.
struct SearchHistory: Identifiable, Codable, Equatable {
    /// The Apify run ID.
    var id: String
    var date: Date
    var query: String
    var location: String
    var radius: Double
    var limit: Int
    var mode: String
    /// Final Apify run status (e.g. "SUCCEEDED", "ABORTED").
    var status: String
    var returned: Int
    var newCount: Int
    var refreshedCount: Int
    var qualifiedCount: Int
    var actualCostUSD: Double?
    var completed: Bool

    init(
        id: String = "",
        date: Date = Date(),
        query: String = "",
        location: String = "",
        radius: Double = 0,
        limit: Int = 0,
        mode: String = "",
        status: String = "",
        returned: Int = 0,
        newCount: Int = 0,
        refreshedCount: Int = 0,
        qualifiedCount: Int = 0,
        actualCostUSD: Double? = nil,
        completed: Bool = false
    ) {
        self.id = id
        self.date = date
        self.query = query
        self.location = location
        self.radius = radius
        self.limit = limit
        self.mode = mode
        self.status = status
        self.returned = returned
        self.newCount = newCount
        self.refreshedCount = refreshedCount
        self.qualifiedCount = qualifiedCount
        self.actualCostUSD = actualCostUSD
        self.completed = completed
    }
}

// MARK: - Enrichment instrumentation (EnrichmentJob)

/// One enrichment pass over a set of leads. `actualCostUSD` is nil while the
/// cost is unknown; a job record never fabricates a price.
struct EnrichmentJob: Identifiable, Codable, Equatable {
    var id: String
    var date: Date
    var leadIDs: [String]
    var status: String
    var summary: String
    var actualCostUSD: Double?

    init(
        id: String = UUID().uuidString,
        date: Date = Date(),
        leadIDs: [String] = [],
        status: String = "",
        summary: String = "",
        actualCostUSD: Double? = nil
    ) {
        self.id = id
        self.date = date
        self.leadIDs = leadIDs
        self.status = status
        self.summary = summary
        self.actualCostUSD = actualCostUSD
    }
}

// MARK: - Priority preferences (PriorityPreferences)

/// Operator preferences that promote leads in the call queue. They only ever
/// award points for matches — they never exclude a lead from eligibility.
/// Comma-separated lists are matched loosely (case-insensitive, substring in
/// either direction), because actor categories and preference notes rarely
/// agree on exact spelling.
struct PriorityPreferences: Codable, Equatable {
    /// Comma-separated preferred niches (e.g. "plumber, hvac, roofing").
    var niches: String
    /// Comma-separated preferred areas (city / state / country names).
    var areas: String
    /// Comma-separated preferred call templates.
    var templates: String
    var preferIndependent: Bool
    var minReviews: Int
    var maxReviews: Int
    var minRating: Double
    /// "Any", "Website" (no site listed), or "Existing site". See `offers`.
    var offer: String

    static let offers = ["Any", "Website", "Existing site"]

    init(
        niches: String = "",
        areas: String = "",
        templates: String = "",
        preferIndependent: Bool = false,
        minReviews: Int = 0,
        maxReviews: Int = 100_000,
        minRating: Double = 0,
        offer: String = "Any"
    ) {
        self.niches = niches
        self.areas = areas
        self.templates = templates
        self.preferIndependent = preferIndependent
        self.minReviews = minReviews
        self.maxReviews = maxReviews
        self.minRating = minRating
        self.offer = offer
    }

    /// Trims a comma-separated list into clean tokens.
    nonisolated static func tokens(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var nicheList: [String] { Self.tokens(niches) }
    var areaList: [String] { Self.tokens(areas) }
    var templateList: [String] { Self.tokens(templates) }
}

// MARK: - Container (WorkflowData)

/// Everything the workflow layer persists, in one atomically written file.
struct WorkflowData: Codable, Equatable {
    var profiles: [String: LeadWorkflow]
    var events: [ContactEvent]
    var searches: [SearchHistory]
    var jobs: [EnrichmentJob]
    var suppressedPhones: [String]
    var preferences: PriorityPreferences

    init(
        profiles: [String: LeadWorkflow] = [:],
        events: [ContactEvent] = [],
        searches: [SearchHistory] = [],
        jobs: [EnrichmentJob] = [],
        suppressedPhones: [String] = [],
        preferences: PriorityPreferences = PriorityPreferences()
    ) {
        self.profiles = profiles
        self.events = events
        self.searches = searches
        self.jobs = jobs
        self.suppressedPhones = suppressedPhones
        self.preferences = preferences
    }
}

// MARK: - Store

/// Outreach state that outlives individual scans: per-lead corrections,
/// contact history, search/enrichment instrumentation, phone-based
/// suppression, and priority preferences.
///
/// Persistence is fail-closed: the on-disk `workflow.json` is decoded
/// strictly, and if it cannot be read the store refuses every mutation so
/// the damaged file is never overwritten. Changes are published only after a
/// successful atomic save.
@MainActor
final class WorkflowStore: ObservableObject {
    @Published private(set) var data: WorkflowData
    @Published var error: String?

    private let fileURL: URL
    /// True when workflow.json exists but could not be decoded (or its folder
    /// could not be created). All mutations are then refused.
    private var storageBroken = false

    /// Every call outcome the UI offers, in queue-progression order.
    static let outcomes = [
        "No answer", "Voicemail", "Wrong number", "Confirmed closed", "Call back",
        "Reached", "Interested", "Meeting booked", "Meeting held", "Proposal sent",
        "Won", "Not interested", "Do not contact",
    ]

    /// Outcomes that record a terminal manual correction on the profile.
    private static let correctionOutcomes: Set<String> = ["Confirmed closed", "Wrong number"]

    init(directory: URL? = nil) {
        let dir = directory ?? LeadStore.defaultDirectory()
        fileURL = dir.appendingPathComponent("workflow.json", isDirectory: false)
        data = WorkflowData()

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch let folderError {
            storageBroken = true
            error = "Workflow folder could not be created (\(folderError.localizedDescription)). Nothing will be saved until it is available."
            return
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let raw = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            data = try decoder.decode(WorkflowData.self, from: raw)
            try Self.validate(data)
        } catch {
            storageBroken = true
            data = WorkflowData()
            self.error = "Saved workflow data could not be read (\(error.localizedDescription)). The file at \(fileURL.path) was left untouched — restore or remove it before continuing; nothing will be saved over it."
        }
    }

    // MARK: Profiles

    /// The manual correction state for a lead; a defaulted profile when none
    /// was recorded yet.
    func profile(id: String) -> LeadWorkflow {
        data.profiles[id] ?? LeadWorkflow()
    }

    /// Saves the manual correction state for a lead.
    ///
    /// `verifiedWebsite` (when non-empty) must be an http(s) URL on a host,
    /// with no user:password credentials. When the correction fields change
    /// against what was stored, `correctedAt` is stamped with the current
    /// time so every correction carries its timestamp; an explicitly newer
    /// `correctedAt` supplied by the caller is kept when nothing changed.
    @discardableResult func saveProfile(_ profile: LeadWorkflow, id: String) -> Bool {
        var next = profile
        if let raw = next.verifiedWebsite {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                next.verifiedWebsite = nil
                return commitCorrection(next, id: id)
            }
            switch Self.validatedWebsite(trimmed) {
            case .success(let url):
                next.verifiedWebsite = url
            case .failure(let reason):
                error = "Verified website rejected: \(reason)"
                return false
            }
        }
        return commitCorrection(next, id: id)
    }

    private func commitCorrection(_ profile: LeadWorkflow, id: String) -> Bool {
        var next = data
        let stored = next.profiles[id] ?? LeadWorkflow()
        if profile.verifiedWebsite != stored.verifiedWebsite
            || profile.operatingOverride != stored.operatingOverride {
            var stamped = profile
            stamped.correctedAt = Date()
            next.profiles[id] = stamped
        } else {
            next.profiles[id] = profile
        }
        return commit(next)
    }

    /// The lead as outreach should treat it: manual overlays applied to a
    /// working copy. The stored lead and every raw fact in it (`rawJSON`,
    /// phone, address, listing history) are never altered — this returns a
    /// value for display and gating, it does not mutate the library.
    func effective(_ lead: Lead) -> Lead {
        var result = lead
        let profile = self.profile(id: lead.id)
        if let verified = profile.verifiedWebsite {
            result.website = verified
            result.websiteKnown = true
        }
        switch profile.operatingOverride {
        case "Confirmed operating":
            result.businessStatus = "OPERATIONAL"
        case "Confirmed closed":
            result.businessStatus = "CLOSED_PERMANENTLY"
        default:
            break
        }
        return result
    }

    // MARK: Categories

    /// Queue category for a lead, refining `EnrichmentStore.category` with
    /// manually recorded state. Priority order:
    ///
    /// 1. Phone suppression (exact normalized-digit match) → "Excluded".
    /// 2. Archived profile → "Excluded".
    /// 3. Manual closure ("Confirmed closed", "Wrong number", "Not a fit") → "Excluded".
    /// 4. Hard exclusions from the listing itself (Do-not-contact stage, Not
    ///    interested, moved, consumer alert, Google-closed status, no phone)
    ///    — these always hold, corrections or not.
    /// 5. A human "Confirmed operating" correction bypasses the stale review
    ///    gate and satisfies the operating-status requirement; the address
    ///    and website checks still apply ("respect website").
    ///
    /// Returned vocabulary matches `EnrichmentStore.category`:
    /// "Excluded", "Needs verification", "Inactive / stale leads",
    /// "Existing-site opportunities", "Website opportunities".
    func category(_ lead: Lead, enrichment: EnrichmentStore, now: Date = Date()) -> String {
        let profile = self.profile(id: lead.id)
        if profile.archived { return "Archived" }
        let confirmedOperating = profile.operatingOverride == "Confirmed operating"
        let record = enrichment.records[lead.id]

        if let phone = lead.phone, Self.normalizedPhone(phone).isEmpty == false,
           data.suppressedPhones.contains(Self.normalizedPhone(phone)) {
            return "Excluded"
        }
        switch profile.operatingOverride {
        case "Confirmed closed", "Wrong number", "Not a fit":
            return "Excluded"
        default:
            break
        }

        if ["Do not contact", "Not interested"].contains(lead.stage) || lead.moved || lead.alert
            || ["CLOSED_PERMANENTLY", "CLOSED_TEMPORARILY"].contains(lead.businessStatus ?? "")
            || Self.normalizedPhone(lead.phone).isEmpty {
            return "Excluded"
        }
        // Stale review gate — bypassed only by the human correction.
        if !confirmedOperating && enrichment.options.reviewsEnabled {
            guard record?.reviewError == nil, let review = record?.review,
                  enrichment.fresh(review.checkedAt, now: now), let latest = review.latestReview
            else { return "Needs verification" }
            let cutoff = Calendar.current.date(byAdding: .month, value: -enrichment.options.reviewMonths, to: now)!
            if latest < cutoff { return "Inactive / stale leads" }
        }

        if !confirmedOperating && lead.businessStatus != "OPERATIONAL" { return "Needs verification" }
        if lead.address == nil { return "Needs verification" }

        // Respect the website: a listed site or a human-verified one both
        // mean the business already has a web presence.
        if lead.website != nil || profile.verifiedWebsite != nil { return "Existing-site opportunities" }

        if enrichment.options.firecrawlEnabled {
            let identity = [lead.title, lead.phone ?? "", lead.address ?? "", lead.website ?? ""]
                .joined(separator: "\u{1F}")
            guard record?.websiteIdentity == identity, record?.websiteError == nil,
                  let check = record?.website, enrichment.fresh(check.checkedAt, now: now)
            else { return "Needs verification" }
            if check.status == "found" { return "Existing-site opportunities" }
            if check.status != "notFound" { return "Needs verification" }
        } else if !lead.websiteKnown {
            return "Needs verification"
        }
        return "Website opportunities"
    }

    // MARK: Priority

    /// Queue priority for a lead: the base Maps score plus preference points.
    ///
    /// Preferences award points only for matches and never affect
    /// eligibility — a lead with zero preference points keeps whatever
    /// `category` says. `reasons` mirrors the score exactly, one line per
    /// contributing signal.
    func priority(_ lead: Lead) -> (score: Int, reasons: [String]) {
        let prefs = data.preferences
        let profile = self.profile(id: lead.id)
        var score = lead.score
        var reasons = ["+\(lead.score) · Base Maps score"]

        let niches = prefs.nicheList
        if !niches.isEmpty {
            let categories = lead.categories.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let hit = niches.first(where: { token in categories.contains { Self.looseMatch(token, $0) } }) {
                score += 3
                reasons.append("+3 · Preferred niche: \(hit)")
            }
        }

        let areas = prefs.areaList
        if !areas.isEmpty {
            let area = Self.areaSnapshot(for: lead)
            let haystack = [area, lead.address ?? ""]
            if let hit = areas.first(where: { token in haystack.contains { Self.looseMatch(token, $0) } }) {
                score += 2
                reasons.append("+2 · Preferred area: \(hit)")
            }
        }

        let templates = prefs.templateList
        if !templates.isEmpty {
            let value = profile.template.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, let hit = templates.first(where: { Self.looseMatch($0, value) }) {
                score += 1
                reasons.append("+1 · Preferred template: \(hit)")
            }
        }

        if prefs.preferIndependent && lead.isChain == false {
            score += 2
            reasons.append("+2 · Independent business (not a chain)")
        }

        if let reviews = lead.reviewCount, reviews >= prefs.minReviews, reviews <= prefs.maxReviews {
            score += 1
            reasons.append("+1 · \(reviews) reviews within preferred range (\(prefs.minReviews)–\(prefs.maxReviews))")
        }

        if prefs.minRating > 0, let rating = lead.rating, rating >= prefs.minRating {
            score += 1
            reasons.append("+1 · Rating \(String(format: "%.1f", rating)) meets preferred minimum \(String(format: "%.1f", prefs.minRating))")
        }

        let hasSite = lead.website != nil || profile.verifiedWebsite != nil
        switch prefs.offer {
        case "Website" where !hasSite:
            score += 2
            reasons.append("+2 · Matches preferred offer: new website")
        case "Existing site" where hasSite:
            score += 2
            reasons.append("+2 · Matches preferred offer: existing site")
        default:
            break
        }

        return (score, reasons)
    }

    // MARK: Preferences

    @discardableResult func savePreferences(_ preferences: PriorityPreferences) -> Bool {
        var next = data
        next.preferences = preferences
        return commit(next)
    }

    // MARK: Instrumentation

    /// Records (or updates, when re-saving the same run ID) one search.
    @discardableResult func saveSearch(_ search: SearchHistory) -> Bool {
        var next = data
        if let index = next.searches.firstIndex(where: { $0.id == search.id && !search.id.isEmpty }) {
            next.searches[index] = search
        } else {
            next.searches.append(search)
        }
        return commit(next)
    }

    /// Records (or updates, when re-saving the same job ID) one enrichment pass.
    @discardableResult func saveJob(_ job: EnrichmentJob) -> Bool {
        var next = data
        if let index = next.jobs.firstIndex(where: { $0.id == job.id }) {
            next.jobs[index] = job
        } else {
            next.jobs.append(job)
        }
        return commit(next)
    }

    // MARK: Contact history

    /// Logs one call outcome against a lead.
    ///
    /// The event snapshots niche (first Maps category), area (raw
    /// city/state/country, else the address), and the offer recorded on the
    /// profile at call time. "Confirmed closed" and "Wrong number" also write
    /// the matching manual correction onto the profile, and "Do not contact"
    /// also suppresses the lead's exact normalized phone number — all in the
    /// same atomic save, so the correction and its reason can never tear
    /// apart. No stage is ever inferred; stages live on `Lead` in `LeadStore`.
    @discardableResult func record(outcome: String, note: String, lead: Lead) -> Bool {
        var next = data
        var profile = next.profiles[lead.id] ?? LeadWorkflow()
        let now = Date()

        switch outcome {
        case "Confirmed closed", "Wrong number":
            profile.operatingOverride = outcome
            profile.correctedAt = now
            profile.correctionNote = note.isEmpty ? outcome : note
            next.profiles[lead.id] = profile
        case "Do not contact":
            let key = Self.normalizedPhone(lead.phone)
            if !key.isEmpty, !next.suppressedPhones.contains(key) {
                next.suppressedPhones.append(key)
            }
        default:
            break
        }

        let event = ContactEvent(
            leadID: lead.id,
            date: now,
            outcome: outcome,
            note: note,
            niche: Self.nicheSnapshot(for: lead),
            area: Self.areaSnapshot(for: lead),
            offer: (next.profiles[lead.id] ?? profile).offer
        )
        next.events.append(event)
        return commit(next)
    }

    // MARK: Restore

    /// Replaces the persisted data, used by backup restore. The replacement
    /// unions — never erases — recorded opt-outs:
    ///
    /// * `suppressedPhones` keeps every existing entry;
    /// * historical "Do not contact" events survive even when the restored
    ///   library no longer contains the records they refer to;
    /// * profiles carrying a terminal correction ("Confirmed closed",
    ///   "Wrong number", "Not a fit") survive for lead IDs missing from the
    ///   incoming data.
    ///
    /// Everything else (searches, jobs, ordinary events, preferences,
    /// non-terminal profiles) is taken from `incoming` as given.
    @discardableResult func replace(_ incoming: WorkflowData) -> Bool {
        var merged = incoming

        var phones = incoming.suppressedPhones
        for existing in data.suppressedPhones where !phones.contains(existing) {
            phones.append(existing)
        }
        merged.suppressedPhones = phones

        var seen = Set(incoming.events.map(\.id))
        for existing in data.events where existing.outcome == "Do not contact" && !seen.contains(existing.id) {
            merged.events.append(existing)
            seen.insert(existing.id)
        }

        let terminal: Set<String> = ["Confirmed closed", "Wrong number", "Not a fit"]
        for (id, existing) in data.profiles
        where merged.profiles[id] == nil
            && (existing.archived || terminal.contains(existing.operatingOverride)) {
            merged.profiles[id] = existing
        }

        return commit(merged)
    }

    // MARK: Suppression

    /// True when the lead's exact normalized phone number is suppressed.
    func isSuppressed(_ lead: Lead) -> Bool {
        let key = Self.normalizedPhone(lead.phone)
        return !key.isEmpty && data.suppressedPhones.contains(key)
    }

    /// Suppresses the lead by its exact normalized phone number. The number
    /// is stored as bare digits; matching is exact — a 10-digit local form
    /// and its 11-digit "+1" form are different keys, because the raw
    /// country information needed to fold them together is not reliably
    /// available and a wrong fold could silence an unrelated business.
    @discardableResult func suppress(_ lead: Lead) -> Bool {
        let key = Self.normalizedPhone(lead.phone)
        guard !key.isEmpty else {
            error = "Cannot suppress a lead without a phone number."
            return false
        }
        guard !data.suppressedPhones.contains(key) else { return true }
        var next = data
        next.suppressedPhones.append(key)
        return commit(next)
    }

    /// Removes one exact normalized phone number from the suppression list.
    /// This is the only path that ever removes a suppression; deletes and
    /// restores elsewhere never touch the list.
    @discardableResult func removeSuppression(phone: String) -> Bool {
        let key = Self.normalizedPhone(phone)
        guard !key.isEmpty, let index = data.suppressedPhones.firstIndex(of: key) else {
            return false
        }
        var next = data
        next.suppressedPhones.remove(at: index)
        return commit(next)
    }

    // MARK: Pure helpers

    /// Normalizes a phone number to bare ASCII digits, dropping formatting
    /// (+, spaces, dashes, parentheses, dots) and everything else. There is
    /// deliberately no country folding: "+15551234567" and "5551234567"
    /// normalize to different keys (see `suppress`).
    nonisolated static func normalizedPhone(_ value: String?) -> String {
        guard let value else { return "" }
        return String(value.unicodeScalars.filter { (48...57).contains($0.value) }.map(Character.init))
    }

    /// First Maps category, used as the niche snapshot at call time.
    nonisolated static func nicheSnapshot(for lead: Lead) -> String {
        lead.categories.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// "City, State, Country" from the raw listing payload, falling back to
    /// the formatted address when none of those fields are present.
    nonisolated static func areaSnapshot(for lead: Lead) -> String {
        if let object = try? JSONSerialization.jsonObject(with: Data(lead.rawJSON.utf8)) as? [String: Any] {
            let city = (object["city"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let state = ((object["state"] as? String) ?? (object["region"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let country = (object["country"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = [city, state, country].compactMap { $0 }.filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: ", ") }
        }
        return lead.address ?? ""
    }

    /// Case-insensitive two-way substring match between a preference token
    /// and a recorded value.
    nonisolated private static func looseMatch(_ token: String, _ value: String) -> Bool {
        guard !token.isEmpty, !value.isEmpty else { return false }
        return value.localizedCaseInsensitiveContains(token) || token.localizedCaseInsensitiveContains(value)
    }

    private struct WebsiteValidationError: Error, ExpressibleByStringLiteral, ExpressibleByStringInterpolation, CustomStringConvertible {
        let description: String
        init(stringLiteral value: String) { description = value }
        init(stringInterpolation: DefaultStringInterpolation) { description = String(stringInterpolation: stringInterpolation) }
    }
    /// Validates a manually verified website: http(s) scheme, real host, no
    /// embedded credentials, not localhost. Returns the canonical absolute
    /// string, or the reason it was rejected.
    nonisolated private static func validatedWebsite(_ raw: String) -> Result<String, WebsiteValidationError> {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return .failure("\"\(raw)\" is not an http(s) URL.")
        }
        guard let host = url.host, !host.isEmpty else {
            return .failure("\"\(raw)\" has no host.")
        }
        guard url.user == nil, url.password == nil, !raw.contains("@") else {
            return .failure("\"\(raw)\" embeds credentials; use a clean public URL.")
        }
        guard host.lowercased() != "localhost", !host.hasSuffix(".local"), !host.isIPAddressLiteral else {
            return .failure("\"\(raw)\" is not a public address.")
        }
        return .success(url.absoluteString)
    }

    // MARK: Internals

    private static func validate(_ value: WorkflowData) throws {
        func require(_ condition: Bool, _ reason: String) throws {
            if !condition { throw NSError(domain: "MapLeads.Workflow", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
        }
        try require(value.preferences.minReviews >= 0 && value.preferences.maxReviews >= value.preferences.minReviews && (0...5).contains(value.preferences.minRating), "Invalid priority ranges")
        try require(Set(value.events.map(\.id)).count == value.events.count && value.events.allSatisfy { !$0.id.isEmpty && !$0.leadID.isEmpty && $0.date.timeIntervalSince1970.isFinite }, "Invalid contact history")
        try require(Set(value.searches.map(\.id)).count == value.searches.count && value.searches.allSatisfy { !$0.id.isEmpty && $0.newCount >= 0 && $0.refreshedCount >= 0 && $0.returned >= 0 }, "Invalid search history")
        try require(Set(value.jobs.map(\.id)).count == value.jobs.count, "Duplicate enrichment job IDs")
        for (id, profile) in value.profiles {
            try require(!id.isEmpty && LeadWorkflow.operatingOverrides.contains(profile.operatingOverride), "Invalid manual correction")
            if let website = profile.verifiedWebsite, case .failure = validatedWebsite(website) { try require(false, "Invalid verified website in workflow") }
        }
    }

    private func ensureWritable() -> Bool {
        guard !storageBroken else {
            error = "Refused: the saved workflow data is damaged, so changes cannot be stored. Restore or remove \(fileURL.path) and relaunch."
            return false
        }
        return true
    }

    /// Encodes and atomically writes `next`; publishes it only after the
    /// write succeeds. On failure nothing is published and the previous data
    /// stays in force.
    private func commit(_ next: WorkflowData) -> Bool {
        guard ensureWritable() else { return false }
        do {
            try Self.validate(next)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(next).write(to: fileURL, options: .atomic)
            data = next
            error = nil
            return true
        } catch {
            self.error = "Workflow data could not be saved (\(error.localizedDescription)). Nothing was changed."
            return false
        }
    }
}

private extension String {
    /// True for IPv4 literals like "192.0.2.1" (IPv6 hosts arrive bracketed
    /// and are treated as non-public only when they are literals, which this
    /// also covers via the colon check on the bare host).
    var isIPAddressLiteral: Bool {
        if contains(":") { return true }
        let parts = split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part), (0...255).contains(value) else { return false }
            return part.count == String(value).count
        }
    }
}
