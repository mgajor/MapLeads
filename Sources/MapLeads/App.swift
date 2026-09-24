import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct MapLeadsApp: App {
    @StateObject private var store = LeadStore()
    var body: some Scene {
        WindowGroup {
            Workspace(store: store)
                .frame(minWidth: 1050, minHeight: 700)
        }
        .windowStyle(.titleBar)
    }
}

@MainActor
final class SearchSession: ObservableObject {
    @Published var token = ""
    @Published var message = ""
    @Published var busy = false
    @Published var runID = UserDefaults.standard.string(forKey: "pendingRun") ?? ""
    @Published var error: String?
    init() {
        do { token = try KeychainToken.load() } catch { self.error = error.localizedDescription }
    }
    func saveToken() {
        do { try KeychainToken.save(token.trimmingCharacters(in: .whitespacesAndNewlines)); message = "Credential updated in Keychain." }
        catch { self.error = error.localizedDescription }
    }
    func search(query: String, location: String, radius: Double, limit: Int, mode: String, budget: Double, store: LeadStore) async {
        busy = true
        defer { busy = false }
        do {
            message = "Starting paid Apify run…"
            let run = try await ApifyClient(token: token).start(query: query, location: location, radius: radius, maxResults: limit, mode: mode, budget: budget)
            runID = run.id
            UserDefaults.standard.set(runID, forKey: "pendingRun")
            try await collect(store: store)
        } catch { self.error = error.localizedDescription; message = "Search interrupted. If a run ID is present, resume it rather than starting again. Check Apify Console before retrying an uncertain start." }
    }
    func resume(store: LeadStore) async {
        busy = true
        defer { busy = false }
        do { try await collect(store: store) } catch { self.error = error.localizedDescription }
    }
    private func collect(store: LeadStore) async throws {
        let client = ApifyClient(token: token)
        while true {
            let run = try await client.getRun(runID)
            message = "\(run.status): \(run.statusMessage ?? run.id)"
            if run.terminal {
                let leads = run.defaultDatasetId.isEmpty ? [] : try await client.results(run.defaultDatasetId)
                store.merge(leads)
                guard store.error == nil else { return }
                message = "\(run.status) · Saved \(leads.count) results.\(run.status == "SUCCEEDED" ? "" : " Results may be partial.")"
                runID = ""
                UserDefaults.standard.removeObject(forKey: "pendingRun")
                return
            }
            try await Task.sleep(for: .seconds(3))
        }
    }
    func abort() async {
        do { try await ApifyClient(token: token).abort(runID); message = "Abort requested. Resume to retrieve any partial results." }
        catch { self.error = error.localizedDescription }
    }
}

struct Workspace: View {
    @ObservedObject var store: LeadStore
    @StateObject private var session = SearchSession()
    @StateObject private var enrichment = EnrichmentStore()
    @State private var enrichmentTargets: [Lead] = []
    @State private var confirmEnrichment = false
    @State private var forceEnrichment = false
    @State private var selected: String?
    @State private var bucket = "All leads"
    @State private var search = ""
    @State private var showSearch = false
    @State private var showSettings = false
    @State private var localError: String?
    @State private var websiteFilter = "Any website"
    @State private var phoneOnly = false
    @State private var stageFilter = "Any stage"
    @State private var operationalOnly = false
    private let buckets = ["All leads", "Website opportunities", "Existing-site opportunities", "Needs verification", "Inactive / stale leads", "Excluded", "Follow-ups"]
    var filtered: [Lead] {
        store.leads.filter { lead in
            let matchesBucket = bucket == "All leads" || enrichment.category(lead) == bucket || (bucket == "Follow-ups" && lead.followUp != nil && !["Do not contact", "Not interested"].contains(lead.stage))
            let websiteMatches = websiteFilter == "Any website" || (websiteFilter == "No website listed" && lead.websiteKnown && lead.website == nil) || (websiteFilter == "Website present" && lead.website != nil) || (websiteFilter == "Website unknown" && !lead.websiteKnown)
            return matchesBucket && websiteMatches && (!phoneOnly || lead.phone != nil) && (!operationalOnly || lead.businessStatus == "OPERATIONAL") && (stageFilter == "Any stage" || lead.stage == stageFilter) && (search.isEmpty || "\(lead.title) \(lead.address ?? "") \(lead.categories.joined(separator: " "))".localizedCaseInsensitiveContains(search))
        }.sorted { $0.score == $1.score ? $0.title < $1.title : $0.score > $1.score }
    }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 20) {
                Label("MapLeads", systemImage: "mappin.and.ellipse").font(.title2.bold()).padding(.top)
                Text("LOCAL PROSPECT WORKSPACE").font(.caption2).foregroundStyle(.secondary)
                List(buckets, id: \.self, selection: $bucket) { item in
                    Label(item, systemImage: icon(item)).tag(item)
                }.listStyle(.sidebar)
                DisclosureGroup("Filters") {
                    Picker("Website", selection: $websiteFilter) {
                        ForEach(["Any website", "No website listed", "Website present", "Website unknown"], id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                    Picker("Stage", selection: $stageFilter) {
                        ForEach(["Any stage", "New", "Contacted", "Interested", "Meeting booked", "Won", "Not interested", "Do not contact"], id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                    Toggle("Has phone", isOn: $phoneOnly)
                    Toggle("Operational status", isOn: $operationalOnly)
                }.font(.caption)
                Text("\(store.leads.count) saved businesses").font(.caption).foregroundStyle(.secondary)
                Button("Settings", systemImage: "gearshape") { showSettings = true }.disabled(enrichment.busy)
                Text("Your lead library stays on this Mac. Searches run on Apify.").font(.caption).foregroundStyle(.secondary)
            }.padding().navigationSplitViewColumnWidth(230)
        } content: {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(bucket).font(.title2.bold())
                        Text("\(filtered.count) businesses · ranked by evidence").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Find leads", systemImage: "plus.magnifyingglass") { showSearch = true }.buttonStyle(.borderedProminent)
                }.padding()
                if !session.message.isEmpty || !session.runID.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if session.busy { ProgressView().controlSize(.small) }
                        Text(session.message.isEmpty ? "A previous Apify run is available to resume." : session.message).font(.caption).textSelection(.enabled)
                        if !session.runID.isEmpty {
                            HStack {
                                Link("Open run", destination: URL(string: "https://console.apify.com/actors/runs/\(session.runID)")!)
                                Button("Resume / collect") { Task { await session.resume(store: store) } }.disabled(session.busy || session.token.isEmpty)
                                Button("Abort cloud run") { Task { await session.abort() } }
                            }.font(.caption)
                        }
                    }.padding().frame(maxWidth: .infinity, alignment: .leading).background(.blue.opacity(0.06))
                }
                List(filtered, selection: $selected) { lead in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(lead.title).font(.headline)
                            Spacer()
                            Text("\(lead.score)").font(.system(.headline, design: .rounded)).foregroundStyle(.blue)
                        }
                        Text(lead.categories.first ?? "Category unavailable").font(.subheadline).foregroundStyle(.secondary)
                        Text(lead.address ?? "Address unavailable").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        HStack {
                            Text(enrichment.category(lead)).foregroundStyle(enrichment.category(lead) == "Website opportunities" ? .green : .secondary)
                            Spacer()
                            Text(lead.stage)
                        }.font(.caption)
                    }.padding(.vertical, 7).tag(lead.id)
                }.overlay {
                    if filtered.isEmpty {
                        ContentUnavailableView("Your next call starts here", systemImage: "building.2", description: Text("Search a niche and location, or import an Apify JSON export. No demo leads are mixed into your library."))
                    }
                }
                HStack {
                    Button("Import JSON", systemImage: "square.and.arrow.down", action: importJSON)
                    Button("Export CSV", systemImage: "square.and.arrow.up") { saveText(enrichment.exportCSV(filtered, store: store), name: "MapLeads.csv", type: .commaSeparatedText) }.disabled(filtered.isEmpty)
                    Spacer()
                }.padding()
                HStack {
                    Button("Enrich filtered list") { enrichmentTargets = filtered; confirmEnrichment = true }
                        .disabled(filtered.isEmpty || !enrichment.enabled || enrichment.busy)
                    if enrichment.busy { ProgressView().controlSize(.small); Button("Stop") { enrichment.stop() } }
                }.padding(.horizontal)
                if !enrichment.status.isEmpty { Text(enrichment.status).font(.caption).textSelection(.enabled).padding() }
            }.navigationSplitViewColumnWidth(min: 350, ideal: 410)
        } detail: {
            if let lead = store.leads.first(where: { $0.id == selected }) {
                VStack(spacing: 0) {
                    HStack {
                        Text(enrichment.category(lead)).font(.caption.bold())
                        Spacer()
                        Button("Enrich this lead") { enrichmentTargets = [lead]; confirmEnrichment = true }
                            .disabled(!enrichment.enabled || enrichment.busy)
                    }.padding()
                    LeadDetail(lead: lead, enrichment: enrichment, save: store.update, export: { text in saveText(text, name: "Business-brief.txt", type: .plainText) }).id(lead.id).disabled(enrichment.busy)
                }
            } else {
                ContentUnavailableView("Choose a business", systemImage: "person.text.rectangle", description: Text("Review evidence, plan a call, and track the next step."))
            }
        }
        .searchable(text: $search, prompt: "Search saved businesses")
        .sheet(isPresented: $showSearch) { SearchForm(session: session, store: store) }
        .sheet(isPresented: $showSettings) {
            ProviderSettingsView(session: session, enrichment: enrichment)
        }
        .sheet(isPresented: $confirmEnrichment) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Enrich \(enrichmentTargets.count) businesses?").font(.title2.bold())
                Text("Enabled providers: \([enrichment.options.reviewsEnabled ? "DataForSEO" : nil, enrichment.options.firecrawlEnabled ? "Firecrawl" : nil, enrichment.options.aiEnabled ? "AI provider" : nil].compactMap { $0 }.joined(separator: ", "))")
                Text("This sends selected business facts and website excerpts to enabled providers and may incur charges. The Apify spending cap does not apply. Existing opt-outs and closed listings are skipped. Successful recent checks are reused.")
                Toggle("Refresh cached checks (additional paid requests)", isOn: $forceEnrichment)
                Text("Pending review tasks resume instead of being resubmitted. Stop finishes the current request; cloud tasks may continue.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { confirmEnrichment = false }
                    Spacer()
                    Button("Authorize enrichment") {
                        confirmEnrichment = false
                        let targets = enrichmentTargets
                        let force = forceEnrichment
                        Task { await enrichment.run(targets, force: force) }
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(26).frame(width: 550)
        }
        .alert("Action needs attention", isPresented: Binding(get: { localError != nil || session.error != nil || store.error != nil || enrichment.error != nil }, set: { if !$0 { localError = nil; session.error = nil; store.error = nil; enrichment.error = nil } })) {
            Button("OK") { localError = nil; session.error = nil; store.error = nil; enrichment.error = nil }
        } message: { Text(localError ?? session.error ?? store.error ?? enrichment.error ?? "") }
    }
    func icon(_ bucket: String) -> String {
        switch bucket {
        case "Website opportunities": return "phone"
        case "Existing-site opportunities": return "globe"
        case "Inactive / stale leads": return "archivebox"
        case "Needs verification": return "questionmark.circle"
        case "Excluded": return "nosign"
        case "Follow-ups": return "calendar"
        default: return "tray.full"
        }
    }
    func importJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { store.merge(try Lead.parse(Data(contentsOf: url))) } catch { localError = error.localizedDescription }
    }
    func saveText(_ text: String, name: String, type: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { localError = error.localizedDescription }
    }
}

struct SearchForm: View {
    @ObservedObject var session: SearchSession
    @ObservedObject var store: LeadStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var location = ""
    @State private var radius = 10.0
    @State private var limit = 100
    @State private var mode = "basic"
    @State private var budget = 1.0
    @State private var consent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Find your next customers").font(.title.bold())
            Text("Search one niche in one area. Start small, then verify your shortlist before building previews.").foregroundStyle(.secondary)
            Form {
                TextField("Business niche", text: $query, prompt: Text("e.g. independent salons"))
                TextField("Location", text: $location, prompt: Text("City, state, country"))
                Stepper("Radius: \(Int(radius)) miles", value: $radius, in: 1...100)
                Stepper("Maximum results: \(limit)", value: $limit, in: 25...1000, step: 25)
                Picker("Details", selection: $mode) {
                    Text("Basic — contact and operating data").tag("basic")
                    Text("Detailed — profile and claimed status").tag("detailed")
                    Text("Rich — review and media details").tag("rich")
                }
                Stepper("Run spending cap: $\(budget, specifier: "%.2f") USD", value: $budget, in: 0.5...20, step: 0.5)
            }
            Text("Area searches cover a rectangle, not city boundaries. Results may be fewer than requested. No website listed does not prove no website exists.").font(.caption).foregroundStyle(.secondary)
            Link("Review current actor pricing", destination: URL(string: "https://apify.com/kaix/google-maps-places-scraper")!)
            Toggle("I authorize a paid Apify run up to the cap above.", isOn: $consent)
            if session.token.isEmpty { Text("Add an API token in Apify settings first.").foregroundStyle(.orange) }
            if !session.runID.isEmpty { Text("Collect the existing run before starting another.").foregroundStyle(.orange) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Start search") {
                    dismiss()
                    Task { await session.search(query: query.trimmingCharacters(in: .whitespacesAndNewlines), location: location.trimmingCharacters(in: .whitespacesAndNewlines), radius: radius, limit: limit, mode: mode, budget: budget, store: store) }
                }.buttonStyle(.borderedProminent)
                    .disabled(!consent || session.token.isEmpty || session.busy || !session.runID.isEmpty || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 600)
    }
}

struct LeadDetail: View {
    let lead: Lead
    @ObservedObject var enrichment: EnrichmentStore
    let save: (Lead) -> Void
    let export: (String) -> Void
    @State private var stage = "New"
    @State private var notes = ""
    @State private var followUp = Date()
    @State private var meeting = Date()
    @State private var hasFollowUp = false
    @State private var hasMeeting = false
    @State private var saved = false
    let stages = ["New", "Contacted", "Interested", "Meeting booked", "Won", "Not interested", "Do not contact"]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(lead.title).font(.largeTitle.bold()).textSelection(.enabled)
                Text(lead.categories.joined(separator: " · ")).foregroundStyle(.secondary)
                HStack {
                    Label(enrichment.category(lead), systemImage: "checklist")
                    Spacer()
                    Text("Score \(lead.score)").font(.headline).foregroundStyle(.blue)
                }
                GroupBox("Listing facts") {
                    VStack(alignment: .leading, spacing: 9) {
                        fact("Phone", lead.phone ?? "Not provided")
                        fact("Address", lead.address ?? "Not provided")
                        fact("Website", lead.website ?? (lead.websiteKnown ? "No website listed on Maps" : "Unknown — field not returned"))
                        fact("Business status", lead.businessStatus ?? "Unknown")
                        fact("Rating", lead.rating.map { String(format: "%.1f", $0) } ?? "Unknown")
                        fact("Reviews", lead.reviewCount.map(String.init) ?? "Unknown")
                        fact("Claimed", lead.isClaimed.map { $0 ? "Yes" : "No" } ?? "Unknown")
                        if !lead.hours.isEmpty { fact("Hours", lead.hours.joined(separator: "\n")) }
                        if let url = safeURL(lead.mapsURL) { Link("Inspect Google Maps listing", destination: url) }
                        if let url = safeURL(lead.website) { Link("Open listed website", destination: url) }
                        Text("Fetched \(lead.fetchedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Original Maps evidence").font(.headline)
                    ForEach(lead.evidence, id: \.self) { Text("• \($0)").font(.callout) }
                    Text("Listing signals are not proof the business is still operating. Verify before investing in a preview.").font(.caption).foregroundStyle(.secondary)
                }
                if !lead.opportunities.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Potential offers").font(.headline)
                        ForEach(lead.opportunities, id: \.self) { Text("• \($0)").font(.callout) }
                    }
                }
                Divider()
                EnrichmentDetailView(record: enrichment.records[lead.id], category: enrichment.category(lead))
                Divider()
                Text("Outreach & next step").font(.title3.bold())
                Picker("Stage", selection: $stage) { ForEach(stages, id: \.self) { Text($0).tag($0) } }
                Toggle("Schedule follow-up", isOn: $hasFollowUp)
                if hasFollowUp { DatePicker("Follow-up", selection: $followUp) }
                Toggle("Meeting booked", isOn: $hasMeeting)
                if hasMeeting { DatePicker("Meeting", selection: $meeting) }
                Text("Call notes").font(.headline)
                TextEditor(text: $notes).font(.body).frame(minHeight: 120).padding(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(.gray.opacity(0.3)))
                HStack {
                    Button("Save outreach") {
                        var updated = lead
                        updated.stage = stage; updated.notes = notes
                        updated.followUp = hasFollowUp ? followUp : nil
                        updated.meeting = hasMeeting ? meeting : nil
                        save(updated); saved = true
                    }.buttonStyle(.borderedProminent)
                    if saved { Text("Save requested").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Export brief") { export(brief) }
                }
                DisclosureGroup("Source JSON") { Text(lead.rawJSON).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            }.padding(26)
        }.onAppear {
            stage = lead.stage; notes = lead.notes
            hasFollowUp = lead.followUp != nil; followUp = lead.followUp ?? Date()
            hasMeeting = lead.meeting != nil; meeting = lead.meeting ?? Date()
        }
    }
    func fact(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(name).foregroundStyle(.secondary).frame(width: 95, alignment: .leading)
            Text(value).textSelection(.enabled)
        }.font(.callout)
    }
    func safeURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
    var brief: String {
        """
        BUSINESS PREVIEW BRIEF
        \(lead.title)
        Categories: \(lead.categories.joined(separator: ", "))
        Phone: \(lead.phone ?? "Unknown")
        Address: \(lead.address ?? "Unknown")
        Listed website: \(lead.website ?? (lead.websiteKnown ? "None listed on Maps" : "Unknown"))
        Maps: \(lead.mapsURL ?? "Unknown")
        Hours: \(lead.hours.joined(separator: "; "))
        Qualification: \(enrichment.category(lead))
        Enrichment: \(enrichment.summary(lead))
        Evidence:
        \(lead.evidence.joined(separator: "\n"))
        Potential offers:
        \(lead.opportunities.joined(separator: "\n"))
        Stage: \(stage)
        Meeting: \(hasMeeting ? meeting.formatted() : "Not scheduled")
        Follow-up: \(hasFollowUp ? followUp.formatted() : "Not scheduled")
        Notes: \(notes)

        PREVIEW CHECKLIST
        Verify operating status and whether a separate website exists.
        Use your existing niche template; label any placeholder content.
        Confirm rights/permission for photos and logos; public availability is not a license.
        Never invent testimonials, services, credentials, or business history.
        Keep previews access-controlled. A Vercel URL and noindex alone are not private.
        """
    }
}
