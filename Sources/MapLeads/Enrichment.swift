import Foundation
import Combine
import Security

struct EnrichmentOptions: Codable {
    var firecrawlEnabled = false
    var reviewsEnabled = false
    var aiEnabled = false
    var reviewMonths = 24
    var cacheDays = 30
    var llmBaseURL = "https://openrouter.ai/api/v1"
    var llmModel = ""
}

enum ProviderSecrets {
    static func load(_ account: String) throws -> String {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw failure(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw failure(errSecDecode) }
        return value
    }
    static func save(_ value: String, account: String) throws {
        let query = base(account)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
            return
        }
        let attrs = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            insertion[kSecValueData as String] = Data(value.utf8)
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(insertion as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }
    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.MapLeads.enrichment", kSecAttrAccount as String: account]
    }
    private static func failure(_ status: OSStatus) -> NSError {
        NSError(domain: "MapLeads.Keychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain operation failed"])
    }
}

struct EnrichmentRecord: Codable {
    var review: ReviewCheck?
    var reviewTaskID: String?
    var reviewError: String?
    var website: WebsiteCheck?
    var websiteError: String?
    var analysis: OpportunityAnalysis?
    var analysisBaseURL: String?
    var analysisError: String?
    var websiteIdentity: String?
    var retiredReviewTaskIDs: [String]?
}

@MainActor
final class EnrichmentStore: ObservableObject {
    @Published var options: EnrichmentOptions
    @Published private(set) var records: [String: EnrichmentRecord] = [:]
    @Published var error: String?
    @Published var status = ""
    @Published private(set) var busy = false
    private var stopped = false
    private var broken = false
    private let file: URL
    private let preferences: UserDefaults
    private let network: URLSession
    private let secret: (String) throws -> String
    var enabled: Bool { options.firecrawlEnabled || options.reviewsEnabled || options.aiEnabled }
    init(directory: URL? = nil, preferences: UserDefaults = .standard, network: URLSession = .shared, secret: @escaping (String) throws -> String = ProviderSecrets.load) {
        self.secret = secret
        self.network = network
        self.preferences = preferences
        let saved = preferences.data(forKey: "enrichmentOptions")
        options = saved.flatMap { try? JSONDecoder().decode(EnrichmentOptions.self, from: $0) } ?? EnrichmentOptions()
        let directory = directory ?? LeadStore.defaultDirectory()
        file = directory.appendingPathComponent("enrichment.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path) {
                records = try JSONDecoder().decode([String: EnrichmentRecord].self, from: Data(contentsOf: file))
            }
        } catch { broken = true; self.error = "Enrichment library could not be read; it will not be overwritten. \(error.localizedDescription)" }
    }
    func saveOptions() {
        do { preferences.set(try JSONEncoder().encode(options), forKey: "enrichmentOptions") }
        catch { self.error = error.localizedDescription }
    }
    @discardableResult func replaceRecords(_ replacement: [String: EnrichmentRecord]) -> Bool {
        guard !broken, !busy else { error = "Enrichment storage unavailable or a batch is running."; return false }
        do {
            try JSONEncoder().encode(replacement).write(to: file, options: .atomic)
            records = replacement; error = nil; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func category(_ lead: Lead, now: Date = Date()) -> String {
        if ["Do not contact", "Not interested"].contains(lead.stage) || lead.moved || lead.alert || ["CLOSED_PERMANENTLY", "CLOSED_TEMPORARILY"].contains(lead.businessStatus ?? "") || lead.phone == nil { return "Excluded" }
        let record = records[lead.id]
        if options.reviewsEnabled {
            guard record?.reviewError == nil, let review = record?.review, fresh(review.checkedAt, now: now), let latest = review.latestReview else { return "Needs verification" }
            let cutoff = Calendar.current.date(byAdding: .month, value: -options.reviewMonths, to: now)!
            if latest < cutoff { return "Inactive / stale leads" }
        }
        if lead.businessStatus != "OPERATIONAL" || lead.address == nil { return "Needs verification" }
        if lead.website != nil { return "Existing-site opportunities" }
        if options.firecrawlEnabled {
            guard record?.websiteIdentity == [lead.title, lead.phone ?? "", lead.address ?? "", lead.website ?? ""].joined(separator: "\u{1F}"), record?.websiteError == nil, let check = record?.website, fresh(check.checkedAt, now: now) else { return "Needs verification" }
            if check.status == "found" { return "Existing-site opportunities" }
            if check.status != "notFound" { return "Needs verification" }
        } else if !lead.websiteKnown { return "Needs verification" }
        return "Website opportunities"
    }
    func summary(_ lead: Lead) -> String {
        guard let record = records[lead.id] else { return "Not checked" }
        var lines: [String] = []
        if let review = record.review { lines.append("Review check \(review.checkedAt.formatted()): \(review.evidence)") }
        if let task = record.reviewTaskID { lines.append("Pending review task: \(task)") }
        if let retired = record.retiredReviewTaskIDs, !retired.isEmpty { lines.append("Replaced review task IDs: \(retired.joined(separator: ", "))") }
        if let check = record.website { lines.append("Website \(check.status), \(check.checkedAt.formatted()): \(check.url ?? "none") · \(check.evidence.joined(separator: "; "))") }
        if let analysis = record.analysis {
            lines.append("AI model: \(analysis.model), \(analysis.checkedAt.formatted())")
            for item in analysis.opportunities { lines.append("\(item.title) | Observed: \(item.evidence) | Ask: \(item.question) | Limitation: \(item.limitation) | Sources: \(item.sourceURLs.joined(separator: ", "))") }
        }
        lines.append(contentsOf: [record.reviewError, record.websiteError, record.analysisError].compactMap { $0 })
        return lines.joined(separator: "\n")
    }
    func exportCSV(_ leads: [Lead], store: LeadStore) -> String {
        // Use the existing CSV serializer for original fields; append enrichment
        // to each complete record, not to physical lines (notes may contain newlines).
        let header = store.exportCSV([]).trimmingCharacters(in: .newlines)
        var rows = [header + ",Prospecting category,Enrichment"]
        for lead in leads {
            let row = String(store.exportCSV([lead]).dropFirst(header.count + 1).dropLast())
            rows.append(row + "," + csv(category(lead)) + "," + csv(summary(lead)))
        }
        return rows.joined(separator: "\n") + "\n"
    }
    private func csv(_ raw: String) -> String {
        let first = raw.first(where: { !$0.isWhitespace })
        let safe = first.map { "=+-@".contains($0) } == true ? "'" + raw : raw
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    func fresh(_ date: Date, now: Date = Date()) -> Bool {
        date <= now && now.timeIntervalSince(date) < Double(options.cacheDays) * 86400
    }
    func stop() { stopped = true; status = "Stopping after the current request; pending review tasks are retained." }
    @discardableResult private func persist(_ record: EnrichmentRecord, id: String) -> Bool {
        guard !broken else { error = "Enrichment storage is unavailable; restore the library and relaunch."; return false }
        var next = records
        next[id] = record
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(next).write(to: file, options: .atomic)
            records = next
            return true
        } catch { self.error = "Could not save enrichment: \(error.localizedDescription)"; return false }
    }
    @discardableResult func retireFailedReviewTasks(_ ids: [String]) -> Bool {
        guard !busy else { return false }
        var next = records
        for id in ids {
            guard var record = next[id], record.reviewError != nil, let task = record.reviewTaskID else { continue }
            record.retiredReviewTaskIDs = (record.retiredReviewTaskIDs ?? []) + [task]
            record.reviewTaskID = nil
            next[id] = record
        }
        return replaceRecords(next)
    }
    func run(_ leads: [Lead], force: Bool = false, confirmedOperating: Set<String> = []) async {
        guard !busy, enabled, !broken else { return }
        let settings = options
        busy = true; stopped = false; error = nil
        defer { busy = false }
        do {
            let fireToken = settings.firecrawlEnabled ? try secret("firecrawl") : ""
            let login = settings.reviewsEnabled ? try secret("dataforseo.login") : ""
            let password = settings.reviewsEnabled ? try secret("dataforseo.password") : ""
            let aiToken = settings.aiEnabled ? try secret("llm") : ""
            if settings.firecrawlEnabled && fireToken.isEmpty { throw issue("Save a Firecrawl API key in Settings first.") }
            if settings.reviewsEnabled && (login.isEmpty || password.isEmpty) { throw issue("Save DataForSEO API login and password first.") }
            if settings.aiEnabled && (aiToken.isEmpty || settings.llmModel.isEmpty) { throw issue("Save an AI API key and select or enter a model first.") }
            for (index, lead) in leads.enumerated() {
                if stopped { break }
                if ["Do not contact", "Not interested"].contains(lead.stage) || lead.moved || lead.alert || ["CLOSED_PERMANENTLY", "CLOSED_TEMPORARILY"].contains(lead.businessStatus ?? "") || lead.phone == nil { continue }
                status = "\(index + 1)/\(leads.count) · \(lead.title)"
                var record = records[lead.id] ?? EnrichmentRecord()
                let identity = [lead.title, lead.phone ?? "", lead.address ?? "", lead.website ?? ""].joined(separator: "\u{1F}")
                if record.websiteIdentity != identity {
                    record.website = nil; record.websiteError = nil; record.analysis = nil
                    record.websiteIdentity = identity
                }
                if settings.reviewsEnabled && !confirmedOperating.contains(lead.id) && (force || record.review == nil || record.reviewError != nil || !fresh(record.review!.checkedAt) || record.reviewTaskID != nil) {
                    do {
                        let client = DataForSEOClient(login: login, password: password, session: network)
                        if record.reviewTaskID == nil {
                            let task = try await client.start(lead)
                            record.reviewTaskID = task.id
                            guard persist(record, id: lead.id) else {
                                status = "Review task \(task.id) started but could not be saved. Record this ID before retrying."
                                return
                            }
                        }
                        record.reviewError = nil
                        // One bounded poll window; a pending task resumes without paying to resubmit.
                        for _ in 0..<20 {
                            if stopped { break }
                            if let result = try await client.result(record.reviewTaskID!) {
                                record.review = result; record.reviewTaskID = nil; break
                            }
                            try await Task.sleep(for: .seconds(3))
                        }
                    } catch { record.reviewError = error.localizedDescription }
                    guard persist(record, id: lead.id) else { return }
                }
                if stopped { break }
                if settings.reviewsEnabled && !confirmedOperating.contains(lead.id) && (record.reviewTaskID != nil || record.reviewError != nil || record.review?.latestReview == nil || category(lead) == "Inactive / stale leads") { continue }
                if settings.firecrawlEnabled && (force || record.website == nil || record.websiteError != nil || !fresh(record.website!.checkedAt)) {
                    do {
                        record.website = try await FirecrawlClient(token: fireToken, session: network).check(lead)
                        record.websiteError = nil
                        record.analysis = nil
                    } catch { record.websiteError = error.localizedDescription }
                    guard persist(record, id: lead.id) else { return }
                }
                if stopped { break }
                if settings.aiEnabled && (force || record.analysis == nil || record.analysisError != nil || !fresh(record.analysis!.checkedAt) || record.analysis?.model != settings.llmModel || record.analysisBaseURL != settings.llmBaseURL) {
                    if let check = record.website, fresh(check.checkedAt), !check.pages.isEmpty, record.websiteError == nil, check.status == "found" {
                        do {
                            record.analysis = try await LLMClient(baseURL: settings.llmBaseURL, token: aiToken, model: settings.llmModel, session: network).analyze(lead: lead, pages: check.pages)
                            record.analysisBaseURL = settings.llmBaseURL
                            record.analysisError = nil
                        } catch { record.analysisError = error.localizedDescription }
                    } else { record.analysisError = "AI analysis needs fresh page content from a matched website. Enable Firecrawl or review the website-check result." }
                    guard persist(record, id: lead.id) else { return }
                }
            }
            status = stopped ? "Stopped. Completed results saved; pending review tasks will resume next time." : "Enrichment pass finished. Inspect results and errors; pending review tasks resume on the next pass."
        } catch { self.error = error.localizedDescription }
    }
    private func issue(_ message: String) -> NSError { NSError(domain: "MapLeads.Enrichment", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
