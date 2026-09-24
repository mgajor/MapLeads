import Foundation

// MARK: - Result model

/// One scraped page kept as evidence for a website check. `markdown` is the
/// page's main content, bounded in length; `url` is the page's final URL after
/// redirects when the API reported one.
struct WebsitePage: Codable {
    var url: String
    var title: String
    var markdown: String
}

/// The outcome of checking whether a lead has an official website.
///
/// `status` is one of:
/// - `"found"` — the Maps listing already named the site (scraped directly),
///   or a search candidate carries the business name *plus* the listing's
///   phone number or street address on the page. Name alone never qualifies.
/// - `"possible"` — a plausible but unverified candidate.
/// - `"notFound"` — the web searches succeeded and nothing plausible surfaced.
///   API, network, and decode failures throw instead; they never degrade to
///   `notFound`.
///
/// `evidence` explains what was searched, what was rejected, and why any match
/// or non-match was decided. `pages` only ever holds plausible business sites.
struct WebsiteCheck: Codable {
    var checkedAt: Date
    var status: String
    var url: String?
    var evidence: [String]
    var pages: [WebsitePage]

    static let statusFound = "found"
    static let statusPossible = "possible"
    static let statusNotFound = "notFound"
}

// MARK: - Errors

enum FirecrawlError: LocalizedError {
    case missingToken
    case http(status: Int, error: String?, code: String?)
    case unsuccessful(error: String?)
    case malformed(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "No Firecrawl API token is configured. Add your token (firecrawl.dev → API Keys) and try again."
        case .http(let status, let error, let code):
            var text = "Firecrawl request failed (HTTP \(status))"
            if let code, !code.isEmpty { text += ": \(code)" }
            if let error, !error.isEmpty { text += " — \(error)" }
            if status == 401 || status == 403 {
                text += " Check that your Firecrawl API token is valid (firecrawl.dev → API Keys)."
            } else if status == 402 {
                text += " Your Firecrawl plan may be out of credits."
            }
            return text
        case .unsuccessful(let error):
            if let error, !error.isEmpty {
                return "Firecrawl reported that the request failed: \(error)"
            }
            return "Firecrawl reported that the request failed without a reason."
        case .malformed(let detail):
            return "Could not read the Firecrawl response: \(detail)"
        case .network(let detail):
            return "Firecrawl request could not be sent (\(detail))"
        }
    }
}

// MARK: - Client

/// Native URLSession client for the Firecrawl v2 search and scrape endpoints
/// (https://api.firecrawl.dev/v2). All requests authenticate with
/// `Authorization: Bearer <token>` and go to that HTTPS host only.
///
/// URLSession drops the Authorization header whenever a redirect crosses
/// origins (including a port change), so the token cannot leak off
/// api.firecrawl.dev even if the API redirected; no custom redirect handler
/// is needed.
///
/// Every call is a single attempt — failures throw and are never retried
/// automatically, and never reported as `notFound`.
final class FirecrawlClient {
    private static let baseURL = URL(string: "https://api.firecrawl.dev/v2")!
    /// Low result cap: we only need a handful of candidates per query.
    private static let searchLimit = 4
    private static let maxSearches = 2
    private static let scrapeTimeout: TimeInterval = 120
    private static let searchTimeout: TimeInterval = 90
    private static let markdownCharacterLimit = 20_000
    private static let titleCharacterLimit = 200
    private static let evidenceLineLimit = 500
    private static let maxEvidenceLines = 12
    private static let maxRejectionNotes = 3

    private let token: String
    private let session: URLSession

    init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    // MARK: Public entry point

    /// Checks one lead for an official website. A lead whose Maps listing
    /// already names a website has that site scraped directly (never
    /// searched for); otherwise the web is searched (at most two queries) for
    /// an official site corroborated by phone number or street address.
    ///
    /// All values are read from the snapshot passed in; nothing is mutated.
    func check(_ lead: Lead) async throws -> WebsiteCheck {
        guard !token.isEmpty else { throw FirecrawlError.missingToken }

        let listed = lead.website?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !listed.isEmpty {
            return try await scrapeListedSite(listed, lead: lead)
        }
        return try await searchForOfficialSite(lead)
    }

    // MARK: Listed-website path

    private func scrapeListedSite(_ listed: String, lead: Lead) async throws -> WebsiteCheck {
        let normalized = listed.contains("://") ? listed : "https://" + listed
        guard let url = Self.safePublicURL(normalized) else {
            return WebsiteCheck(
                checkedAt: Date(),
                status: WebsiteCheck.statusPossible,
                url: listed,
                evidence: [
                    "The Maps listing links to \(listed), which is not a safe public web address (internal host, non-standard port, embedded credentials, or malformed); it was not scraped.",
                    "Kept as an unverified candidate: the business lists this site, but it could not be checked.",
                ],
                pages: []
            )
        }

        // A Maps listing that points at an aggregator page (Yelp page, Facebook
        // profile, booking widget…) is not the business's own website; don't
        // spend a scrape or analyze it as an owned site.
        let domain = Self.registrableDomain(url.host ?? "")
        if Self.nonOfficialDomains.contains(domain) {
            return WebsiteCheck(
                checkedAt: Date(),
                status: WebsiteCheck.statusPossible,
                url: url.absoluteString,
                evidence: [
                    "The Maps listing links to \(url.absoluteString), a \(domain) page.",
                    "\(domain) is a directory, social, or booking platform, not a business-owned website.",
                    "Kept as an unverified candidate: no official website was established.",
                ],
                pages: []
            )
        }

        let envelope: ScrapeEnvelope
        do {
            let data = try await post(
                "scrape",
                body: ScrapeBody(url: normalized),
                timeout: Self.scrapeTimeout
            )
            envelope = try JSONDecoder().decode(ScrapeEnvelope.self, from: data)
        } catch let error as FirecrawlError {
            throw error
        } catch {
            throw FirecrawlError.malformed("scrape response could not be decoded (\(error.localizedDescription))")
        }

        guard envelope.success else {
            throw FirecrawlError.unsuccessful(error: redacted(envelope.error))
        }
        guard let page = envelope.data else {
            throw FirecrawlError.malformed("scrape response had no data object")
        }

        let statusCode = page.metadata?.statusCode ?? 200
        let pageError = (page.metadata?.error).flatMap { $0.isEmpty ? nil : $0 }
        let rawMarkdown = page.markdown ?? ""
        let trimmedMarkdown = rawMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)

        // A scrape that ends on an unsafe final URL (redirect to an internal
        // host, malformed metadata) is not evidence of anything.
        guard let finalURL = Self.safePublicURL(page.metadata?.url ?? normalized) else {
            return WebsiteCheck(
                checkedAt: Date(),
                status: WebsiteCheck.statusPossible,
                url: url.absoluteString,
                evidence: [
                    "Scraped the website listed on Google Maps (\(url.absoluteString)).",
                    "The scrape landed on “\(page.metadata?.url ?? normalized)”, which is not a safe public web address; the content was discarded.",
                    "Kept as an unverified candidate: the business lists this site, but its content could not be checked.",
                ],
                pages: []
            )
        }

        if pageError != nil || statusCode >= 400 || trimmedMarkdown.isEmpty {
            var detail = "HTTP \(statusCode)"
            if let pageError {
                detail += ": \(pageError)"
            } else if trimmedMarkdown.isEmpty {
                detail += ": no page content was returned"
            }
            return WebsiteCheck(
                checkedAt: Date(),
                status: WebsiteCheck.statusPossible,
                url: finalURL.absoluteString,
                evidence: [
                    "Scraped the website listed on Google Maps (\(url.absoluteString)).",
                    "The page could not be read (\(detail)) — the link may be broken, parked, or empty.",
                    "Kept as an unverified candidate: the business lists this site, but its content could not be checked.",
                ],
                pages: []
            )
        }

        let title = Self.singleLine(page.metadata?.title?.value ?? Self.hostTitle(for: finalURL.absoluteString) ?? finalURL.absoluteString)
        let markdown = Self.bound(trimmedMarkdown, limit: Self.markdownCharacterLimit)

        var evidence = [
            "Scraped the website listed on Google Maps (\(url.absoluteString)).",
            "Page title: “\(title)”.",
        ]
        if let phone = lead.phone, !phone.isEmpty,
           let snippet = Self.phoneMatchSnippet(in: markdown, phone: phone) {
            evidence.append("The page shows the listing's phone number (matched “\(snippet)”).")
        }
        return WebsiteCheck(
            checkedAt: Date(),
            status: WebsiteCheck.statusFound,
            url: finalURL.absoluteString,
            evidence: evidence,
            pages: [WebsitePage(url: finalURL.absoluteString, title: title, markdown: markdown)]
        )
    }

    // MARK: Search path

    private func searchForOfficialSite(_ lead: Lead) async throws -> WebsiteCheck {
        let signals = Self.signals(for: lead)
        var evidence: [String] = []
        var strongMatch: (candidate: SearchCandidate, reasons: [String])?
        var bestPossible: (candidate: SearchCandidate, reasons: [String], score: Int)?
        var sawDirectoryRejections = false
        var totalResults = 0

        let queries = Self.searchQueries(signals)
        for query in queries.prefix(Self.maxSearches) {
            if strongMatch != nil { break }

            let outcome = try await runSearch(query)
            totalResults += outcome.resultCount
            evidence.append(
                "Searched the web for “\(query)” — \(outcome.resultCount) result\(outcome.resultCount == 1 ? "" : "s")."
            )
            sawDirectoryRejections = sawDirectoryRejections || outcome.hadDirectoryRejections
            evidence.append(contentsOf: outcome.notes)

            for candidate in outcome.candidates {
                let assessment = Self.assess(candidate: candidate, against: signals)
                guard assessment.plausible else { continue }
                if assessment.strong {
                    strongMatch = (candidate, assessment.reasons)
                    break
                }
                if bestPossible == nil || assessment.score > bestPossible!.score {
                    bestPossible = (candidate, assessment.reasons + assessment.gaps, assessment.score)
                }
            }
        }

        if let match = strongMatch {
            evidence.append(contentsOf: match.reasons)
            evidence.append("Matched \(match.candidate.url.absoluteString) as the official website.")
            return WebsiteCheck(
                checkedAt: Date(),
                status: WebsiteCheck.statusFound,
                url: match.candidate.url.absoluteString,
                evidence: Self.trimEvidence(evidence),
                pages: [match.candidate.page()]
            )
        }

        if let candidate = bestPossible?.candidate, let reasons = bestPossible?.reasons {
            evidence.append("Closest candidate: \(candidate.url.absoluteString).")
            evidence.append(contentsOf: reasons)
            return WebsiteCheck(
                checkedAt: Date(),
                status: WebsiteCheck.statusPossible,
                url: candidate.url.absoluteString,
                evidence: Self.trimEvidence(evidence),
                pages: candidate.contentAvailable ? [candidate.page()] : []
            )
        }

        evidence.append("No plausible official website for this business appeared in the search results.")
        if sawDirectoryRejections {
            evidence.append(
                "The matching results were directories, social profiles, or booking sites, which are not official business websites."
            )
        }
        if totalResults == 0 {
            evidence.append("Both searches returned no results.")
        }
        return WebsiteCheck(
            checkedAt: Date(),
            status: WebsiteCheck.statusNotFound,
            url: nil,
            evidence: Self.trimEvidence(evidence),
            pages: []
        )
    }

    /// One search round: POST /search with markdown scraping enabled.
    private func runSearch(_ query: String) async throws -> SearchOutcome {
        let envelope: SearchEnvelope
        do {
            let data = try await post(
                "search",
                body: SearchBody(query: query, limit: Self.searchLimit),
                timeout: Self.searchTimeout
            )
            envelope = try JSONDecoder().decode(SearchEnvelope.self, from: data)
        } catch let error as FirecrawlError {
            throw error
        } catch {
            throw FirecrawlError.malformed("search response could not be decoded (\(error.localizedDescription))")
        }

        guard envelope.success else {
            throw FirecrawlError.unsuccessful(error: redacted(envelope.error))
        }

        let web = envelope.data?.web ?? []
        var candidates: [SearchCandidate] = []
        var notes: [String] = []
        var directoryRejections = 0

        for result in web {
            let raw = (result.metadata?.url ?? result.url)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !raw.isEmpty, let url = Self.safePublicURL(raw) else {
                if !raw.isEmpty, notes.count < Self.maxRejectionNotes {
                    notes.append("Skipped \(raw) — not a safe public web address.")
                }
                continue
            }

            let domain = Self.registrableDomain(url.host ?? "")
            if Self.nonOfficialDomains.contains(domain) {
                directoryRejections += 1
                if notes.count < Self.maxRejectionNotes {
                    notes.append(
                        "Skipped \(url.absoluteString) — directory, social, or booking site (\(domain)), not an official business website."
                    )
                }
                continue
            }

            let markdown = Self.bound(result.markdown ?? "", limit: Self.markdownCharacterLimit)
            let resultError = result.metadata?.error?.isEmpty == false
            candidates.append(
                SearchCandidate(
                    url: url,
                    title: Self.singleLine(
                        result.metadata?.title?.value ?? result.title ?? url.host ?? url.absoluteString
                    ),
                    markdown: markdown,
                    contentAvailable: !resultError && !(result.markdown ?? "").isEmpty
                )
            )
        }

        return SearchOutcome(
            candidates: candidates,
            resultCount: web.count,
            notes: notes,
            hadDirectoryRejections: directoryRejections > 0
        )
    }

    // MARK: Transport

    private func post(_ path: String, body: some Encodable, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw FirecrawlError.malformed("request body could not be encoded (\(error.localizedDescription))")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FirecrawlError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw FirecrawlError.malformed("response was not HTTP")
        }
        // URLSession already strips Authorization on cross-origin redirects;
        // we additionally refuse to consume any body that landed off-host.
        guard let finalHost = http.url?.host?.lowercased(),
              finalHost == Self.baseURL.host?.lowercased() else {
            throw FirecrawlError.malformed(
                "request was redirected away from \(Self.baseURL.host ?? ""); the response was discarded"
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw apiError(status: http.statusCode, data: data)
        }
        return data
    }

    /// The API's own error text is echoed into our error messages; the token
    /// must never survive that round trip.
    private func redacted(_ text: String?) -> String? {
        guard let text, !text.isEmpty, !token.isEmpty else { return text }
        return text.replacingOccurrences(of: token, with: "[redacted]")
    }

    private func apiError(status: Int, data: Data) -> FirecrawlError {
        struct ErrorBody: Decodable {
            let error: String?
            let code: String?
        }
        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        return .http(status: status, error: redacted(body?.error), code: redacted(body?.code))
    }

    // MARK: Wire types

    private struct FormatOption: Encodable {
        let type = "markdown"
    }

    private struct SharedScrapeOptions: Encodable {
        let formats = [FormatOption()]
        let onlyMainContent = true
    }

    private struct ScrapeBody: Encodable {
        let url: String
        let formats = [FormatOption()]
        let onlyMainContent = true
    }

    private struct SearchBody: Encodable {
        let query: String
        let limit: Int
        let scrapeOptions = SharedScrapeOptions()
    }

    /// `metadata.title` is documented as either a string or an array of strings.
    private struct FlexTitle: Decodable {
        let value: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let s = try? container.decode(String.self) {
                value = s
            } else if let list = try? container.decode([String].self) {
                value = list.first
            } else {
                value = nil
            }
        }
    }

    private struct ScrapeEnvelope: Decodable {
        let success: Bool
        let error: String?
        let data: Payload?

        struct Payload: Decodable {
            let markdown: String?
            let metadata: Metadata?
        }

        struct Metadata: Decodable {
            let title: FlexTitle?
            let url: String?
            let sourceURL: String?
            let error: String?
            let statusCode: Int?
        }
    }

    private struct SearchEnvelope: Decodable {
        let success: Bool
        let error: String?
        let data: Payload?

        struct Payload: Decodable {
            let web: [WebResult]?
        }

        struct WebResult: Decodable {
            let title: String?
            let url: String?
            let markdown: String?
            let metadata: Metadata?
        }

        struct Metadata: Decodable {
            let title: FlexTitle?
            let url: String?
            let sourceURL: String?
            let error: String?
            let statusCode: Int?
        }
    }

    // MARK: Search evaluation

    private struct SearchCandidate {
        let url: URL
        let title: String
        let markdown: String
        let contentAvailable: Bool

        func page() -> WebsitePage {
            WebsitePage(url: url.absoluteString, title: title, markdown: markdown)
        }
    }

    private struct SearchOutcome {
        let candidates: [SearchCandidate]
        let resultCount: Int
        let notes: [String]
        let hadDirectoryRejections: Bool
    }

    private struct Assessment {
        let plausible: Bool
        let strong: Bool
        let reasons: [String]
        let gaps: [String]
        let score: Int
    }

    private struct LeadSignals {
        let name: String
        let signature: [String]
        let phone: String?
        let address: AddressParts?
        let categories: [String]
    }

    private struct AddressParts {
        let number: String?
        let streetTokens: [String]
        let addressLine: String?
        let cityLine: String?
    }

    /// A candidate is *strong* only when its name matches the business AND the
    /// page carries the listing's phone number or street address. Name alone —
    /// however good — never yields `found`.
    private static func assess(candidate: SearchCandidate, against signals: LeadSignals) -> Assessment {
        let titleTokens = Set(tokens(candidate.title))
        let pageTokens = Set(tokens(candidate.markdown))
        let signature = signals.signature

        var score = 0
        var reasons: [String] = []

        let titleOverlap = overlap(signature, in: titleTokens)
        let nameInTitle = titleOverlap >= 0.6
        if nameInTitle {
            score += 2
            reasons.append("Page title “\(candidate.title)” matches the business name.")
        }

        let hostSlug = fold(candidate.url.host ?? "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
        let joinedName = signature.joined()
        let nameInHost = joinedName.count >= 4 && hostSlug.contains(joinedName)
        if nameInHost {
            score += 2
            reasons.append("Domain \(candidate.url.host ?? "") contains the business name.")
        }

        var nameInPage = false
        if candidate.contentAvailable, !signature.isEmpty {
            let foldedPage = fold(candidate.markdown)
            nameInPage = foldedPage.contains(signature.joined(separator: " "))
                || overlap(signature, in: pageTokens) >= 0.8
            if nameInPage {
                score += 1
                reasons.append("The business name appears on the page.")
            }
        }
        let nameMatched = nameInTitle || nameInHost || nameInPage

        var phoneSnippet: String? = nil
        if let phone = signals.phone, !phone.isEmpty, candidate.contentAvailable {
            phoneSnippet = phoneMatchSnippet(in: candidate.markdown, phone: phone)
            if let snippet = phoneSnippet {
                score += 3
                reasons.append("The page lists the listing's phone number (matched “\(snippet)”).")
            }
        }

        var addressEvidence: String? = nil
        if let address = signals.address, candidate.contentAvailable,
           let matched = addressMatch(tokens: pageTokens, address: address) {
            addressEvidence = matched
            score += 2
            reasons.append("The page shows the listing's street address (\(matched)).")
        }

        let corroborated = phoneSnippet != nil || addressEvidence != nil
        let plausible = nameMatched || corroborated
        let strong = nameMatched && corroborated

        var gaps: [String] = []
        if plausible, !strong {
            if !nameMatched {
                gaps.append("The business name is not evident on this page, so the match rests on the phone number alone.")
            }
            if !corroborated {
                if signals.phone != nil || signals.address != nil {
                    gaps.append(
                        "Neither the listing's phone number nor its street address appears on the page, so the match could not be confirmed."
                    )
                } else {
                    gaps.append(
                        "The listing provides no phone number or street address to confirm the match."
                    )
                }
            }
            if !candidate.contentAvailable {
                gaps.append("The page content could not be retrieved for verification.")
            }
        }

        return Assessment(
            plausible: plausible,
            strong: strong,
            reasons: reasons,
            gaps: gaps,
            score: score
        )
    }

    // MARK: Query construction

    /// At most two queries. The first leads with the phone number (or street
    /// address when there is no phone); a second, address- or category-based
    /// query is offered only when it adds a differentiator the first lacked.
    private static func searchQueries(_ signals: LeadSignals) -> [String] {
        let quotedName = "\"\(signals.name.replacingOccurrences(of: "\"", with: ""))\""
        let city = signals.address?.cityLine

        var first: [String] = [quotedName]
        if let phone = signals.phone {
            first.append(phone)
        } else if let line = signals.address?.addressLine {
            first.append(line)
        }
        if let city { first.append(city) }

        var queries = [first.joined(separator: " ")]

        var second: [String] = []
        if signals.phone != nil, let line = signals.address?.addressLine {
            second = [quotedName, line]
            if let city { second.append(city) }
        } else if signals.phone == nil, let category = signals.categories.first {
            second = [quotedName, category]
            if let city { second.append(city) }
        }
        if !second.isEmpty, second != first {
            queries.append(second.joined(separator: " "))
        }

        // The API caps queries at 500 characters.
        return queries.map { query in
            query.count <= 480 ? query : String(query.prefix(480))
        }
    }

    private static func signals(for lead: Lead) -> LeadSignals {
        let phone = lead.phone?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPhone = (phone?.isEmpty == true) ? nil : phone
        return LeadSignals(
            name: lead.title.trimmingCharacters(in: .whitespacesAndNewlines),
            signature: nameSignature(lead.title),
            phone: cleanPhone,
            address: lead.address.map(parseAddress),
            categories: lead.categories
        )
    }

    // MARK: Text utilities

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
    }

    private static func tokens(_ s: String) -> [String] {
        fold(s).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func bound(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…[truncated]"
    }

    private static func singleLine(_ s: String) -> String {
        let flattened = s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return bound(flattened, limit: titleCharacterLimit)
    }

    private static func trimEvidence(_ lines: [String]) -> [String] {
        guard lines.count > maxEvidenceLines else { return lines }
        // Keep the search narrative at the top and the decisive lines at the end.
        let head = Array(lines.prefix(maxEvidenceLines - 4))
        let tail = Array(lines.suffix(4))
        return (head + tail).map { bound($0, limit: evidenceLineLimit) }
    }

    private static func hostTitle(for urlString: String) -> String? {
        URL(string: urlString)?.host
    }

    // MARK: Name matching

    private static let nameStopWords: Set<String> = [
        "the", "and", "for", "inc", "llc", "ltd", "corp", "plc", "llp",
        "company", "corporation", "enterprises",
    ]

    private static func nameSignature(_ name: String) -> [String] {
        let all = tokens(name)
        var significant = all.filter { $0.count >= 3 && !nameStopWords.contains($0) }
        var seen = Set<String>()
        significant = significant.filter { seen.insert($0).inserted }
        return significant.isEmpty ? all : significant
    }

    private static func overlap(_ signature: [String], in tokens: Set<String>) -> Double {
        guard !signature.isEmpty else { return 0 }
        let present = signature.filter { tokens.contains($0) }.count
        return Double(present) / Double(signature.count)
    }

    // MARK: Phone matching

    private static let phoneRunPattern = try! NSRegularExpression(
        pattern: "[0-9][0-9 ().\\-–—+]{5,}[0-9]"
    )

    private static func digits(_ s: String) -> String {
        String(s.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.map(Character.init))
    }

    /// Finds the listing's phone number on a page. Both sides are reduced to
    /// digits; a run matches when its digits equal the listing's digits or
    /// share the same national 10-digit tail. Returns the matched raw text as
    /// evidence, or nil.
    private static func phoneMatchSnippet(in text: String, phone: String) -> String? {
        let full = digits(phone)
        guard full.count >= 7 else { return nil }
        let national = full.count >= 10 ? String(full.suffix(10)) : full

        let range = NSRange(text.startIndex..., in: text)
        for match in phoneRunPattern.matches(in: text, range: range) {
            guard let r = Range(match.range, in: text) else { continue }
            let run = String(text[r])
            let runDigits = digits(run)
            guard runDigits.count >= 7 else { continue }
            let tail = runDigits.count >= 10 ? String(runDigits.suffix(10)) : runDigits
            if runDigits == full || tail == national {
                return bound(run.trimmingCharacters(in: .whitespacesAndNewlines), limit: 40)
            }
        }
        return nil
    }

    // MARK: Address matching

    private static let streetTypeWords: Set<String> = [
        "st", "street", "ave", "avenue", "rd", "road", "blvd", "boulevard",
        "dr", "drive", "ln", "lane", "way", "ct", "court", "pl", "place",
        "sq", "square", "ter", "terrace", "hwy", "highway", "trl", "trail",
        "pkwy", "parkway", "cir", "circle", "pike", "xt", "xing", "crossing",
    ]

    private static func parseAddress(_ raw: String) -> AddressParts {
        let parts = raw
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let first = parts.first ?? raw

        var toks = tokens(first)
        var number: String? = nil
        if let head = toks.first {
            let digitPrefix = head.prefix(while: { $0.isNumber })
            let rest = head.dropFirst(digitPrefix.count)
            if !digitPrefix.isEmpty, rest.count <= 1, rest.allSatisfy({ $0.isLetter }) {
                number = String(digitPrefix)
                toks = Array(toks.dropFirst(1))
            }
        }
        let streetTokens = toks.filter { $0.count >= 3 && !streetTypeWords.contains($0) }
        let deduped = Array(Set(streetTokens)).sorted()
        return AddressParts(
            number: number,
            streetTokens: deduped,
            addressLine: first.isEmpty ? nil : first,
            cityLine: parts.count > 1 ? parts[1] : nil
        )
    }

    /// A meaningful street-address match: the street number appears as a token
    /// and at least half of the significant street-name tokens do too.
    /// Returns the matched text for evidence, or nil.
    private static func addressMatch(tokens pageTokens: Set<String>, address: AddressParts) -> String? {
        guard let number = address.number, !address.streetTokens.isEmpty else { return nil }
        let hasNumber = pageTokens.contains(number)
            || pageTokens.contains { $0.hasPrefix(number) && $0.count <= number.count + 1 }
        guard hasNumber else { return nil }

        let present = address.streetTokens.filter { pageTokens.contains($0) }
        guard Double(present.count) / Double(address.streetTokens.count) >= 0.5 else { return nil }
        return ([number] + present.sorted { l, r in
            guard let li = address.streetTokens.firstIndex(of: l),
                  let ri = address.streetTokens.firstIndex(of: r) else { return l < r }
            return li < ri
        }).joined(separator: " ")
    }


    // MARK: URL safety

    /// Accepts only public http(s) URLs: no embedded credentials, no
    /// non-standard ports, no loopback/local/internal hosts, no IP literals.
    /// Everything we pass to Firecrawl or store as an official site goes
    /// through this gate.
    private static func safePublicURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else { return nil }

        let scheme = components.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        guard components.user == nil, components.password == nil else { return nil }
        if let port = components.port, port != 80, port != 443 { return nil }

        guard let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        if host.contains(":") { return nil } // IPv6 literal
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        if labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isNumber } }) { return nil } // IPv4 or numeric junk
        if host == "localhost" || host.hasSuffix(".localhost")
            || host.hasSuffix(".local") || host.hasSuffix(".internal")
            || host.hasSuffix(".lan") || host.hasSuffix(".example")
            || host.hasSuffix(".invalid") || host.hasSuffix(".test") {
            return nil
        }

        components.scheme = scheme
        return components.url
    }

    // MARK: Directory / social / booking hosts

    /// Registrable domains that are aggregators rather than the business's own
    /// site. A business's presence here is never its official website.
    /// Subdomains are covered by comparing registrable domains.
    private static let nonOfficialDomains: Set<String> = [
        // Social
        "facebook.com", "instagram.com", "twitter.com", "x.com", "tiktok.com",
        "linkedin.com", "pinterest.com", "youtube.com", "snapchat.com",
        "threads.net", "reddit.com", "whatsapp.com", "telegram.org",
        "medium.com", "tumblr.com", "nextdoor.com", "alignable.com",
        // Maps / search / reference
        "google.com", "bing.com", "mapquest.com", "waze.com", "here.com",
        "apple.com", "yellowpages.com", "whitepages.com", "superpages.com",
        "yellowbook.com", "manta.com", "hotfrog.com", "nicelocal.com",
        "cylex.com", "cylex.biz", "cylex.us", "cylex.co.uk", "opendi.com",
        "chamberofcommerce.com", "yell.com", "justdial.com", "hipages.com.au",
        "scamadviser.com", "bbb.org", "zoominfo.com", "crunchbase.com",
        "dnb.com", "glassdoor.com", "indeed.com", "ziprecruiter.com",
        // Reviews / vertical directories
        "yelp.com", "tripadvisor.com", "foursquare.com", "trustpilot.com",
        "birdeye.com", "zomato.com", "angi.com", "homeadvisor.com",
        "thumbtack.com", "porch.com", "houzz.com", "care.com", "zocdoc.com",
        "healthgrades.com", "vitals.com", "ratemds.com", "weddingwire.com",
        "theknot.com",
        // Booking / scheduling
        "opentable.com", "resy.com", "sevenrooms.com", "tocknetwork.com",
        "booking.com", "airbnb.com", "vrbo.com", "expedia.com", "hotels.com",
        "trivago.com", "kayak.com", "priceline.com", "agoda.com",
        "hostelworld.com", "styleseat.com", "booksy.com", "vagaro.com",
        "mindbodyonline.com", "classpass.com",
        // Delivery / marketplaces / deals
        "doordash.com", "ubereats.com", "grubhub.com", "seamless.com",
        "postmates.com", "delivery.com", "allmenus.com", "sirved.com",
        "menupix.com", "deliveroo.ie", "deliveroo.co.uk", "just-eat.co.uk",
        "swiggy.com", "talabat.com", "groupon.com", "livingsocial.com",
    ]

    private static let twoLevelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "net.uk", "sch.uk",
        "com.au", "net.au", "org.au", "gov.au", "edu.au",
        "co.nz", "net.nz", "org.nz", "govt.nz",
        "com.br", "com.mx", "com.ar", "com.co", "com.pe", "com.ec", "com.ve",
        "co.za", "com.tr", "com.cn", "com.sg", "com.hk", "com.tw",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "co.in", "net.in", "org.in",
        "co.kr", "com.vn", "com.my", "co.id", "com.ph",
    ]

    /// Approximate registrable domain ("business.facebook.com" →
    /// "facebook.com"), aware of common two-level public suffixes.
    private static func registrableDomain(_ host: String) -> String {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return host }
        if labels.count >= 3 {
            let lastTwo = labels.suffix(2).joined(separator: ".")
            if twoLevelSuffixes.contains(lastTwo) {
                return labels.suffix(3).joined(separator: ".")
            }
        }
        return labels.suffix(2).joined(separator: ".")
    }
}
