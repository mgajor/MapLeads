import SwiftUI

/// Workspace analytics over recorded workflow data. Everything shown here is
/// grounded in persisted records; nothing is inferred or fabricated.
struct InsightsView: View {
    @ObservedObject var workflow: WorkflowStore
    @ObservedObject var store: LeadStore
    @ObservedObject var enrichment: EnrichmentStore
    let retry: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            if let error = workflow.error {
                Text(error).font(.callout).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal).padding(.vertical, 6).background(.red.opacity(0.08))
            }
            TabView {
                SearchHistoryTab(workflow: workflow)
                    .tabItem { Label("Search history", systemImage: "clock.arrow.circlepath") }
                PrioritiesTab(workflow: workflow, store: store, enrichment: enrichment)
                    .tabItem { Label("Priorities", systemImage: "slider.horizontal.3") }
                FunnelTab(workflow: workflow, store: store)
                    .tabItem { Label("Funnel", systemImage: "chart.bar.xaxis") }
                JobsTab(workflow: workflow, retry: retry)
                    .tabItem { Label("Enrichment jobs", systemImage: "wand.and.stars") }
                SuppressionTab(workflow: workflow, store: store)
                    .tabItem { Label("Suppressions", systemImage: "phone.badge.xmark") }
            }
        }.toolbar { Button("Done") { dismiss() } }
    }
}

// MARK: - Pure helpers

enum FunnelStage: String, CaseIterable, Identifiable {
    case attempted, reached, interested, meeting, proposal, won
    var id: String { rawValue }
    var title: String {
        switch self {
        case .attempted: return "Call attempted"
        case .reached: return "Reached"
        case .interested: return "Interested"
        case .meeting: return "Meeting"
        case .proposal: return "Proposal"
        case .won: return "Won"
        }
    }

    /// Maps a recorded outcome to an explicit funnel stage. Terminal and
    /// unrecognized outcomes return nil — they never imply an earlier stage.
    static func from(outcome: String) -> FunnelStage? {
        switch outcome {
        case "No answer", "Voicemail": return .attempted
        case "Reached", "Call back": return .reached
        case "Interested": return .interested
        case "Meeting booked", "Meeting held": return .meeting
        case "Proposal sent": return .proposal
        case "Won": return .won
        default: return nil
        }
    }

    /// Distinct lead IDs per stage for a set of recorded events.
    static func counts(_ events: [ContactEvent]) -> [FunnelStage: Int] {
        var sets: [FunnelStage: Set<String>] = [:]
        for event in events {
            if let stage = from(outcome: event.outcome) { sets[stage, default: []].insert(event.leadID) }
        }
        return sets.mapValues(\.count)
    }

    /// Distinct leads with recorded outcomes that map to no funnel stage.
    static func otherOutcomes(_ events: [ContactEvent]) -> Int {
        Set(events.filter { from(outcome: $0.outcome) == nil }.map(\.leadID)).count
    }
}

enum InsightsFormat {
    /// Unknown cost is never shown as zero.
    static func cost(_ value: Double?) -> String {
        value.map { String(format: "$%.2f", $0) } ?? "Not reported"
    }

    /// Comma-separated preference lists, trimmed, empties dropped.
    static func list(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func isPending(_ status: String) -> Bool {
        let s = status.lowercased()
        return s.contains("pending") || s.contains("running") || s.contains("in progress")
    }

    static func isFailed(_ status: String) -> Bool {
        let s = status.lowercased()
        return s.contains("fail") || s.contains("error") || s.contains("aborted") || s.contains("timeout")
    }

    static func isSucceeded(_ status: String) -> Bool {
        let s = status.lowercased()
        return s.contains("succeed") || s.contains("success") || s.contains("finished") || s.contains("complete") || s.contains("collected")
    }

    static func statusColor(_ status: String) -> Color {
        if isSucceeded(status) { return .green }
        if isFailed(status) { return .red }
        if isPending(status) { return .orange }
        return .secondary
    }

    static func runURL(_ runID: String) -> URL? {
        guard !runID.isEmpty,
              let url = URL(string: "https://console.apify.com/actors/runs/\(runID)") else { return nil }
        return url
    }

    static func modeLabel(_ mode: String) -> String {
        switch mode {
        case "basic": return "Basic details"
        case "detailed": return "Detailed"
        case "rich": return "Rich"
        default: return mode.isEmpty ? "Unspecified" : mode
        }
    }
}

// MARK: - Search history

private struct SearchHistoryTab: View {
    @ObservedObject var workflow: WorkflowStore

    var searches: [SearchHistory] { workflow.data.searches.sorted { $0.date > $1.date } }

    var totals: (runs: Int, returned: Int, new: Int, refreshed: Int, qualified: Int) {
        let all = workflow.data.searches
        return (all.count,
                all.reduce(0) { $0 + $1.returned },
                all.reduce(0) { $0 + $1.newCount },
                all.reduce(0) { $0 + $1.refreshedCount },
                all.reduce(0) { $0 + $1.qualifiedCount })
    }

    var body: some View {
        Group {
            if searches.isEmpty {
                ContentUnavailableView("No searches recorded", systemImage: "clock.arrow.circlepath",
                    description: Text("Every search started from this workspace is recorded here with its parameters and result counts. Runs finished before this history existed are not reconstructed — no entries are invented for them."))
            } else {
                List {
                    Section {
                        ForEach(searches) { run in
                            row(run)
                        }
                    } header: {
                        Text("Recorded runs — newest first")
                    } footer: {
                        Text("Counts are what the run actually produced. Cost is shown only when it was reported; “Not reported” is not a $0 claim.")
                    }
                    Section("Totals across \(totals.runs) recorded runs") {
                        HStack(spacing: 26) {
                            stat("Returned", "\(totals.returned)")
                            stat("New leads", "\(totals.new)")
                            stat("Refreshed", "\(totals.refreshed)")
                            stat("Qualified", "\(totals.qualified)")
                        }
                    }
                }
            }
        }
    }

    private func row(_ run: SearchHistory) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("“\(run.query)” in \(run.location)").font(.headline)
                Spacer()
                if run.completed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                Text(run.status.isEmpty ? "Unknown" : run.status)
                    .foregroundStyle(InsightsFormat.statusColor(run.status))
            }
            Text(run.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Text("Radius \(Int(run.radius)) mi")
                Text("Cap \(run.limit)")
                Text(InsightsFormat.modeLabel(run.mode))
            }.font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 26) {
                stat("Returned", "\(run.returned)")
                stat("New", "\(run.newCount)")
                stat("Refreshed", "\(run.refreshedCount)")
                stat("Qualified", "\(run.qualifiedCount)")
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Cost \(InsightsFormat.cost(run.actualCostUSD))").font(.caption)
                    if let url = InsightsFormat.runURL(run.id) {
                        Link("Open run", destination: url).font(.caption)
                    }
                }
            }
        }.padding(.vertical, 5)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.callout.bold())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Priorities

private struct PrioritiesTab: View {
    @ObservedObject var workflow: WorkflowStore
    @ObservedObject var store: LeadStore
    @ObservedObject var enrichment: EnrichmentStore

    @State private var niches = ""
    @State private var areas = ""
    @State private var templates = ""
    @State private var preferIndependent = false
    @State private var minReviews = 0
    @State private var maxReviews = 100000
    @State private var minRating = 0.0
    @State private var offer = "Any"
    @State private var message: String?
    @State private var loaded = false

    var validationError: String? {
        if minReviews < 0 { return "Minimum reviews cannot be negative." }
        if maxReviews < 0 { return "Maximum reviews cannot be negative." }
        if minReviews > maxReviews { return "Minimum reviews must not exceed the maximum." }
        if minRating < 0 || minRating > 5 { return "Minimum rating must be between 0 and 5." }
        return nil
    }

    var ranked: [(lead: Lead, score: Int, reasons: [String])] {
        store.leads.map { lead in
            let priority = workflow.priority(lead)
            return (lead, priority.score, priority.reasons)
        }.sorted { $0.score == $1.score ? $0.lead.title < $1.lead.title : $0.score > $1.score }
    }

    var body: some View {
        List {
            Section {
                TextField("Niches (comma separated)", text: $niches, prompt: Text("e.g. salons, barbers"))
                TextField("Areas (comma separated)", text: $areas, prompt: Text("e.g. Austin, Round Rock"))
                TextField("Templates (comma separated)", text: $templates, prompt: Text("e.g. salon-homepage"))
                Picker("Offer", selection: $offer) {
                    ForEach(["Any", "Website", "Existing site"], id: \.self) { Text($0).tag($0) }
                }
                Toggle("Prefer independent businesses", isOn: $preferIndependent)
                HStack {
                    TextField("Minimum reviews", value: $minReviews, format: .number)
                    TextField("Maximum reviews", value: $maxReviews, format: .number)
                }
                Stepper("Minimum rating: \(minRating, specifier: "%.1f")", value: $minRating, in: 0...5, step: 0.1)
                if let error = validationError {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
                HStack {
                    Button("Save preferences") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(validationError != nil)
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                }
            } header: {
                Text("Priority preferences")
            } footer: {
                Text("The ranked queue below follows the saved preferences. Edit and save explicitly — nothing is written until you press Save.")
            }

            Section {
                ForEach(Array(ranked.enumerated()), id: \.element.lead.id) { index, entry in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(index + 1).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            Text(entry.lead.title).font(.headline)
                            Spacer()
                            Text("\(entry.score)").font(.headline).foregroundStyle(.blue)
                        }
                        HStack {
                            Text(workflow.category(entry.lead, enrichment: enrichment)).foregroundStyle(.secondary)
                            Spacer()
                            Text(entry.lead.phone ?? "No phone").foregroundStyle(.secondary)
                        }.font(.caption)
                        if !entry.reasons.isEmpty {
                            Text(entry.reasons.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 3)
                }
            } header: {
                Text("Ranked queue — \(ranked.count) saved leads")
            } footer: {
                Text("Scores come from your saved preferences applied to listing and enrichment facts. Each line shows the recorded reasons behind the score.")
            }
        }
        .overlay {
            if store.leads.isEmpty {
                ContentUnavailableView("No saved leads", systemImage: "building.2",
                    description: Text("Search or import leads first; the priority queue ranks your saved library."))
            }
        }
        .onAppear(perform: loadDraft)
    }

    private func loadDraft() {
        guard !loaded else { return }
        loaded = true
        let preferences = workflow.data.preferences
        niches = preferences.niches
        areas = preferences.areas
        templates = preferences.templates
        preferIndependent = preferences.preferIndependent
        minReviews = preferences.minReviews
        maxReviews = preferences.maxReviews
        minRating = preferences.minRating
        offer = preferences.offer
    }

    private func save() {
        let preferences = PriorityPreferences(
            niches: niches,
            areas: areas,
            templates: templates,
            preferIndependent: preferIndependent,
            minReviews: minReviews,
            maxReviews: maxReviews,
            minRating: minRating,
            offer: offer
        )
        message = workflow.savePreferences(preferences) ? "Preferences saved." : "Could not save preferences."
    }
}

// MARK: - Funnel

private struct FunnelTab: View {
    @ObservedObject var workflow: WorkflowStore
    @ObservedObject var store: LeadStore

    @State private var breakdown = "None"
    @State private var nicheFilter = "All niches"
    @State private var areaFilter = "All areas"
    @State private var offerFilter = "All offers"

    let stageOrder: [FunnelStage] = [.attempted, .reached, .interested, .meeting, .proposal, .won]
    let stageNames = ["New", "Contacted", "Interested", "Meeting booked", "Won", "Not interested", "Do not contact"]

    var filteredEvents: [ContactEvent] {
        workflow.data.events.filter { event in
            (nicheFilter == "All niches" || (event.niche.isEmpty ? "Unspecified" : event.niche) == nicheFilter)
            && (areaFilter == "All areas" || (event.area.isEmpty ? "Unspecified" : event.area) == areaFilter)
            && (offerFilter == "All offers" || (event.offer.isEmpty ? "Unspecified" : event.offer) == offerFilter)
        }
    }

    var distinctValues: (niches: [String], areas: [String], offers: [String]) {
        let events = workflow.data.events
        func values(_ keyPath: (ContactEvent) -> String) -> [String] {
            Set(events.map { keyPath($0).isEmpty ? "Unspecified" : keyPath($0) }).sorted()
        }
        return (values(\.niche), values(\.area), values(\.offer))
    }

    var grouped: [(key: String, events: [ContactEvent])] {
        let events = filteredEvents
        switch breakdown {
        case "Niche": return group(events) { $0.niche.isEmpty ? "Unspecified" : $0.niche }
        case "Area": return group(events) { $0.area.isEmpty ? "Unspecified" : $0.area }
        case "Offer": return group(events) { $0.offer.isEmpty ? "Unspecified" : $0.offer }
        default: return [("All recorded outcomes", events)]
        }
    }

    private func group(_ events: [ContactEvent], by key: (ContactEvent) -> String) -> [(String, [ContactEvent])] {
        Dictionary(grouping: events, by: key).map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }

    var body: some View {
        List {
            Section {
                Picker("Break down by", selection: $breakdown) {
                    ForEach(["None", "Niche", "Area", "Offer"], id: \.self) { Text($0).tag($0) }
                }
                Picker("Niche", selection: $nicheFilter) {
                    Text("All niches").tag("All niches")
                    ForEach(distinctValues.niches, id: \.self) { Text($0).tag($0) }
                }
                Picker("Area", selection: $areaFilter) {
                    Text("All areas").tag("All areas")
                    ForEach(distinctValues.areas, id: \.self) { Text($0).tag($0) }
                }
                Picker("Offer", selection: $offerFilter) {
                    Text("All offers").tag("All offers")
                    ForEach(distinctValues.offers, id: \.self) { Text($0).tag($0) }
                }
            } footer: {
                Text("Filters and breakdowns use the niche, area, and offer recorded with each contact event — not guesses from listing data.")
            }

            Section {
                if workflow.data.events.isEmpty {
                    Text("No contact events recorded yet. Stages appear here only after you record call outcomes.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(grouped, id: \.key) { key, events in
                        stageBlock(title: key, events: events)
                    }
                }
            } header: {
                Text("Recorded funnel — distinct businesses per stage")
            } footer: {
                Text("Each stage counts distinct leads with at least one recorded outcome at that stage. Stages are independent, not cumulative: a later stage can outnumber an earlier one because no preceding stage is ever assumed, and no conversion rate is implied. “Other outcomes” counts leads whose recorded outcomes (e.g. wrong number, do not contact) map to no funnel stage.")
            }

            Section {
                let stock = stockByStage
                if stock.isEmpty {
                    Text("No saved leads.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(stock, id: \.0) { stage, count in
                        HStack {
                            Text(stage)
                            Spacer()
                            Text("\(count)").monospacedDigit()
                        }
                    }
                }
            } header: {
                Text("Current library — saved lead stages")
            } footer: {
                Text("This is your current stock by saved stage, not call history. A stage set manually (or imported) does not mean a call was recorded, and the two tables above are never merged or compared as a conversion.")
            }
        }
    }

    private func stageBlock(title: String, events: [ContactEvent]) -> some View {
        let counts = FunnelStage.counts(events)
        let other = FunnelStage.otherOutcomes(events)
        return VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            HStack(spacing: 26) {
                ForEach(stageOrder) { stage in
                    stat(stage.title, "\(counts[stage] ?? 0)")
                }
                stat("Other outcomes", "\(other)")
            }
        }.padding(.vertical, 5)
    }

    private var stockByStage: [(String, Int)] {
        let counts = Dictionary(grouping: store.leads, by: \.stage).mapValues(\.count)
        let known = stageNames.filter { counts[$0] != nil }.map { ($0, counts[$0]!) }
        let extra = counts.keys.filter { !stageNames.contains($0) }.sorted().map { ($0, counts[$0]!) }
        return known + extra
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.callout.bold())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Enrichment jobs

private struct JobsTab: View {
    @ObservedObject var workflow: WorkflowStore
    let retry: ([String]) -> Void

    var jobs: [EnrichmentJob] { workflow.data.jobs.sorted { $0.date > $1.date } }

    var body: some View {
        Group {
            if jobs.isEmpty {
                ContentUnavailableView("No enrichment jobs recorded", systemImage: "wand.and.stars",
                    description: Text("Each enrichment pass started from this workspace is recorded with its outcome and reported cost."))
            } else {
                List {
                    Section {
                        ForEach(jobs) { job in
                            row(job)
                        }
                    } footer: {
                        Text("Retry sends the stored lead IDs back through the workspace enrichment path — this view adds no network calls of its own. Pending and failed states come from the recorded job status.")
                    }
                }
            }
        }
    }

    private func row(_ job: EnrichmentJob) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.date.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                Spacer()
                if InsightsFormat.isPending(job.status) { ProgressView().controlSize(.small) }
                Text(job.status.isEmpty ? "Unknown" : job.status)
                    .foregroundStyle(InsightsFormat.statusColor(job.status))
            }
            if !job.summary.isEmpty {
                Text(job.summary).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Text("\(job.leadIDs.count) leads")
                Text("Cost \(InsightsFormat.cost(job.actualCostUSD))")
                Spacer()
                if InsightsFormat.isFailed(job.status) {
                    Button("Retry failed job") { retry(job.leadIDs) }
                        .buttonStyle(.borderedProminent)
                        .disabled(job.leadIDs.isEmpty)
                } else {
                    Button("Resume / retry") { retry(job.leadIDs) }
                        .disabled(job.leadIDs.isEmpty)
                }
            }.font(.caption)
        }.padding(.vertical, 5)
    }
}

// MARK: - Suppressions

private struct SuppressionTab: View {
    @ObservedObject var workflow: WorkflowStore
    @ObservedObject var store: LeadStore

    @State private var query = ""
    @State private var pendingPhone: String?
    @State private var message: String?

    var filtered: [String] {
        workflow.data.suppressedPhones
            .filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
            .sorted()
    }

    var body: some View {
        Group {
            if workflow.data.suppressedPhones.isEmpty {
                ContentUnavailableView("No suppressed numbers", systemImage: "phone.badge.xmark",
                    description: Text("Numbers suppressed from calling appear here. Suppressions survive library deletions and imports."))
            } else {
                List {
                    Section {
                        ForEach(filtered, id: \.self) { phone in
                            row(phone)
                        }
                    } header: {
                        Text("Suppressed numbers — \(filtered.count) shown")
                    } footer: {
                        Text("Removing a suppression re-enables phone matching for that number only. It does not change any lead: a business marked “Do not contact” stays excluded until its stage is changed in the lead panel, and library deletes never erase suppressions.")
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search suppressed numbers")
        .confirmationDialog(
            "Remove suppression for \(pendingPhone ?? "")?",
            isPresented: Binding(get: { pendingPhone != nil }, set: { if !$0 { pendingPhone = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove suppression", role: .destructive) {
                if let phone = pendingPhone {
                    if workflow.removeSuppression(phone: phone) {
                        message = "Suppression removed for \(phone). Leads marked “Do not contact” keep that stage until you change it."
                    } else {
                        message = "Could not remove the suppression."
                    }
                }
                pendingPhone = nil
            }
            Button("Cancel", role: .cancel) { pendingPhone = nil }
        } message: {
            Text("The number will be eligible for calling and enrichment again. Lead-specific do-not-contact stages are untouched and still apply until changed.")
        }
        .overlay(alignment: .top) {
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
        }
    }

    private func row(_ phone: String) -> some View {
        let matched = leads(matching: phone)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(phone).font(.callout.monospaced())
                Spacer()
                Button("Remove…") { pendingPhone = phone }
            }
            if matched.isEmpty {
                Text("No saved lead currently matches this number.").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(matched.map(\.title).joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
            }
            if let lead = matched.first, lead.stage == "Do not contact" {
                Text("This lead is also marked “Do not contact”; that stage remains after removal until changed.")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }.padding(.vertical, 3)
    }

    private func leads(matching phone: String) -> [Lead] {
        let normalized = WorkflowStore.normalizedPhone(phone)
        return store.leads.filter { WorkflowStore.normalizedPhone($0.phone) == normalized }
    }
}
