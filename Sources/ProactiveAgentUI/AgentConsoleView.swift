#if canImport(SwiftUI)
import ProactiveAgent
import SwiftUI

/// A console for the proactive agent: deliver signals, step the loop, answer consent and
/// approval prompts, inject faults, and inspect exactly what left the device.
public struct AgentConsoleView: View {
    @ObservedObject private var model: AgentConsoleModel

    public init(model: AgentConsoleModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            List {
                if let error = model.setupError {
                    Section { Text(error).foregroundStyle(.red) }
                }
                ControlsSection(model: model)
                WaitingSection(model: model)
                EventLogSection(events: model.live)
                EgressSection(tickets: model.status?.recentEgress ?? [], issued: model.status?.metrics.ticketsIssued ?? 0)
                MetricsSection(status: model.status, executed: model.status?.metrics.executed ?? 0)
                TimelineSection(entries: model.timeline)
            }
            .navigationTitle("Proactive Agent")
        }
    }
}

struct ControlsSection: View {
    @ObservedObject var model: AgentConsoleModel

    var body: some View {
        Section {
            HStack {
                ActionButton(title: "Deliver", systemImage: "tray.and.arrow.down") { await model.deliverSignals() }
                ActionButton(title: "Step", systemImage: "forward.frame") { await model.step() }
                ActionButton(title: "Run", systemImage: "play.fill") { await model.runUntilIdle() }
            }
            HStack {
                ActionButton(title: "+5 min", systemImage: "clock.arrow.circlepath") { await model.advance(minutes: 5) }
                Button(role: .destructive) { model.reset() } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
            }
            Toggle("Low Power Mode", isOn: $model.lowPowerMode)
            Toggle("Offline", isOn: $model.offline)
            Toggle("Classifier bug (scanner must catch it)", isOn: $model.classifierBug)
            Toggle("Injected planner (proposes off-module tool)", isOn: $model.rogueRequests)
        } header: {
            Text("Controls · t = \(Saturating.int(model.now))s")
        } footer: {
            Text("\(model.signals.count) signals in this scenario, including one redelivered duplicate.")
        }
    }
}

struct ActionButton: View {
    let title: String
    let systemImage: String
    let action: @MainActor () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.borderedProminent)
    }
}

struct WaitingSection: View {
    @ObservedObject var model: AgentConsoleModel

    var body: some View {
        let approvals = model.status?.approvals ?? []
        let consent = (model.status?.awaitingConsent ?? [:]).sorted { $0.key < $1.key }
        Section("Waiting on you") {
            if approvals.isEmpty && consent.isEmpty {
                Text("Nothing needs you right now.").foregroundStyle(.secondary)
            }
            ForEach(consent, id: \.key) { item in
                ConsentRow(seq: item.key, categories: item.value) { await model.allow(item.value) }
            }
            ForEach(approvals) { request in
                ApprovalRow(request: request,
                            approve: { await model.approve(request) },
                            reject: { await model.reject(request) })
            }
        }
    }
}

struct ConsentRow: View {
    let seq: UInt64
    let categories: Set<DataCategory>
    let allow: @MainActor () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("#\(seq) wants to share \(categories.map(\.rawValue).sorted().joined(separator: ", "))")
                .font(.subheadline.weight(.semibold))
            Text("Consent applies to this category and destination, and expires in 24 hours.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Allow") { Task { await allow() } }
                .buttonStyle(.borderedProminent)
        }
    }
}

struct ApprovalRow: View {
    let request: ApprovalRequest
    let approve: @MainActor () async -> Void
    let reject: @MainActor () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(request.action.summary).font(.subheadline.weight(.semibold))
            // The arguments are what will actually run; the summary is planner-written text.
            ForEach(request.action.disclosure, id: \.self) { line in
                Text(line).font(.caption.monospaced())
            }
            Text("\(request.action.tool) · digest \(request.digest.description)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            HStack {
                Button("Approve") { Task { await approve() } }
                    .buttonStyle(.borderedProminent)
                Button("Reject", role: .destructive) { Task { await reject() } }
                    .buttonStyle(.bordered)
            }
        }
    }
}

struct EventLogSection: View {
    let events: [LoggedEvent]

    var body: some View {
        Section("Durable event log") {
            if events.isEmpty {
                Text("Empty. Tap Deliver to feed the scenario's signals.").foregroundStyle(.secondary)
            }
            ForEach(events) { event in
                HStack {
                    Text("#\(event.seq)").font(.caption.monospaced())
                    VStack(alignment: .leading) {
                        Text(event.signal.title).lineLimit(1)
                        Text("\(event.signal.source.rawValue) · attempts \(event.attempts)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(event.state.rawValue)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }
        }
    }
}

struct EgressSection: View {
    let tickets: [EgressTicket]
    let issued: Int

    /// Stable ids: the n-th ticket ever issued keeps id n even as older ones fall off the list.
    private var numbered: [(id: Int, ticket: EgressTicket)] {
        let base = Swift.max(0, Saturating.subtract(issued, tickets.count))
        let items: [(id: Int, ticket: EgressTicket)] = tickets.enumerated().map { (id: Saturating.add(base, $0.offset), ticket: $0.element) }
        return Array(items.reversed())
    }

    var body: some View {
        Section("What actually left the device") {
            if tickets.isEmpty {
                Text("No egress yet.").foregroundStyle(.secondary)
            }
            ForEach(numbered, id: \.id) { item in
                let ticket = item.ticket
                VStack(alignment: .leading, spacing: 4) {
                    Text("→ \(ticket.destination) · \(ticket.byteCount) bytes")
                        .font(.caption.weight(.semibold))
                    ForEach(Array(ticket.fields.enumerated()), id: \.offset) { _, field in
                        Text("\(field.key): \(field.value)")
                            .font(.caption.monospaced())
                            .foregroundStyle(field.redacted ? Color.orange : Color.primary)
                    }
                }
            }
        }
    }
}

struct MetricsSection: View {
    let status: AgentStatus?
    let executed: Int

    var body: some View {
        Section("Budgets & metrics") {
            if let status {
                MetricRow(label: "Actions executed", value: "\(executed)")
                MetricRow(label: "Tickets issued", value: "\(status.metrics.ticketsIssued)")
                MetricRow(label: "Leaks blocked by scanner", value: "\(status.metrics.leaksBlocked)")
                MetricRow(label: "Tool tokens disclosed / eager",
                          value: "\(status.metrics.disclosedSchemaTokens) / \(status.metrics.eagerSchemaTokens)")
                MetricRow(label: "Cloud budget left", value: "\(status.cloudBudgetRemaining)")
                MetricRow(label: "Triage budget left", value: "\(status.triageBudgetRemaining)")
            } else {
                Text("No activity yet.").foregroundStyle(.secondary)
            }
        }
    }
}

struct MetricRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

struct TimelineSection: View {
    let entries: [TimelineEntry]

    var body: some View {
        Section("Timeline (newest first)") {
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.description.headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Self.color(for: entry.description.tone))
                    Text(entry.description.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    static func color(for tone: OutcomeTone) -> Color {
        switch tone {
        case .done: return .green
        case .waiting: return .blue
        case .guarded: return .orange
        case .deferred: return .purple
        case .failed: return .red
        case .neutral: return .primary
        }
    }
}
#endif
