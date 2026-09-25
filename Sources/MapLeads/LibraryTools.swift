import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct LibraryBackup: Codable {
    var version = 1
    var createdAt = Date()
    var leads: [Lead]
    var enrichment: [String: EnrichmentRecord]
    var options: EnrichmentOptions
    var workflow: WorkflowData
}

@MainActor
enum LibraryOperations {
    static func backup(store: LeadStore, enrichment: EnrichmentStore, workflow: WorkflowStore) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(LibraryBackup(leads: store.leads, enrichment: enrichment.records, options: enrichment.options, workflow: workflow.data))
    }
    static func decode(_ data: Data) throws -> LibraryBackup {
        let value = try JSONDecoder().decode(LibraryBackup.self, from: data)
        guard value.version == 1, Set(value.leads.map(\.id)).count == value.leads.count,
              value.leads.allSatisfy({ !$0.id.isEmpty && !$0.title.isEmpty }),
              (6...60).contains(value.options.reviewMonths), (1...90).contains(value.options.cacheDays),
              value.workflow.preferences.minReviews >= 0,
              value.workflow.preferences.maxReviews >= value.workflow.preferences.minReviews,
              (0...5).contains(value.workflow.preferences.minRating),
              value.leads.allSatisfy({ $0.fetchedAt.timeIntervalSince1970.isFinite }) else {
            throw failure("Invalid or unsupported backup; no files changed.")
        }
        return value
    }
    static func restore(_ value: LibraryBackup, store: LeadStore, enrichment: EnrichmentStore, workflow: WorkflowStore) throws {
        guard !enrichment.busy else { throw failure("Stop enrichment before restoring.") }
        let previousLeads = store.leads
        let previousRecords = enrichment.records
        let previousOptions = enrichment.options
        let previousWorkflow = workflow.data
        var replacement = value.workflow
        // A backup cannot retract an opt-out recorded since that backup.
        for lead in previousLeads where lead.stage == "Do not contact" {
            let phone = WorkflowStore.normalizedPhone(lead.phone)
            if !phone.isEmpty && !replacement.suppressedPhones.contains(phone) { replacement.suppressedPhones.append(phone) }
            if let profile = previousWorkflow.profiles[lead.id] { replacement.profiles[lead.id] = profile }
            for event in previousWorkflow.events where event.leadID == lead.id && event.outcome == "Do not contact" {
                if !replacement.events.contains(where: { $0.id == event.id }) { replacement.events.append(event) }
            }
        }
        var restoredLeads = value.leads
        let dncIDs = Set(previousLeads.filter { $0.stage == "Do not contact" }.map(\.id))
        for i in restoredLeads.indices where dncIDs.contains(restoredLeads[i].id) { restoredLeads[i].stage = "Do not contact" }
        var restoredRecords = value.enrichment
        for (id, record) in previousRecords where record.reviewTaskID != nil { restoredRecords[id] = record }
        guard workflow.replace(replacement) else { throw failure(workflow.error ?? "Workflow restore failed") }
        guard enrichment.replaceRecords(restoredRecords) else {
            _ = workflow.replace(previousWorkflow)
            throw failure(enrichment.error ?? "Enrichment restore failed")
        }
        guard store.replaceAll(restoredLeads) else {
            _ = enrichment.replaceRecords(previousRecords)
            _ = workflow.replace(previousWorkflow)
            enrichment.options = previousOptions
            throw failure(store.error ?? "Lead restore failed; attempted rollback. Keep your safety backup.")
        }
        enrichment.options = value.options; enrichment.saveOptions()
        // Restore never enables notifications or launches a provider request.
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
    static func archive(_ leads: [Lead], workflow: WorkflowStore) throws {
        var next = workflow.data
        for lead in leads { var p = next.profiles[lead.id] ?? LeadWorkflow(); p.archived = true; next.profiles[lead.id] = p }
        guard workflow.replace(next) else { throw failure(workflow.error ?? "Archive failed") }
        let ids = leads.flatMap { ["mapleads.callback.\($0.id)", "mapleads.meeting.\($0.id)"] }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }
    static func deleteArchived(store: LeadStore, enrichment: EnrichmentStore, workflow: WorkflowStore) throws -> Int {
        let archived = store.leads.filter { workflow.profile(id: $0.id).archived }
        for lead in archived where lead.stage == "Do not contact" {
            guard workflow.suppress(lead) else { throw failure(workflow.error ?? "Could not preserve suppression") }
        }
        let ids = Set(archived.map(\.id))
        let oldRecords = enrichment.records
        // Keep pending cloud tasks: deleting a row doesn't cancel provider work.
        let retained = oldRecords.filter { !ids.contains($0.key) || $0.value.reviewTaskID != nil }
        guard enrichment.replaceRecords(retained) else { throw failure(enrichment.error ?? "Could not clean enrichment") }
        guard store.replaceAll(store.leads.filter { !ids.contains($0.id) }) else {
            _ = enrichment.replaceRecords(oldRecords)
            throw failure(store.error ?? "Could not delete archived leads")
        }
        return ids.count
    }
    static func failure(_ text: String) -> NSError { NSError(domain: "MapLeads.Library", code: 1, userInfo: [NSLocalizedDescriptionKey:text]) }
}

struct LibraryToolsView: View {
    @ObservedObject var store: LeadStore
    @ObservedObject var enrichment: EnrichmentStore
    @ObservedObject var workflow: WorkflowStore
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var pending: LibraryBackup?
    @State private var confirmRestore = false
    @State private var confirmDelete = false
    @State private var age = 90
    @State private var confirmArchive = false
    var oldLeads: [Lead] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -age, to: Date())!
        return store.leads.filter { $0.fetchedAt < cutoff && !workflow.profile(id: $0.id).archived }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Library maintenance").font(.title2.bold())
            Text("Backups include leads, enrichment evidence, contact history, manual corrections, search/job history and preferences. API keys are never included. Keep backups private.")
            HStack {
                Button("Export full backup") { exportBackup() }
                Button("Restore backup…") { chooseRestore() }
            }
            Divider()
            Stepper("Archive records last fetched over \(age) days ago", value: $age, in: 30...730, step: 30)
            Text("\(oldLeads.count) records match. Archiving hides them from active queues; it does not declare them closed. Active follow-ups and meetings may be included—review before proceeding.").font(.caption)
            Button("Archive matching records…") { confirmArchive = true }.disabled(oldLeads.isEmpty)
            Button("Delete archived research…", role: .destructive) { confirmDelete = true }
            Text("Deletion removes archived lead/source records and completed enrichment. Correction tombstones, contact history, search history, suppression records, and pending cloud task IDs remain. A future scan can rediscover the business, but it stays archived until you unarchive it.").font(.caption).foregroundStyle(.secondary)
            if !message.isEmpty { Text(message).textSelection(.enabled).font(.callout) }
            Spacer()
            Button("Done") { dismiss() }
        }.padding(28).frame(width: 640, height: 520)
        .disabled(enrichment.busy)
        .alert("Replace the local library?", isPresented: $confirmRestore) {
            Button("Cancel", role: .cancel) { pending = nil }
            Button("Restore", role: .destructive) {
                guard let pending else { return }
                do { try LibraryOperations.restore(pending, store: store, enrichment: enrichment, workflow: workflow); message = "Backup restored. Existing opt-outs retained; notifications cancelled. No provider requests started." }
                catch { message = error.localizedDescription }
                self.pending = nil
            }
        } message: { Text("A safety backup is saved before this prompt. Current opt-outs remain authoritative. Restoring changes local records; it does not cancel existing cloud jobs.") }
        .alert("Archive \(oldLeads.count) records?", isPresented: $confirmArchive) {
            Button("Cancel", role: .cancel) {}
            Button("Archive") { do { try LibraryOperations.archive(oldLeads, workflow: workflow); message = "Records archived." } catch { message = error.localizedDescription } }
        }
        .alert("Delete archived lead research?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete research", role: .destructive) {
                do { let count = try LibraryOperations.deleteArchived(store: store, enrichment: enrichment, workflow: workflow); message = "Deleted \(count) archived lead records. Suppression and history retained." }
                catch { message = error.localizedDescription }
            }
        } message: { Text("Export a backup first if you need these source records. This cannot be undone without a backup.") }
    }
    func exportBackup() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "MapLeads-backup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try LibraryOperations.backup(store: store, enrichment: enrichment, workflow: workflow).write(to: url, options: .atomic); message = "Backup saved." }
        catch { message = error.localizedDescription }
    }
    func chooseRestore() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let candidate = try LibraryOperations.decode(Data(contentsOf: url))
            let safety = LeadStore.defaultDirectory().appendingPathComponent("before-restore-\(UUID().uuidString).json")
            try LibraryOperations.backup(store: store, enrichment: enrichment, workflow: workflow).write(to: safety, options: .atomic)
            message = "Safety backup: \(safety.path)"; pending = candidate; confirmRestore = true
        } catch { message = error.localizedDescription }
    }
}
