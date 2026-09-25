import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications

enum BusinessClock {
    static func text(_ lead: Lead, now: Date = Date()) -> String {
        guard let raw = try? JSONSerialization.jsonObject(with: Data(lead.rawJSON.utf8)) as? [String: Any],
              let name = raw["timezone"] as? String, let zone = TimeZone(identifier: name) else { return "Business local time: unknown (timezone not returned)" }
        let formatter = DateFormatter(); formatter.timeZone = zone; formatter.dateStyle = .medium; formatter.timeStyle = .short
        return "Business local time: \(formatter.string(from: now)) · \(zone.identifier)"
    }
}

// MARK: - Call outcomes

/// One dialable outcome. `id` is the exact string stored in ContactEvent and
/// must stay byte-identical to the special outcomes WorkflowStore records
/// corrections/suppressions for ("Confirmed closed", "Wrong number",
/// "Do not contact").
struct CallOutcome: Identifiable, Hashable {
    enum DateKind { case callback, meeting }

    let id: String
    let label: String
    let requiresDate: Bool
    let dateKind: DateKind?
}

enum CallOutcomeCatalog {
    static let all: [CallOutcome] = [
        CallOutcome(id: "Interested", label: "Reached · interested", requiresDate: false, dateKind: nil),
        CallOutcome(id: "Call back", label: "Reached · callback requested", requiresDate: true, dateKind: .callback),
        CallOutcome(id: "Meeting booked", label: "Meeting booked", requiresDate: true, dateKind: .meeting),
        CallOutcome(id: "No answer", label: "No answer", requiresDate: false, dateKind: nil),
        CallOutcome(id: "Voicemail", label: "Left voicemail", requiresDate: false, dateKind: nil),
        CallOutcome(id: "Not interested", label: "Reached · not interested", requiresDate: false, dateKind: nil),
        CallOutcome(id: "Wrong number", label: "Wrong number", requiresDate: false, dateKind: nil),
        CallOutcome(id: "Confirmed closed", label: "Confirmed closed", requiresDate: false, dateKind: nil),
        CallOutcome(id: "Do not contact", label: "Do not contact", requiresDate: false, dateKind: nil),
        CallOutcome(id: "Reached", label: "Reached", requiresDate: false, dateKind: nil),
        CallOutcome(id: "Meeting held", label: "Meeting held", requiresDate: false, dateKind: nil),
        CallOutcome(id: "Proposal sent", label: "Proposal sent", requiresDate: false, dateKind: nil),
        CallOutcome(id: "Won", label: "Won", requiresDate: false, dateKind: nil),
    ]

    static func outcome(id: String) -> CallOutcome {
        all.first { $0.id == id } ?? all[0]
    }
}

// MARK: - Stage rules

/// Conservative outcome-to-stage mapping. A stage is only ever advanced to
/// what the recorded outcome itself proves, never downgraded, and terminal
/// stages are never escaped by a positive outcome (only "Do not contact"
/// overrides "Not interested").
enum CallStageRules {
    static let pipeline = ["New", "Contacted", "Interested", "Meeting booked", "Meeting held", "Proposal sent", "Won"]
    static let terminal = ["Not interested", "Do not contact"]

    /// Highest of the two pipeline stages; unknown strings are left untouched.
    static func advance(_ current: String, toAtLeast floor: String) -> String {
        guard let ci = pipeline.firstIndex(of: current), let fi = pipeline.firstIndex(of: floor) else { return current }
        return ci >= fi ? current : floor
    }

    static func stage(after outcome: String, current: String) -> String {
        if terminal.contains(current) {
            return outcome == "Do not contact" ? "Do not contact" : current
        }
        switch outcome {
        case "Do not contact":
            return "Do not contact"
        case "Not interested":
            return "Not interested"
        case "Interested":
            return advance(current, toAtLeast: "Interested")
        case "Meeting booked":
            return advance(current, toAtLeast: "Meeting booked")
        case "Meeting held", "Proposal sent", "Won":
            return advance(current, toAtLeast: outcome)
        case "Call back", "Reached":
            return advance(current, toAtLeast: "Contacted")
        default:
            return current
        }
    }
}

// MARK: - Library write helper

@MainActor
enum LeadSaver {
    /// Persists one lead through the store's atomic full-library write so the
    /// caller gets a real success/failure signal (LeadStore.update returns
    /// none). Replaces in place, or appends when the lead is not stored yet.
    @discardableResult
    static func save(_ lead: Lead, in store: LeadStore) -> Bool {
        var all = store.leads
        if let index = all.firstIndex(where: { $0.id == lead.id }) {
            all[index] = lead
        } else {
            all.append(lead)
        }
        return store.replaceAll(all)
    }
}

// MARK: - ICS (RFC 5545) export

enum ICS {
    /// Escapes a TEXT property value: backslash, semicolon, comma; line breaks
    /// become the literal sequence `\n`.
    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
    }

    /// Folds one content line to 75 UTF-8 octets (RFC 5545 §3.1) with a
    /// single leading space on continuation lines. Never splits a multi-byte
    /// scalar.
    static func fold(_ line: String) -> [String] {
        var folded: [String] = []
        var current = ""
        var width = 0
        for scalar in line.unicodeScalars {
            let scalarWidth = UTF8.width(scalar)
            let limit = folded.isEmpty ? 75 : 74 // continuation reserves one octet for the space
            if !current.isEmpty && width + scalarWidth > limit {
                folded.append(current)
                current = String(scalar)
                width = scalarWidth
            } else {
                current.unicodeScalars.append(scalar)
                width += scalarWidth
            }
        }
        folded.append(current)
        return folded
    }

    /// UTC basic-format timestamp (`yyyyMMdd'T'HHmmssZ`).
    static func utc(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    /// A single-VEVENT meeting invitation. The UID is derived from the stable
    /// lead id (`mapleads.meeting.<leadID>@mapleads.local`) so re-exporting a
    /// rescheduled meeting updates the same calendar event. All lines are
    /// CRLF-terminated and folded per RFC 5545.
    static func meetingICS(lead: Lead, profile: LeadWorkflow, date: Date, durationMinutes: Int = 60, stamp: Date = Date()) -> String {
        let end = Calendar.current.date(byAdding: .minute, value: max(durationMinutes, 1), to: date) ?? date

        var description: [String] = ["Phone: \(lead.phone ?? "unknown")"]
        if !profile.offer.isEmpty { description.append("Offer: \(profile.offer)") }
        if !profile.template.isEmpty { description.append("Template: \(profile.template)") }
        if !profile.deliverables.isEmpty { description.append("Deliverables: \(profile.deliverables)") }
        if !profile.assetsAvailable.isEmpty { description.append("Assets available: \(profile.assetsAvailable)") }
        if !profile.assetsNeeded.isEmpty { description.append("Assets needed: \(profile.assetsNeeded)") }
        if !profile.questions.isEmpty { description.append("Open questions: \(profile.questions)") }
        if !profile.repoURL.isEmpty { description.append("Repo: \(profile.repoURL)") }
        if !profile.previewURL.isEmpty { description.append("Preview: \(profile.previewURL)") }
        description.append("Preview stage: \(profile.previewStage)")
        if !profile.nextAction.isEmpty { description.append("Next step: \(profile.nextAction)") }

        let properties: [(String, String)] = [
            ("UID", "mapleads.meeting.\(lead.id)@mapleads.local"),
            ("DTSTAMP", utc(stamp)),
            ("DTSTART", utc(date)),
            ("DTEND", utc(end)),
            ("SUMMARY", "Meeting — \(lead.title)"),
            ("LOCATION", lead.address ?? ""),
            ("DESCRIPTION", description.joined(separator: "\n")),
            ("STATUS", "CONFIRMED"),
        ]

        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//MapLeads//local prospect workspace//EN",
            "CALSCALE:GREGORIAN",
            "METHOD:PUBLISH",
            "BEGIN:VEVENT",
        ]
        for (name, value) in properties {
            lines.append(contentsOf: fold("\(name):\(escape(value))").enumerated().map { $0.offset == 0 ? $0.element : " " + $0.element })
        }
        lines.append(contentsOf: ["END:VEVENT", "END:VCALENDAR"])
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}

// MARK: - Brief export

enum BriefBuilder {
    /// Plain-text call & meeting brief: public listing facts, manual
    /// corrections (with the Google-side conflict), outreach state, every
    /// meeting-to-preview prep field, and recorded contact history. Unknown
    /// values are labelled, never guessed.
    static func export(lead: Lead, profile: LeadWorkflow, history: [ContactEvent], now: Date = Date()) -> String {
        func value(_ text: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Not set" : trimmed
        }
        func date(_ date: Date?) -> String {
            date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not scheduled"
        }
        let zone = TimeZone.current.identifier

        var correction = "None"
        if profile.operatingOverride != "Unchanged" || profile.verifiedWebsite != nil {
            let when = profile.correctedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "unknown date"
            correction = "\(profile.operatingOverride) — \(profile.correctionNote.isEmpty ? "no reason recorded" : profile.correctionNote) (\(when))"
        }
        if profile.archived { correction += "\nArchived: Yes" }

        let listedWebsite = lead.website ?? (lead.websiteKnown ? "None listed on Maps" : "Unknown — field not returned")

        let historyText: String
        if history.isEmpty {
            historyText = "No contact events recorded."
        } else {
            historyText = history
                .map { event in
                    "\(event.date.formatted(date: .abbreviated, time: .shortened)) — \(event.outcome)\(event.note.isEmpty ? "" : " · \(event.note)")"
                }
                .joined(separator: "\n")
        }

        return """
        MAPLEADS CALL & MEETING BRIEF
        \(lead.title)
        Generated \(now.formatted(date: .abbreviated, time: .shortened)) — times shown in \(zone)

        LISTING FACTS (public, as returned by Google Maps)
        Categories: \(lead.categories.isEmpty ? "Unknown" : lead.categories.joined(separator: ", "))
        Phone: \(lead.phone ?? "Unknown")
        Address: \(lead.address ?? "Unknown")
        Listed website: \(listedWebsite)
        Business status (Google): \(lead.businessStatus ?? "Unknown")
        Rating: \(lead.rating.map { String(format: "%.1f", $0) } ?? "Unknown") across \(lead.reviewCount.map(String.init) ?? "unknown") reviews
        Hours: \(lead.hours.isEmpty ? "Unknown" : lead.hours.joined(separator: "; "))
        Maps: \(lead.mapsURL ?? "Unknown")
        Listing fetched: \(lead.fetchedAt.formatted(date: .abbreviated, time: .shortened))

        MANUAL CORRECTIONS
        \(correction)
        Verified website: \(profile.verifiedWebsite ?? "Not set")

        OUTREACH
        Stage: \(lead.stage)
        Next action: \(value(profile.nextAction))
        Follow-up: \(date(lead.followUp))
        Meeting: \(date(lead.meeting))
        Reminders: \(profile.notificationsEnabled ? "On" : "Off")

        MEETING-TO-PREVIEW PREP
        Preview stage: \(profile.previewStage)
        Template: \(value(profile.template))
        Offer: \(value(profile.offer))
        Deliverables: \(value(profile.deliverables))
        Assets available: \(value(profile.assetsAvailable))
        Assets needed: \(value(profile.assetsNeeded))
        Open questions: \(value(profile.questions))
        Repo URL: \(value(profile.repoURL))
        Preview URL: \(value(profile.previewURL))

        CONTACT HISTORY (recorded events only, newest first)
        \(historyText)

        NOTES
        \(lead.notes.isEmpty ? "None" : lead.notes)

        Dates are shown in this Mac's timezone (\(zone)).
        \(BusinessClock.text(lead, now: now))
        History lists only recorded contact events — nothing is inferred.
        """
    }
}

// MARK: - Notifications

/// Local reminder scheduling over UNUserNotificationCenter with one stable
/// identifier per lead and purpose:
///   mapleads.callback.<leadID>
///   mapleads.meeting.<leadID>
/// Authorization is only ever requested from a direct user action (the toggle).
enum LeadNotifications {
    struct Scheduled: Identifiable, Equatable {
        let id: String
        let kind: String
        let fireDate: Date
    }

    static func callbackIdentifier(_ leadID: String) -> String { "mapleads.callback.\(leadID)" }
    static func meetingIdentifier(_ leadID: String) -> String { "mapleads.meeting.\(leadID)" }

    /// Requests permission. Call only from a user action (the reminder toggle).
    @discardableResult
    static func requestAuthorization() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    /// Removes every pending reminder for this lead. Synchronous; call on
    /// suppression, closure, wrong number, or opt-out.
    static func cancel(leadID: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: [callbackIdentifier(leadID), meetingIdentifier(leadID)]
        )
    }

    /// Makes pending reminders match the current lead + profile exactly:
    /// removes both stable identifiers, then re-adds only what is still
    /// schedulable — opted in, stage not terminal, no closure/wrong-number
    /// correction, authorized, and in the future. Throws (surfaced by the
    /// caller) when authorization is missing or scheduling fails, after the
    /// stale requests have already been removed.
    @discardableResult
    static func reconcile(lead: Lead, profile: LeadWorkflow, now: Date = Date()) async throws -> [Scheduled] {
        let identifiers = [callbackIdentifier(lead.id), meetingIdentifier(lead.id)]
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)

        guard profile.notificationsEnabled else { return [] }
        guard !CallStageRules.terminal.contains(lead.stage) else { return [] }
        guard !profile.archived, !["Confirmed closed", "Wrong number", "Not a fit"].contains(profile.operatingOverride) else { return [] }

        let status = await authorizationStatus()
        guard status == .authorized || status == .provisional else {
            throw NSError(
                domain: "MapLeads.Notifications",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Reminders are not allowed for MapLeads. Enable them in System Settings → Notifications, then turn the reminder toggle off and on again."]
            )
        }

        var scheduled: [Scheduled] = []
        if let followUp = lead.followUp, followUp > now {
            let content = UNMutableNotificationContent()
            content.title = "Callback: \(lead.title)"
            var body = "Next step: \(profile.nextAction.isEmpty ? "not set" : profile.nextAction)"
            if let phone = lead.phone { body += " · \(phone)" }
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: callbackIdentifier(lead.id), content: content, trigger: trigger(for: followUp))
            try await add(request)
            scheduled.append(Scheduled(id: request.identifier, kind: "Callback", fireDate: followUp))
        }
        if let meeting = lead.meeting, meeting > now {
            let content = UNMutableNotificationContent()
            content.title = "Meeting: \(lead.title)"
            var body = "Preview stage: \(profile.previewStage)"
            if !profile.offer.isEmpty { body += " · \(profile.offer)" }
            if let phone = lead.phone { body += " · \(phone)" }
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: meetingIdentifier(lead.id), content: content, trigger: trigger(for: meeting))
            try await add(request)
            scheduled.append(Scheduled(id: request.identifier, kind: "Meeting", fireDate: meeting))
        }
        return scheduled
    }

    static func summary(_ scheduled: [Scheduled]) -> String {
        guard !scheduled.isEmpty else { return "Reminders up to date — none scheduled." }
        return "Reminders: " + scheduled
            .map { "\($0.kind) \($0.fireDate.formatted(date: .abbreviated, time: .shortened))" }
            .joined(separator: " · ")
    }

    private static func trigger(for date: Date) -> UNNotificationTrigger {
        var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        components.calendar = Calendar.current
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }

    private static func add(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

// MARK: - Shared call workflow actions

@MainActor
enum CallWorkflowActions {
    static let callableCategories = ["Website opportunities", "Existing-site opportunities"]

    /// Eligible for a cold call right now: phone present, stage not terminal,
    /// number not suppressed, and the live workflow category is a call bucket.
    static func isEligible(_ lead: Lead, workflow: WorkflowStore, enrichment: EnrichmentStore) -> Bool {
        eligibilityReason(lead, workflow: workflow, enrichment: enrichment) == nil
    }

    /// nil when callable; otherwise the human reason it is not (used to block
    /// the queue and explain why).
    static func eligibilityReason(_ lead: Lead, workflow: WorkflowStore, enrichment: EnrichmentStore) -> String? {
        guard let phone = lead.phone, !phone.isEmpty else { return "No phone number on the listing." }
        if CallStageRules.terminal.contains(lead.stage) { return "Stage is “\(lead.stage)”." }
        if workflow.data.suppressedPhones.contains(WorkflowStore.normalizedPhone(phone)) {
            return "Phone number is suppressed (do-not-contact list)."
        }
        let category = workflow.category(lead, enrichment: enrichment)
        if !callableCategories.contains(category) { return "Live category is “\(category)”." }
        return nil
    }

    /// http(s) URL with a host, or nothing.
    static func isValidHTTPURL(_ text: String) -> Bool {
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty
        else { return false }
        return true
    }

    /// Records one call outcome end to end. The library write must succeed
    /// before history is appended, so a failed save never leaves a fabricated
    /// ContactEvent. Returns nil on success, or an error message the caller
    /// must surface (never show save-success when this returns non-nil).
    static func recordOutcome(
        _ outcome: CallOutcome,
        note: String,
        date: Date?,
        lead: Lead,
        workflow: WorkflowStore,
        store: LeadStore,
        onNotificationError: ((String) -> Void)? = nil
    ) -> String? {
        if outcome.requiresDate && date == nil {
            return "“\(outcome.label)” needs a date before it can be saved."
        }
        guard let phone = lead.phone, !phone.isEmpty else {
            return "No phone number on this listing; there is nothing to call."
        }
        if CallStageRules.terminal.contains(lead.stage) {
            return "Refused: this business is marked “\(lead.stage)”."
        }
        if workflow.data.suppressedPhones.contains(WorkflowStore.normalizedPhone(phone)) {
            return "Refused: this phone number is suppressed."
        }

        var updated = lead
        updated.stage = CallStageRules.stage(after: outcome.id, current: lead.stage)
        switch outcome.dateKind {
        case .callback: updated.followUp = date
        case .meeting: updated.meeting = date
        case nil: break
        }
        if outcome.id == "Do not contact" {
            updated.followUp = nil
            updated.meeting = nil
        }

        if outcome.id == "Do not contact" && !workflow.suppress(lead) { return workflow.error ?? "Could not save phone suppression." }
        guard LeadSaver.save(updated, in: store) else {
            return store.error ?? "The lead library could not be written; nothing was recorded."
        }
        guard workflow.record(outcome: outcome.id, note: note, lead: updated) else {
            return workflow.error ?? "The call was saved to the library, but the contact history entry could not be recorded."
        }

        if ["Do not contact", "Wrong number", "Confirmed closed"].contains(outcome.id) {
            LeadNotifications.cancel(leadID: lead.id)
            if outcome.id == "Do not contact" {
                let phone = WorkflowStore.normalizedPhone(lead.phone)
                for other in store.leads where WorkflowStore.normalizedPhone(other.phone) == phone { LeadNotifications.cancel(leadID: other.id) }
            }
            return nil
        }

        let leadID = lead.id
        let profile = workflow.profile(id: leadID)
        if profile.notificationsEnabled {
            Task { @MainActor in
                let live = store.leads.first { $0.id == leadID } ?? updated
                do {
                    _ = try await LeadNotifications.reconcile(lead: live, profile: profile)
                } catch {
                    onNotificationError?("Reminders could not be updated: \(error.localizedDescription)")
                }
            }
        }
        return nil
    }
}

// MARK: - Per-business panel

struct WorkflowLeadPanel: View {
    let lead: Lead
    @ObservedObject var workflow: WorkflowStore
    @ObservedObject var store: LeadStore

    @State private var outcomeID = CallOutcomeCatalog.all[0].id
    @State private var callNote = ""
    @State private var callbackDate = Date()
    @State private var outcomeMeetingDate = Date()

    @State private var nextAction = ""
    @State private var hasFollowUp = false
    @State private var followUpDate = Date()

    @State private var operatingOverride = "Unchanged"
    @State private var correctionNote = ""
    @State private var verifiedWebsite = ""
    @State private var archived = false

    @State private var hasMeeting = false
    @State private var meetingDate = Date()
    @State private var previewStage = "Not started"
    @State private var template = ""
    @State private var offer = ""
    @State private var deliverables = ""
    @State private var assetsAvailable = ""
    @State private var assetsNeeded = ""
    @State private var questions = ""
    @State private var repoURL = ""
    @State private var previewURL = ""

    @State private var notes = ""
    @State private var notificationsOn = false

    @State private var message: String?
    @State private var errorMessage: String?
    @State private var reminderMessage: String?
    @State private var reminderError: String?
    @State private var showLostEdits = false
    @State private var lostDraft = ""
    @State private var confirmRemoveSuppression = false

    private let overrides = ["Unchanged", "Confirmed operating", "Confirmed closed", "Wrong number", "Not a fit"]
    private let previewStages = ["Not started", "Draft ready", "Reviewed", "Private preview ready", "Meeting held"]
    private var selectedOutcome: CallOutcome { CallOutcomeCatalog.outcome(id: outcomeID) }

    /// Always the store's current copy, never the snapshot handed in.
    private var current: Lead { store.leads.first { $0.id == lead.id } ?? lead }
    private var savedProfile: LeadWorkflow { workflow.profile(id: current.id) }
    private var history: [ContactEvent] {
        workflow.data.events
            .filter { $0.leadID == current.id }
            .sorted { $0.date > $1.date }
    }
    private var isSuppressed: Bool {
        guard let phone = current.phone else { return false }
        return workflow.data.suppressedPhones.contains(WorkflowStore.normalizedPhone(phone))
    }

    var body: some View {
        VStack {
            VStack(alignment: .leading, spacing: 22) {
                header

                Text("Nothing here saves until you press a Save button. Unsaved edits are kept while you switch businesses — you will be asked before they are dropped.")
                    .font(.caption).foregroundStyle(.secondary)

                logCallSection
                historySection
                nextStepSection
                correctionsSection
                handoffSection
                notificationsSection
                notesSection
                GroupBox("Manual outreach stage") {
                    VStack(alignment: .leading) {
                        Picker("Stage", selection: Binding(get: { current.stage }, set: { value in
                            var updated = current
                            if value == "Do not contact" && !workflow.suppress(updated) { errorMessage = workflow.error; return }
                            updated.stage = value
                            guard LeadSaver.save(updated, in: store) else { errorMessage = store.error; return }
                            if ["Interested", "Meeting booked", "Meeting held", "Proposal sent", "Won", "Not interested", "Do not contact"].contains(value) {
                                _ = workflow.record(outcome: value, note: "Manually recorded stage", lead: updated)
                            }
                            reconcileReminders()
                        })) {
                            ForEach(CallStageRules.pipeline + CallStageRules.terminal, id: \.self) { Text($0).tag($0) }
                        }
                        Text("Changes save immediately. Resetting a stage does not remove phone suppression; use the separate confirmed removal action.").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Text("Dates and reminders use this Mac's timezone (\(TimeZone.current.identifier)). \(BusinessClock.text(current))")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(26)
        }
        .onAppear { load(from: current) }
        .onChange(of: lead.id) { oldID, _ in
            if isDirty(leadID: oldID) {
                lostDraft = draftText(leadID: oldID)
                showLostEdits = true
            }
            load(from: current)
        }
        .confirmationDialog("Unsaved edits", isPresented: $showLostEdits, titleVisibility: .visible) {
            Button("Copy draft to clipboard") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lostDraft, forType: .string)
                message = "Draft copied to the clipboard."
            }
            Button("Drop the edits", role: .destructive) {}
        } message: {
            Text("Edits for the previous business were not saved. Copy them now if you want to keep anything.")
        }
        .confirmationDialog("Remove suppression?", isPresented: $confirmRemoveSuppression, titleVisibility: .visible) {
            Button("Remove suppression", role: .destructive) {
                guard let phone = current.phone else { return }
                if workflow.removeSuppression(phone: WorkflowStore.normalizedPhone(phone)) {
                    message = "Suppression removed for \(WorkflowStore.normalizedPhone(phone))."
                    errorMessage = nil
                } else {
                    errorMessage = workflow.error ?? "The suppression could not be removed."
                    message = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This phone number will become callable again. Recorded history is not changed.")
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(current.title).font(.largeTitle.bold()).textSelection(.enabled)
            Text(current.categories.joined(separator: " · ")).foregroundStyle(.secondary)
            HStack {
                let priority = workflow.priority(current)
                Label("Priority \(priority.score)", systemImage: "flag")
                Spacer()
                Text("Stage: \(current.stage)").font(.caption)
            }
            if isSuppressed {
                HStack {
                    Label("Phone suppressed — calls are blocked", systemImage: "nosign").foregroundStyle(.orange)
                    Spacer()
                    Button("Remove suppression…") { confirmRemoveSuppression = true }
                }.padding(8).background(.orange.opacity(0.08)).cornerRadius(6)
            }
            DisclosureGroup("Why this priority") {
                ForEach(workflow.priority(current).reasons, id: \.self) { Text("• \($0)").font(.callout) }
            }.font(.subheadline)
            feedback
        }
    }

    private var logCallSection: some View {
        GroupBox("Log a call") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Outcome", selection: $outcomeID) {
                    ForEach(CallOutcomeCatalog.all) { outcome in
                        Text(outcome.label).tag(outcome.id)
                    }
                }
                if let kind = selectedOutcome.dateKind {
                    DatePicker(
                        kind == .callback ? "Callback date & time" : "Meeting date & time",
                        selection: kind == .callback ? $callbackDate : $outcomeMeetingDate
                    )
                }
                TextField("Call note (recorded in history)", text: $callNote, axis: .vertical)
                    .lineLimit(1...4)
                HStack {
                    Button("Save outcome") { saveOutcome() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSuppressed || CallStageRules.terminal.contains(current.stage))
                    Text("“\(selectedOutcome.label)” is stored exactly as the contact event outcome.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if isSuppressed || CallStageRules.terminal.contains(current.stage) {
                    Text("Save is blocked: this lead is suppressed or asked not to be contacted.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    private var historySection: some View {
        GroupBox("Contact history (append-only)") {
            VStack(alignment: .leading, spacing: 8) {
                if history.isEmpty {
                    Text("No contact events recorded yet.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(history) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(event.outcome).font(.callout.bold())
                                Spacer()
                                Text(event.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if !event.note.isEmpty {
                                Text(event.note).font(.callout).textSelection(.enabled)
                            }
                        }.padding(.vertical, 3)
                        Divider()
                    }
                    Text("History never rewrites or deletes earlier entries.").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    private var nextStepSection: some View {
        GroupBox("Next step & callback") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Next action (shown in the reminder)", text: $nextAction)
                Toggle("Schedule follow-up", isOn: $hasFollowUp)
                if hasFollowUp {
                    DatePicker("Follow-up", selection: $followUpDate)
                }
                HStack {
                    Button("Save next step") { saveNextStep() }
                    if let followUp = current.followUp, hasFollowUp == false {
                        Text("Stored follow-up: \(followUp.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    private var correctionsSection: some View {
        GroupBox("Manual corrections") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Operating status", selection: $operatingOverride) {
                    ForEach(overrides, id: \.self) { Text($0).tag($0) }
                }
                TextField("Reason (required for any correction)", text: $correctionNote)
                TextField(
                    "Verified website (https://…)",
                    text: $verifiedWebsite,
                    prompt: Text("Leave empty for none")
                )
                if let site = websiteValue, !CallWorkflowActions.isValidHTTPURL(site) {
                    Label("Verified website must be an http(s) URL.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let conflict = statusConflict {
                    Label(conflict, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let conflict = websiteConflict {
                    Label(conflict, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle("Archive this lead (kept, out of active work)", isOn: $archived)
                if let correctedAt = savedProfile.correctedAt, savedProfile.operatingOverride != "Unchanged" || savedProfile.verifiedWebsite != nil {
                    Text("Last correction saved \(correctedAt.formatted(date: .abbreviated, time: .shortened)).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Save corrections") { saveCorrections() }
                    .disabled(!correctionsDirty || !correctionsValid)
                if correctionsDirty && !correctionsValid {
                    Text("A reason is required before a correction can be saved.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    private var handoffSection: some View {
        GroupBox("Meeting → preview handoff") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Meeting booked", isOn: $hasMeeting)
                if hasMeeting {
                    DatePicker("Meeting", selection: $meetingDate)
                }
                Picker("Preview stage", selection: $previewStage) {
                    ForEach(previewStages, id: \.self) { Text($0).tag($0) }
                }
                TextField("Template", text: $template)
                TextField("Offer", text: $offer)
                TextField("Deliverables", text: $deliverables, axis: .vertical).lineLimit(1...3)
                TextField("Assets available", text: $assetsAvailable, axis: .vertical).lineLimit(1...3)
                TextField("Assets still needed", text: $assetsNeeded, axis: .vertical).lineLimit(1...3)
                TextField("Open questions", text: $questions, axis: .vertical).lineLimit(1...3)
                TextField("Repo URL", text: $repoURL)
                TextField("Preview URL", text: $previewURL)
                if let invalid = invalidHandoffURL {
                    Label(invalid, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Save handoff") { saveHandoff() }
                        .disabled(invalidHandoffURL != nil)
                        .buttonStyle(.borderedProminent)
                    Button("Export brief…") { exportBrief() }
                    Button("Export meeting .ics…") { exportICS() }
                        .disabled(!hasMeeting)
                }
                Text("The .ics uses the stable UID mapleads.meeting.\(current.id)@mapleads.local — re-exporting a rescheduled meeting updates the same calendar event.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    private var notificationsSection: some View {
        GroupBox("Reminders") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Remind me about callbacks and meetings", isOn: Binding(
                    get: { notificationsOn },
                    set: { setReminders($0) }
                ))
                if let reminderMessage {
                    Text(reminderMessage).font(.caption).foregroundStyle(.green)
                }
                if let reminderError {
                    Text(reminderError).font(.caption).foregroundStyle(.orange)
                }
                Text("Permission is requested only when you turn this on. Reminders use stable identifiers and are cancelled automatically when the lead is suppressed, confirmed closed, a wrong number, or the toggle is turned off. They fire in this Mac's timezone.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    private var notesSection: some View {
        GroupBox("Working notes") {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $notes).font(.body).frame(minHeight: 100)
                    .padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.gray.opacity(0.3)))
                HStack {
                    Button("Save notes") { saveNotes() }
                    if notes != current.notes {
                        Text("Unsaved").font(.caption).foregroundStyle(.orange)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }

    @ViewBuilder private var feedback: some View {
        if let errorMessage {
            Text(errorMessage).font(.callout).foregroundStyle(.red).textSelection(.enabled)
        }
        if let message {
            Text(message).font(.callout).foregroundStyle(.green)
        }
    }

    // MARK: Corrections helpers

    private var websiteValue: String? {
        let trimmed = verifiedWebsite.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var correctionsDirty: Bool {
        let p = savedProfile
        if p.operatingOverride != operatingOverride || p.verifiedWebsite != websiteValue || p.archived != archived {
            return true
        }
        let hasCorrection = p.operatingOverride != "Unchanged" || p.verifiedWebsite != nil
        return hasCorrection && p.correctionNote != correctionNote.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var correctionsValid: Bool {
        if let site = websiteValue, !CallWorkflowActions.isValidHTTPURL(site) { return false }
        if correctionsDirty && correctionNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return true
    }

    /// Conflict between the manual correction and the raw Google field.
    private var statusConflict: String? {
        let google = current.businessStatus ?? "not returned"
        switch operatingOverride {
        case "Confirmed operating" where current.businessStatus != "OPERATIONAL":
            return "Source conflict: Google status is \(google); your correction says operating. Your correction is used locally."
        case "Confirmed closed" where !["CLOSED_PERMANENTLY", "CLOSED_TEMPORARILY"].contains(current.businessStatus ?? ""):
            return "Source conflict: Google status is \(google); your correction says closed. Your correction is used locally."
        default:
            return nil
        }
    }

    private var websiteConflict: String? {
        guard
            let site = websiteValue,
            let listed = current.website,
            let siteHost = URLComponents(string: site)?.host?.lowercased(),
            let listedHost = URLComponents(string: listed)?.host?.lowercased(),
            siteHost != listedHost
        else { return nil }
        return "Source conflict: verified website (\(siteHost)) differs from the Maps listing (\(listedHost))."
    }

    private var invalidHandoffURL: String? {
        for (label, value) in [("Repo URL", repoURL), ("Preview URL", previewURL)] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !CallWorkflowActions.isValidHTTPURL(trimmed) {
                return "\(label) must be an http(s) URL."
            }
        }
        return nil
    }

    // MARK: Actions

    private func load(from lead: Lead) {
        let p = workflow.profile(id: lead.id)
        nextAction = p.nextAction
        hasFollowUp = lead.followUp != nil
        followUpDate = lead.followUp ?? Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        operatingOverride = p.operatingOverride
        correctionNote = p.correctionNote
        verifiedWebsite = p.verifiedWebsite ?? ""
        archived = p.archived
        hasMeeting = lead.meeting != nil
        meetingDate = lead.meeting ?? Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        previewStage = p.previewStage
        template = p.template
        offer = p.offer
        deliverables = p.deliverables
        assetsAvailable = p.assetsAvailable
        assetsNeeded = p.assetsNeeded
        questions = p.questions
        repoURL = p.repoURL
        previewURL = p.previewURL
        notes = lead.notes
        notificationsOn = p.notificationsEnabled
    }

    private func isDirty(leadID: String) -> Bool {
        let p = workflow.profile(id: leadID)
        let stored = store.leads.first { $0.id == leadID }
        if p.nextAction != nextAction
            || p.template != template || p.offer != offer || p.deliverables != deliverables
            || p.assetsAvailable != assetsAvailable || p.assetsNeeded != assetsNeeded
            || p.questions != questions || p.repoURL != repoURL || p.previewURL != previewURL
            || p.previewStage != previewStage || p.operatingOverride != operatingOverride
            || p.verifiedWebsite != websiteValue || p.archived != archived
            || p.correctionNote != correctionNote.trimmingCharacters(in: .whitespacesAndNewlines)
            || notes != (stored?.notes ?? notes)
            || hasFollowUp != (stored?.followUp != nil)
            || hasMeeting != (stored?.meeting != nil)
        { return true }
        if hasFollowUp, stored?.followUp != followUpDate { return true }
        if hasMeeting, stored?.meeting != meetingDate { return true }
        return false
    }

    private func draftText(leadID: String) -> String {
        let stored = store.leads.first { $0.id == leadID }
        return """
        Unsaved MapLeads draft — \(stored?.title ?? leadID)
        Next action: \(nextAction)
        Operating correction: \(operatingOverride) — \(correctionNote)
        Verified website: \(verifiedWebsite)
        Archived: \(archived)
        Preview stage: \(previewStage)
        Template: \(template)
        Offer: \(offer)
        Deliverables: \(deliverables)
        Assets available: \(assetsAvailable)
        Assets needed: \(assetsNeeded)
        Questions: \(questions)
        Repo URL: \(repoURL)
        Preview URL: \(previewURL)
        Follow-up: \(hasFollowUp ? followUpDate.formatted() : "none")
        Meeting: \(hasMeeting ? meetingDate.formatted() : "none")
        Notes:
        \(notes)
        """
    }

    private func saveOutcome() {
        let lead = current
        let outcome = selectedOutcome
        let date: Date?
        switch outcome.dateKind {
        case .callback: date = callbackDate
        case .meeting: date = outcomeMeetingDate
        case nil: date = nil
        }
        if let failure = CallWorkflowActions.recordOutcome(
            outcome,
            note: callNote,
            date: date,
            lead: lead,
            workflow: workflow,
            store: store,
            onNotificationError: { reminderError = $0; reminderMessage = nil }
        ) {
            errorMessage = failure
            message = nil
            return
        }
        errorMessage = nil
        message = "Recorded “\(outcome.label)”."
        callNote = ""
        load(from: current)
    }

    private func saveNextStep() {
        var updated = current
        updated.followUp = hasFollowUp ? followUpDate : nil
        guard LeadSaver.save(updated, in: store) else {
            errorMessage = store.error ?? "The follow-up could not be saved."
            message = nil
            return
        }
        var p = savedProfile
        p.nextAction = nextAction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard workflow.saveProfile(p, id: current.id) else {
            errorMessage = workflow.error ?? "The next action could not be saved."
            message = nil
            return
        }
        errorMessage = nil
        message = "Next step saved."
        if p.notificationsEnabled { reconcileReminders() }
    }

    private func saveCorrections() {
        let note = correctionNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else {
            errorMessage = "A reason is required for a correction."
            message = nil
            return
        }
        let site = websiteValue
        if let site, !CallWorkflowActions.isValidHTTPURL(site) {
            errorMessage = "Verified website must be an http(s) URL."
            message = nil
            return
        }
        var p = savedProfile
        let changes = p.operatingOverride != operatingOverride || p.verifiedWebsite != site || p.archived != archived
        p.operatingOverride = operatingOverride
        p.verifiedWebsite = site
        p.archived = archived
        p.correctionNote = note
        if changes { p.correctedAt = Date() }
        guard workflow.saveProfile(p, id: current.id) else {
            errorMessage = workflow.error ?? "The correction could not be saved."
            message = nil
            return
        }
        errorMessage = nil
        message = "Corrections saved\(changes ? " · stamped \(p.correctedAt!.formatted(date: .abbreviated, time: .shortened))" : "")."
        if archived || ["Confirmed closed", "Wrong number", "Not a fit"].contains(operatingOverride) {
            LeadNotifications.cancel(leadID: current.id)
            reminderMessage = "Reminders cancelled (lead marked \(operatingOverride))."
            reminderError = nil
        } else if p.notificationsEnabled {
            reconcileReminders()
        }
    }

    private func saveHandoff() {
        var updated = current
        if hasMeeting {
            updated.meeting = meetingDate
            updated.stage = CallStageRules.advance(updated.stage, toAtLeast: "Meeting booked")
        } else {
            updated.meeting = nil
        }
        guard LeadSaver.save(updated, in: store) else {
            errorMessage = store.error ?? "The handoff could not be saved."
            message = nil
            return
        }
        var p = savedProfile
        p.template = template.trimmingCharacters(in: .whitespacesAndNewlines)
        p.offer = offer.trimmingCharacters(in: .whitespacesAndNewlines)
        p.deliverables = deliverables.trimmingCharacters(in: .whitespacesAndNewlines)
        p.assetsAvailable = assetsAvailable.trimmingCharacters(in: .whitespacesAndNewlines)
        p.assetsNeeded = assetsNeeded.trimmingCharacters(in: .whitespacesAndNewlines)
        p.questions = questions.trimmingCharacters(in: .whitespacesAndNewlines)
        p.repoURL = repoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        p.previewURL = previewURL.trimmingCharacters(in: .whitespacesAndNewlines)
        p.previewStage = previewStage
        guard workflow.saveProfile(p, id: current.id) else {
            errorMessage = workflow.error ?? "The prep fields could not be saved."
            message = nil
            return
        }
        errorMessage = nil
        message = "Handoff saved."
        if p.notificationsEnabled { reconcileReminders() }
    }

    private func saveNotes() {
        var updated = current
        updated.notes = notes
        guard LeadSaver.save(updated, in: store) else {
            errorMessage = store.error ?? "The notes could not be saved."
            message = nil
            return
        }
        errorMessage = nil
        message = "Notes saved."
    }

    private func setReminders(_ on: Bool) {
        if !on {
            var p = savedProfile
            p.notificationsEnabled = false
            guard workflow.saveProfile(p, id: current.id) else {
                errorMessage = workflow.error ?? "The opt-out could not be saved."
                message = nil
                notificationsOn = true
                return
            }
            LeadNotifications.cancel(leadID: current.id)
            notificationsOn = false
            reminderMessage = "Reminders cancelled."
            reminderError = nil
            return
        }
        let leadID = current.id
        Task { @MainActor in
            do {
                guard !isSuppressed else { notificationsOn = false; LeadNotifications.cancel(leadID: current.id); reminderError = "Suppressed contacts cannot receive reminders."; return }
                let granted = try await LeadNotifications.requestAuthorization()
                guard granted else {
                    notificationsOn = false
                    reminderError = "Notification permission was denied. Allow MapLeads in System Settings → Notifications, then turn this on again."
                    reminderMessage = nil
                    return
                }
                var p = workflow.profile(id: leadID)
                p.notificationsEnabled = true
                guard workflow.saveProfile(p, id: leadID) else {
                    notificationsOn = false
                    reminderError = workflow.error ?? "The opt-in could not be saved."
                    reminderMessage = nil
                    return
                }
                notificationsOn = true
                let scheduled = try await LeadNotifications.reconcile(lead: current, profile: p)
                reminderMessage = LeadNotifications.summary(scheduled)
                reminderError = nil
            } catch {
                notificationsOn = false
                reminderError = error.localizedDescription
                reminderMessage = nil
            }
        }
    }

    /// Re-syncs reminders after any panel change so pending requests always
    /// match the stored lead + profile.
    private func reconcileReminders() {
        if isSuppressed { LeadNotifications.cancel(leadID: current.id); reminderMessage = "Suppressed contact: reminders cancelled."; return }
        let snapshot = current
        let profile = savedProfile
        Task { @MainActor in
            do {
                let scheduled = try await LeadNotifications.reconcile(lead: snapshot, profile: profile)
                reminderMessage = LeadNotifications.summary(scheduled)
                reminderError = nil
            } catch {
                reminderError = "Reminders could not be updated: \(error.localizedDescription)"
                reminderMessage = nil
            }
        }
    }

    // MARK: Export

    private func exportBrief() {
        let text = BriefBuilder.export(lead: current, profile: savedProfile, history: history)
        saveText(text, name: "Brief-\(safeName(current.title)).txt", type: .plainText)
    }

    private func exportICS() {
        guard hasMeeting else { return }
        let text = ICS.meetingICS(lead: current, profile: savedProfile, date: meetingDate)
        saveText(text, name: "Meeting-\(safeName(current.title)).ics", type: UTType(filenameExtension: "ics") ?? .plainText)
    }

    private func saveText(_ text: String, name: String, type: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            message = "Saved \(url.lastPathComponent)."
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            message = nil
        }
    }

    private func safeName(_ raw: String) -> String {
        let cleaned = raw
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "lead" : cleaned
    }
}

// MARK: - Call queue

struct CallQueueView: View {
    let leads: [Lead]
    @ObservedObject var workflow: WorkflowStore
    @ObservedObject var store: LeadStore
    @ObservedObject var enrichment: EnrichmentStore
    @Environment(\.dismiss) private var dismiss

    /// Session order of lead ids captured when the queue opened. Saving or
    /// skipping removes the head — that removal *is* the auto-advance.
    @State private var queue: [String] = []
    @State private var started = false
    @State private var outcomeID = CallOutcomeCatalog.all[0].id
    @State private var callNote = ""
    @State private var eventDate = Date()
    @State private var message: String?
    @State private var errorMessage: String?

    private var selectedOutcome: CallOutcome { CallOutcomeCatalog.outcome(id: outcomeID) }

    /// The store's live copy of the current lead, never the stale snapshot.
    private var currentLead: Lead? {
        guard let id = queue.first else { return nil }
        return store.leads.first { $0.id == id } ?? leads.first { $0.id == id }
    }

    private var recentHistory: [ContactEvent] {
        guard let lead = currentLead else { return [] }
        return workflow.data.events
            .filter { $0.leadID == lead.id }
            .sorted { $0.date > $1.date }
            .prefix(3)
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Call queue").font(.title2.bold())
                    Text("\(queue.count) left · one business at a time · eligibility re-checked live before every call")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            if let lead = currentLead {
                callCard(lead)
            } else if started {
                ContentUnavailableView(
                    "Queue complete",
                    systemImage: "checkmark.seal",
                    description: Text("Every eligible business in this queue was handled. Skipped businesses were not recorded.")
                )
            } else {
                ContentUnavailableView(
                    "No callable businesses",
                    systemImage: "phone.badge.xmark",
                    description: Text("None of the selected leads are callable right now. Only live “Website opportunities” and “Existing-site opportunities” with an unsuppressed phone number enter the queue.")
                )
            }

            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.green)
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            guard !started else { return }
            started = true
            queue = leads.compactMap { snapshot in
                let live = store.leads.first { $0.id == snapshot.id } ?? snapshot
                return CallWorkflowActions.eligibilityReason(live, workflow: workflow, enrichment: enrichment) == nil ? live.id : nil
            }
        }
        .onChange(of: outcomeID) { _, newID in
            if CallOutcomeCatalog.outcome(id: newID).dateKind == .meeting {
                eventDate = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
            }
        }
    }

    @ViewBuilder
    private func callCard(_ lead: Lead) -> some View {
        let reason = CallWorkflowActions.eligibilityReason(lead, workflow: workflow, enrichment: enrichment)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(lead.title).font(.title3.bold()).textSelection(.enabled)
                Text(lead.categories.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                Text(lead.phone ?? "No phone").font(.title2.bold()).textSelection(.enabled)
                Text(lead.address ?? "Address unavailable").font(.callout).foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 60)) { context in Text(BusinessClock.text(lead, now: context.date)).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Text(workflow.category(lead, enrichment: enrichment)).font(.caption.bold())
                    Spacer()
                    if let url = mapsURL(lead) { Link("Open Maps listing", destination: url).font(.caption) }
                }
            }

            if let reason {
                Label("Not callable right now: \(reason) Save is blocked; remove it from the queue or fix the cause.", systemImage: "nosign")
                    .font(.callout).foregroundStyle(.orange)
                    .padding(8).background(.orange.opacity(0.08)).cornerRadius(6)
            }

            if !recentHistory.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Previous contact").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(recentHistory) { event in
                        Text("\(event.date.formatted(date: .abbreviated, time: .shortened)) — \(event.outcome)\(event.note.isEmpty ? "" : " · \(event.note)")")
                            .font(.caption).textSelection(.enabled)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Picker("Outcome", selection: $outcomeID) {
                    ForEach(CallOutcomeCatalog.all) { outcome in
                        Text(outcome.label).tag(outcome.id)
                    }
                }
                if let kind = selectedOutcome.dateKind {
                    DatePicker(
                        kind == .callback ? "Callback date & time (required)" : "Meeting date & time (required)",
                        selection: $eventDate
                    )
                }
                TextField("Call note (recorded in history)", text: $callNote, axis: .vertical)
                    .lineLimit(1...4)
                HStack {
                    Button("Save & next") { saveOutcome() }
                        .buttonStyle(.borderedProminent)
                        .disabled(reason != nil)
                    Button("Skip") { skip() }
                    Spacer()
                    Text("Skipping records nothing.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("Times use this Mac's timezone (\(TimeZone.current.identifier)); the listing's timezone is unknown.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.quaternary.opacity(0.3))
        .cornerRadius(10)
    }

    // MARK: Actions

    private func saveOutcome() {
        guard let lead = currentLead else { return }
        let outcome = selectedOutcome
        let date: Date? = outcome.dateKind == nil ? nil : eventDate
        if let failure = CallWorkflowActions.recordOutcome(
            outcome,
            note: callNote,
            date: date,
            lead: lead,
            workflow: workflow,
            store: store,
            onNotificationError: { errorMessage = $0; message = nil }
        ) {
            errorMessage = failure
            message = nil
            return
        }
        errorMessage = nil
        message = "Recorded “\(outcome.label)” for \(lead.title)."
        callNote = ""
        if !queue.isEmpty { queue.removeFirst() }
    }

    private func skip() {
        if !queue.isEmpty { queue.removeFirst() }
        message = "Skipped — nothing was recorded."
        errorMessage = nil
    }

    private func mapsURL(_ lead: Lead) -> URL? {
        guard let value = lead.mapsURL, let url = URL(string: value),
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}
