import SwiftUI

struct ProviderSettingsView: View {
    @ObservedObject var session: SearchSession
    @ObservedObject var enrichment: EnrichmentStore
    @Environment(\.dismiss) private var dismiss
    @State private var section = "Enrichment"
    @State private var fireToken = ""
    @State private var dfsLogin = ""
    @State private var dfsPassword = ""
    @State private var aiToken = ""
    @State private var models: [AIModel] = []
    @State private var modelSearch = ""
    @State private var message = ""
    @State private var loading = false
    var body: some View {
        HStack(spacing: 0) {
            List(["Enrichment", "Apify", "Firecrawl", "DataForSEO", "AI analysis"], id: \.self, selection: $section) { Text($0).tag($0) }.frame(width: 160)
            VStack(alignment: .leading, spacing: 16) {
                Text(section).font(.title2.bold())
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch section {
                        case "Apify":
                            Text("Discovery searches run on Apify. Enrichment is separate and optional.")
                            SecureField("Apify API token", text: $session.token)
                            Button("Save Apify token") { session.saveToken(); message = session.error ?? session.message }
                            Button("Remove Apify token") { session.token = ""; session.saveToken(); message = session.error ?? session.message }
                            Link("API token settings", destination: URL(string: "https://console.apify.com/settings/integrations")!)
                        case "Firecrawl":
                            Toggle("Enable website discovery and page retrieval", isOn: $enrichment.options.firecrawlEnabled)
                            SecureField("Firecrawl API key", text: $fireToken)
                            Button("Save Firecrawl key") { saveSecret(fireToken, "firecrawl") }
                            Button("Remove Firecrawl key") { fireToken = ""; saveSecret("", "firecrawl") }
                            Text("Uses search and scraped page content to identify likely official websites. Directory links and ambiguous matches are not treated as confirmed sites. Existing listed websites are inspected directly.")
                            Link("Firecrawl search documentation", destination: URL(string: "https://docs.firecrawl.dev/features/search")!)
                        case "DataForSEO":
                            Toggle("Enable newest-review qualification", isOn: $enrichment.options.reviewsEnabled)
                            TextField("API login", text: $dfsLogin)
                            SecureField("API password (not your account password)", text: $dfsPassword)
                            Button("Save DataForSEO credentials") {
                                do {
                                    try ProviderSecrets.save(dfsLogin.trimmingCharacters(in: .whitespacesAndNewlines), account: "dataforseo.login")
                                    try ProviderSecrets.save(dfsPassword.trimmingCharacters(in: .whitespacesAndNewlines), account: "dataforseo.password")
                                    message = "Credentials saved in Keychain."
                                } catch { message = error.localizedDescription }
                            }
                            Button("Remove DataForSEO credentials") { dfsLogin = ""; dfsPassword = ""; saveSecret("", "dataforseo.login"); saveSecret("", "dataforseo.password") }
                            Stepper("Stale after \(enrichment.options.reviewMonths) months", value: $enrichment.options.reviewMonths, in: 6...60, step: 6)
                            Text("Requests the newest reviews by business identity. Old activity is archived as inactive/stale, not declared closed. Missing dates, zero reviews, and failed checks require verification. Tasks may remain pending; rerun enrichment to collect them without resubmitting.")
                            Link("DataForSEO API access", destination: URL(string: "https://app.dataforseo.com/api-access")!)
                        case "AI analysis":
                            Toggle("Enable service-opportunity analysis", isOn: $enrichment.options.aiEnabled)
                            TextField("API base URL (including /v1 if needed)", text: $enrichment.options.llmBaseURL)
                            SecureField("API key", text: $aiToken)
                            HStack {
                                Button("Save AI key") { saveSecret(aiToken, "llm") }
                                Button("Remove AI key") { aiToken = ""; saveSecret("", "llm") }
                            }
                            TextField("Model ID (manual entry supported)", text: $enrichment.options.llmModel)
                            Button(loading ? "Refreshing…" : "Refresh models") { Task { await refreshModels() } }.disabled(loading)
                            TextField("Filter model list", text: $modelSearch)
                            ForEach(models.filter { modelSearch.isEmpty || $0.id.localizedCaseInsensitiveContains(modelSearch) || $0.name.localizedCaseInsensitiveContains(modelSearch) }) { model in
                                Button { enrichment.options.llmModel = model.id } label: {
                                    VStack(alignment: .leading) { Text(model.name); Text(model.id).font(.caption).foregroundStyle(.secondary) }
                                }.buttonStyle(.plain)
                            }
                            Text("OpenAI-compatible Chat Completions only. Refresh requests /models; a listed model is not a guarantee of account access or chat compatibility. Keys go only to the configured provider. Changing the URL changes who receives business evidence.")
                            Text("Analysis uses fresh, matched website content. Enable Firecrawl or reuse cached pages. Suggestions are hypotheses and discovery questions, not verified needs. No automatic model switching.")
                        default:
                            Text("Enable only the providers you want. Nothing runs automatically after a search or import. Use Enrich this lead or Enrich filtered list and approve the batch before requests start.")
                            Toggle("Firecrawl — website discovery", isOn: $enrichment.options.firecrawlEnabled)
                            Toggle("DataForSEO — review recency", isOn: $enrichment.options.reviewsEnabled)
                            Toggle("AI — service opportunities", isOn: $enrichment.options.aiEnabled)
                            Stepper("Reuse successful checks for \(enrichment.options.cacheDays) days", value: $enrichment.options.cacheDays, in: 1...90)
                            Text("Order: review activity → website check → optional AI analysis. Stale leads and outreach exclusions skip downstream work. Disabling a provider preserves past results but stops its requests and removes its qualification gate.")
                            Text("Provider charges are separate from Apify. There is no shared dollar cap for enrichment. Batch count and cache reuse limit requests; review provider pricing before proceeding.")
                            Text("Credentials are stored in Keychain. Enrichment evidence is saved locally in enrichment.json alongside leads.json. Selected business facts and page excerpts are sent to enabled services.")
                        }
                    }.textFieldStyle(.roundedBorder)
                }
                if !message.isEmpty { Text(message).font(.caption).textSelection(.enabled) }
                HStack {
                    Text("Options save on close; keys use their Save buttons.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { enrichment.saveOptions(); dismiss() }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 570)
        }.frame(height: 620)
        .onAppear {
            do {
                fireToken = try ProviderSecrets.load("firecrawl")
                dfsLogin = try ProviderSecrets.load("dataforseo.login")
                dfsPassword = try ProviderSecrets.load("dataforseo.password")
                aiToken = try ProviderSecrets.load("llm")
            } catch { message = error.localizedDescription }
        }
        .onDisappear { enrichment.saveOptions() }
    }
    private func saveSecret(_ value: String, _ account: String) {
        do { try ProviderSecrets.save(value.trimmingCharacters(in: .whitespacesAndNewlines), account: account); message = value.isEmpty ? "Credential removed." : "Credential saved in Keychain." }
        catch { message = error.localizedDescription }
    }
    private func refreshModels() async {
        loading = true
        defer { loading = false }
        do {
            let fetched = try await LLMClient(baseURL: enrichment.options.llmBaseURL, token: aiToken.trimmingCharacters(in: .whitespacesAndNewlines), model: enrichment.options.llmModel).models()
            models = fetched
            message = "Fetched \(models.count) models. Choose one or enter its exact ID."
        } catch { message = "Model refresh failed; existing list and selection retained. \(error.localizedDescription)" }
    }
}

struct EnrichmentDetailView: View {
    let record: EnrichmentRecord?
    let category: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enrichment · \(category)").font(.headline)
            if let record {
                if let review = record.review {
                    Text("Latest retrieved review: \(review.latestReview.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Unknown")")
                    Text(review.evidence).font(.caption)
                    Text("Review check: \(review.checkedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                }
                if let task = record.reviewTaskID { Text("Pending review task: \(task)").font(.caption).textSelection(.enabled) }
                if let value = record.reviewError { Text("Review check: \(value)").foregroundStyle(.orange) }
                if let website = record.website {
                    Text("Website check: \(website.status)").font(.subheadline.bold())
                    if let raw = website.url, let url = URL(string: raw), ["https", "http"].contains(url.scheme ?? "") { Link(raw, destination: url) }
                    ForEach(Array(website.evidence.enumerated()), id: \.offset) { _, text in Text(text).font(.caption) }
                    Text("Website check: \(website.checkedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                }
                if let value = record.websiteError { Text("Website check: \(value)").foregroundStyle(.orange) }
                if let analysis = record.analysis {
                    Text("Potential service opportunities").font(.headline)
                    ForEach(Array(analysis.opportunities.enumerated()), id: \.offset) { _, opportunity in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(opportunity.title).bold()
                            Text("Observed: \(opportunity.evidence)")
                            Text("Ask: \(opportunity.question)")
                            Text("Limitation: \(opportunity.limitation)").foregroundStyle(.secondary)
                            ForEach(opportunity.sourceURLs, id: \.self) { raw in
                                if let url = URL(string: raw), ["https", "http"].contains(url.scheme ?? "") { Link("Source: \(raw)", destination: url) }
                            }
                        }.font(.callout).padding(.vertical, 5)
                    }
                    Text("\(analysis.model) · \(analysis.checkedAt.formatted()) · AI suggestions, not verified business needs.").font(.caption).foregroundStyle(.secondary)
                }
                if let value = record.analysisError { Text("AI analysis: \(value)").foregroundStyle(.orange) }
            } else { Text("No enrichment saved. Enable providers in Settings, then enrich this lead.").foregroundStyle(.secondary) }
        }.textSelection(.enabled)
    }
}
