import SwiftUI

struct HistoryView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if let decision = model.lastDecision {
                    Section("Latest result") {
                        ServerDecisionBanner(decision: decision)
                    }
                }

                if shouldShowEmptyState {
                    ContentUnavailableView("No events yet", systemImage: "tray")
                } else {
                    if showsLocalHistory, model.localEvents.isEmpty == false {
                        Section("Local history") {
                            ForEach(model.localEvents) { event in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(event.personDisplayName)
                                            .font(.headline)
                                        Spacer()
                                        Text(event.statusLabel)
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(event.reasonCode == "lan_backend_unavailable" ? .orange : (event.accepted ? .green : (event.stepUpRequired ? .orange : .red)))
                                    }
                                    Text("\(event.siteLabel) · \(event.syncStatus.label)")
                                        .foregroundStyle(.secondary)
                                    Text(event.createdAt.formatted())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(event.displayReason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(
                                        "Origin \(event.decisionOrigin.rawValue) · Match \(event.matchScore.formatted(.number.precision(.fractionLength(2)))) · Quality \(event.qualityScore.formatted(.number.precision(.fractionLength(2)))) · Liveness \(event.livenessScore.formatted(.number.precision(.fractionLength(2))))"
                                    )
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 6)
                            }
                        }
                    }

                    if model.recentEvents.isEmpty == false {
                        Section("Server history") {
                            ForEach(model.recentEvents) { event in
                                ServerEventCard(
                                    event: event,
                                    highlighted: model.highlightedServerEventID == event.id
                                )
                                .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                            }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Clear") {
                        if model.settings.backendMode == .lan {
                            Button("Clear classroom history", role: .destructive) {
                                Task { await model.clearDemoServerHistory() }
                            }
                        } else {
                            Button("Clear local history", role: .destructive) {
                                model.clearAllLocalHistory()
                            }
                            Button("Clear queue", role: .destructive) {
                                model.clearQueue()
                            }
                        }
                    }
                }
            }
            .refreshable {
                await model.refreshHistory()
            }
        }
    }

    private var showsLocalHistory: Bool {
        model.settings.backendMode != .lan
    }

    private var shouldShowEmptyState: Bool {
        let localIsEmpty = showsLocalHistory ? model.localEvents.isEmpty : true
        return model.lastDecision == nil && localIsEmpty && model.recentEvents.isEmpty
    }
}

struct ServerDecisionBanner: View {
    let decision: AttendanceDecisionPayload

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(decision.statusLabel)
                    .font(.headline)
                    .foregroundStyle(statusColor)
                Spacer()
                Text(decision.confidenceBand.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(statusColor.opacity(0.12), in: Capsule())
            }

            Text(decision.displayReason)
                .foregroundStyle(.primary)

            Text(
                "Origin \(decision.decisionOrigin.rawValue) · Match \(decision.matchScore.formatted(.number.precision(.fractionLength(2)))) · Quality \(decision.qualityScore.formatted(.number.precision(.fractionLength(2)))) · Liveness \(decision.livenessScore.formatted(.number.precision(.fractionLength(2))))"
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private var statusColor: Color {
        if decision.isTransportFailure { return .orange }
        if decision.accepted { return .green }
        if decision.stepUpRequired { return .orange }
        return .red
    }
}

private struct ServerEventCard: View {
    let event: AttendanceEventPayload
    let highlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.primaryPersonLabel)
                        .font(.headline)
                    Text(event.primarySiteLabel)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(event.statusLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(statusColor.opacity(0.12), in: Capsule())
            }

            Text(event.displayReason)
                .font(.subheadline)
                .foregroundStyle(.primary)

            Text(event.createdAt)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(
                "Matched \(event.matchedPersonLabel) · Origin \(event.decisionOrigin.rawValue) · Match \(event.matchScore.formatted(.number.precision(.fractionLength(2)))) · Quality \(event.qualityScore.formatted(.number.precision(.fractionLength(2)))) · Liveness \(event.livenessScore.formatted(.number.precision(.fractionLength(2))))"
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(highlighted ? statusColor.opacity(0.16) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(highlighted ? statusColor.opacity(0.5) : Color.clear, lineWidth: 1)
        )
    }

    private var statusColor: Color {
        if event.accepted { return .green }
        if event.stepUpRequired { return .orange }
        return .red
    }
}
