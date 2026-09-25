import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct MapLeadsApp: App {
    @StateObject private var store = LeadStore()
    var body: some Scene {
        Window("MapLeads", id: "workspace") {
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
    func search(query: String, location: String, radius: Double, limit: Int, mode: String, budget: Double, store: LeadStore, workflow: WorkflowStore, enrichment: EnrichmentStore) async {
        busy = true
        defer { busy = false }
        do {
            message = "Starting paid Apify run…"
            let run = try await ApifyClient(token: token).start(query: query, location: location, radius: radius, maxResults: limit, mode: mode, budget: budget)
            runID = run.id
            UserDefaults.standard.set(runID, forKey: "pendingRun")
            let history = SearchHistory(id: run.id, date: Date(), query: query, location: location, radius: radius, limit: limit, mode: mode, status: run.status)
            guard workflow.saveSearch(history) else { self.error = workflow.error; return }
            try await collect(store: store, workflow: workflow, enrichment: enrichment)
        } catch { self.error = error.localizedDescription; message = "Search interrupted. If a run ID is present, resume it rather than starting again. Check Apify Console before retrying an uncertain start." }
    }
    func resume(store: LeadStore, workflow: WorkflowStore, enrichment: EnrichmentStore) async {
        busy = true
        defer { busy = false }
        do { try await collect(store: store, workflow: workflow, enrichment: enrichment) } catch { self.error = error.localizedDescription }
    }
    private func collect(store: LeadStore, workflow: WorkflowStore, enrichment: EnrichmentStore) async throws {
        let client = ApifyClient(token: token)
        while true {
            let run = try await client.getRun(runID)
            message = "\(run.status): \(run.statusMessage ?? run.id)"
            if run.terminal {
                let leads = run.defaultDatasetId.isEmpty ? [] : try await client.results(run.defaultDatasetId)
                let incomingIDs = Set(leads.map(\.id))
                let existingIDs = Set(store.leads.map(\.id))
                var history = workflow.data.searches.first { $0.id == run.id } ?? SearchHistory(id: run.id, date: Date(), query: "Unknown (resumed legacy run)", location: "Unknown", radius: 0, limit: 0, mode: "Unknown", status: run.status)
                if !history.completed {
                    history.returned = leads.count
                    history.newCount = incomingIDs.subtracting(existingIDs).count
                    history.refreshedCount = incomingIDs.intersection(existingIDs).count
                    history.status = run.status
                    history.qualifiedCount = leads.filter { ["Website opportunities", "Existing-site opportunities"].contains(workflow.category($0, enrichment: enrichment)) }.count
                    guard workflow.saveSearch(history) else { self.error = workflow.error; return }
                }
                store.merge(leads)
                guard store.error == nil else { return }
                history.completed = true
                history.actualCostUSD = run.usageTotalUsd
                guard workflow.saveSearch(history) else { self.error = workflow.error; return }
                message = "\(run.status) · \(history.newCount) new · \(history.refreshedCount) refreshed · \(history.returned) returned.\(run.status == "SUCCEEDED" ? "" : " Results may be partial.")"
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
    @StateObject private var workflow = WorkflowStore()
    @State private var showCallQueue = false
    @State private var showInsights = false
    @State private var showLibrary = false
    @State private var enrichmentTargets: [Lead] = []
    @State private var confirmEnrichment = false
    @State private var forceEnrichment = false
    @State private var replaceFailedTasks = false
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
    private let buckets = ["All leads", "Website opportunities", "Existing-site opportunities", "Due today", "Overdue", "Needs verification", "Inactive / stale leads", "Excluded", "Follow-ups", "Archived"]
    var filtered: [Lead] {
        store.leads.filter { lead in
            let category = workflow.category(lead, enrichment: enrichment)
            let effective = workflow.effective(lead)
            let eligibleCallback = !["Excluded", "Archived", "Inactive / stale leads"].contains(category)
            let today = Calendar.current.startOfDay(for: Date())
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
            let dueToday = lead.followUp.map { $0 >= today && $0 < tomorrow } ?? false
            let overdue = lead.followUp.map { $0 < today } ?? false
            let matchesBucket = (bucket == "All leads" && category != "Archived") || category == bucket || (bucket == "Follow-ups" && lead.followUp != nil && eligibleCallback) || (bucket == "Due today" && dueToday && eligibleCallback) || (bucket == "Overdue" && overdue && eligibleCallback)
            let websiteMatches = websiteFilter == "Any website" || (websiteFilter == "No website listed" && effective.websiteKnown && effective.website == nil) || (websiteFilter == "Website present" && effective.website != nil) || (websiteFilter == "Website unknown" && !effective.websiteKnown)
            return matchesBucket && websiteMatches && (!phoneOnly || effective.phone != nil) && (!operationalOnly || effective.businessStatus == "OPERATIONAL") && (stageFilter == "Any stage" || lead.stage == stageFilter) && (search.isEmpty || "\(lead.title) \(lead.address ?? "") \(lead.categories.joined(separator: " "))".localizedCaseInsensitiveContains(search))
        }.sorted {
            if ["Due today", "Overdue", "Follow-ups"].contains(bucket), $0.followUp != $1.followUp { return ($0.followUp ?? .distantFuture) < ($1.followUp ?? .distantFuture) }
            let a = workflow.priority($0).score, b = workflow.priority($1).score
            return a == b ? ($0.score == $1.score ? $0.title < $1.title : $0.score > $1.score) : a > b
        }
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
                        ForEach(["Any stage", "New", "Contacted", "Interested", "Meeting booked", "Meeting held", "Proposal sent", "Won", "Not interested", "Do not contact"], id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                    Toggle("Has phone", isOn: $phoneOnly)
                    Toggle("Operational status", isOn: $operationalOnly)
                }.font(.caption)
                Text("\(store.leads.count) saved businesses").font(.caption).foregroundStyle(.secondary)
                Button("Settings", systemImage: "gearshape") { showSettings = true }.disabled(enrichment.busy)
                Button("Call queue", systemImage: "phone") { showCallQueue = true }.disabled(enrichment.busy || session.busy)
                Button("Insights & history", systemImage: "chart.bar") { showInsights = true }.disabled(enrichment.busy || session.busy)
                Button("Library tools", systemImage: "externaldrive") { showLibrary = true }.disabled(enrichment.busy || session.busy)
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
                                Button("Resume / collect") { Task { await session.resume(store: store, workflow: workflow, enrichment: enrichment) } }.disabled(session.busy || session.token.isEmpty)
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
                            Text(workflow.category(lead, enrichment: enrichment)).foregroundStyle(workflow.category(lead, enrichment: enrichment) == "Website opportunities" ? .green : .secondary)
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
                    Button("Export CSV", systemImage: "square.and.arrow.up") { saveText(WorkflowExport.csv(leads: filtered, store: store, enrichment: enrichment, workflow: workflow), name: "MapLeads.csv", type: .commaSeparatedText) }.disabled(filtered.isEmpty)
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
                        Text(workflow.category(lead, enrichment: enrichment)).font(.caption.bold())
                        Spacer()
                        Button("Enrich this lead") { enrichmentTargets = [lead]; confirmEnrichment = true }
                            .disabled(!enrichment.enabled || enrichment.busy)
                    }.padding()
                    LeadDetail(lead: lead, enrichment: enrichment, workflow: workflow, store: store).disabled(enrichment.busy)
                }
            } else {
                ContentUnavailableView("Choose a business", systemImage: "person.text.rectangle", description: Text("Review evidence, plan a call, and track the next step."))
            }
        }
        .searchable(text: $search, prompt: "Search saved businesses")
        .sheet(isPresented: $showSearch) { SearchForm(session: session, store: store, workflow: workflow, enrichment: enrichment) }
        .sheet(isPresented: $showCallQueue) { CallQueueView(leads: filtered, workflow: workflow, store: store, enrichment: enrichment).frame(minWidth: 850, minHeight: 650) }
        .sheet(isPresented: $showInsights) {
            InsightsView(workflow: workflow, store: store, enrichment: enrichment, retry: { ids in
                showInsights = false
                enrichmentTargets = store.leads.filter { ids.contains($0.id) }
                confirmEnrichment = true
            }).frame(minWidth: 900, minHeight: 650)
        }
        .sheet(isPresented: $showLibrary) { LibraryToolsView(store: store, enrichment: enrichment, workflow: workflow) }
        .sheet(isPresented: $showSettings) {
            ProviderSettingsView(session: session, enrichment: enrichment)
        }
        .sheet(isPresented: $confirmEnrichment) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Enrich \(enrichmentTargets.count) businesses?").font(.title2.bold())
                Text("Enabled providers: \([enrichment.options.reviewsEnabled ? "DataForSEO" : nil, enrichment.options.firecrawlEnabled ? "Firecrawl" : nil, enrichment.options.aiEnabled ? "AI provider" : nil].compactMap { $0 }.joined(separator: ", "))")
                Text("This sends selected business facts and website excerpts to enabled providers and may incur charges. The Apify spending cap does not apply. Existing opt-outs and closed listings are skipped. Successful recent checks are reused.")
                Toggle("Refresh cached checks (additional paid requests)", isOn: $forceEnrichment)
                Toggle("Replace failed review tasks (may purchase new tasks)", isOn: $replaceFailedTasks)
                Text("Use only after inspecting provider errors. Old task IDs are retained for audit; this does not cancel cloud work.").font(.caption).foregroundStyle(.secondary)
                Text("Pending review tasks resume instead of being resubmitted. Stop finishes the current request; cloud tasks may continue.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { confirmEnrichment = false }
                    Spacer()
                    Button("Authorize enrichment") {
                        confirmEnrichment = false
                        let targets = enrichmentTargets
                        let force = forceEnrichment
                        if replaceFailedTasks && !enrichment.retireFailedReviewTasks(targets.map(\.id)) { return }
                        Task { await runEnrichment(targets, force: force) }
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(26).frame(width: 550)
        }
        .alert("Action needs attention", isPresented: Binding(get: { localError != nil || session.error != nil || store.error != nil || enrichment.error != nil || workflow.error != nil }, set: { if !$0 { localError = nil; session.error = nil; store.error = nil; enrichment.error = nil; workflow.error = nil } })) {
            Button("OK") { localError = nil; session.error = nil; store.error = nil; enrichment.error = nil; workflow.error = nil }
        } message: { Text(localError ?? session.error ?? store.error ?? enrichment.error ?? workflow.error ?? "") }
    }
    func runEnrichment(_ targets: [Lead], force: Bool) async {
        let allowed = targets.filter { !["Excluded", "Archived"].contains(workflow.category($0, enrichment: enrichment)) }
        var job = EnrichmentJob(date: Date(), leadIDs: allowed.map(\.id), status: "Running", summary: "\(targets.count - allowed.count) excluded or archived records skipped. Costs not reported; provider billing applies.")
        guard workflow.saveJob(job) else { localError = workflow.error; return }
        let confirmed = Set(allowed.filter { workflow.profile(id: $0.id).operatingOverride == "Confirmed operating" }.map(\.id))
        await enrichment.run(allowed.map(workflow.effective), force: force, confirmedOperating: confirmed)
        let failed = allowed.filter {
            guard let r = enrichment.records[$0.id] else { return false }
            return r.reviewError != nil || r.websiteError != nil || r.analysisError != nil
        }
        let pending = allowed.filter { enrichment.records[$0.id]?.reviewTaskID != nil }
        job.status = enrichment.error != nil ? "Failed" : (!failed.isEmpty ? "Needs attention" : (!pending.isEmpty ? "Pending" : "Completed"))
        if enrichment.status.hasPrefix("Stopped") { job.status = "Stopped" }
        job.summary = "\(allowed.count) selected · \(failed.count) with errors · \(pending.count) pending. \(enrichment.error ?? enrichment.status) Cost not reported."
        _ = workflow.saveJob(job)
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
    @ObservedObject var workflow: WorkflowStore
    @ObservedObject var enrichment: EnrichmentStore
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
                    Task { await session.search(query: query.trimmingCharacters(in: .whitespacesAndNewlines), location: location.trimmingCharacters(in: .whitespacesAndNewlines), radius: radius, limit: limit, mode: mode, budget: budget, store: store, workflow: workflow, enrichment: enrichment) }
                }.buttonStyle(.borderedProminent)
                    .disabled(!consent || session.token.isEmpty || session.busy || !session.runID.isEmpty || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 600)
    }
}

struct LeadDetail: View {
    let lead: Lead
    @ObservedObject var enrichment: EnrichmentStore
    @ObservedObject var workflow: WorkflowStore
    @ObservedObject var store: LeadStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(lead.title).font(.largeTitle.bold()).textSelection(.enabled)
                Text(lead.categories.joined(separator: " · ")).foregroundStyle(.secondary)
                HStack {
                    Label(workflow.category(lead, enrichment: enrichment), systemImage: "checklist")
                    Spacer()
                    Text("Score \(lead.score)").font(.headline).foregroundStyle(.blue)
                }
                Text("Priority \(workflow.priority(lead).score): \(workflow.priority(lead).reasons.joined(separator: "; "))").font(.caption).foregroundStyle(.secondary)
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
                EnrichmentDetailView(record: enrichment.records[lead.id], category: workflow.category(lead, enrichment: enrichment))
                WorkflowLeadPanel(lead: lead, workflow: workflow, store: store)
                Divider()
                DisclosureGroup("Source JSON") { Text(lead.rawJSON).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            }.padding(26)
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
}
