import Foundation

@MainActor
enum WorkflowExport {
    static func csv(leads: [Lead], store: LeadStore, enrichment: EnrichmentStore, workflow: WorkflowStore) -> String {
        let header = enrichment.exportCSV([], store: store).trimmingCharacters(in: .newlines)
        var rows = [header + ",Workflow category,Verified website,Manual status,Correction reason,Correction date,Next action,Offer,Template,Preview status,Repository,Preview,Contact attempts,Last outcome"]
        for lead in leads {
            let sourceRow = String(enrichment.exportCSV([lead], store: store).dropFirst(header.count + 1).dropLast())
            let p = workflow.profile(id: lead.id)
            let events = workflow.data.events.filter { $0.leadID == lead.id }.sorted { $0.date > $1.date }
            let values = [workflow.category(lead, enrichment: enrichment), p.verifiedWebsite ?? "", p.operatingOverride, p.correctionNote, p.correctedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "", p.nextAction, p.offer, p.template, p.previewStage, p.repoURL, p.previewURL, String(events.count), events.first?.outcome ?? ""]
            rows.append(sourceRow + "," + values.map(field).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }
    private static func field(_ value: String) -> String {
        let unsafe = value.first(where: { !$0.isWhitespace }).map { "=+-@".contains($0) } ?? false
        let safe = unsafe ? "'" + value : value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
