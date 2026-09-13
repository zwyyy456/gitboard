import AppKit
import SwiftUI

struct AutomationConnectionList: View {
    @Bindable var setup: AutomationSetupModel
    @State private var pendingDeletion: AutomationService.Automation?
    @State private var isShowingDeletionConfirmation = false

    var body: some View {
        ForEach(setup.automations) { automation in
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(automation.accountLogin)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(
                        automation.enabled ? String(localized: "Pause") : String(localized: "Resume"),
                        action: { setEnabled(automation) }
                    )
                    .disabled(!automation.enabled && !canResume(automation))
                    Button("Reauthorize…", action: { reauthorize(automation) })
                    Button("Delete…", role: .destructive) {
                        pendingDeletion = automation
                        isShowingDeletionConfirmation = true
                    }
                }
                .disabled(setup.busyAutomationIDs.contains(automation.id))

                Label(
                    statusTitle(for: automation),
                    systemImage: statusIcon(for: automation)
                )
                .foregroundStyle(statusColor(for: automation))
                .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 4) {
                    LabeledContent("Repositories", value: "\(automation.repositoryCount)")
                    LabeledContent("Status template", value: String(localized: "Project #\(automation.mappingProjectNumber)"))
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                if let delivery = automation.lastDelivery {
                    Text(lastDeliveryText(delivery))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
        .confirmationDialog(
            "Delete account automation?",
            isPresented: $isShowingDeletionConfirmation,
            presenting: pendingDeletion
        ) { automation in
            Button("Delete Account Automation", role: .destructive) {
                Task { await setup.deleteAutomation(id: automation.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { automation in
            Text("GitStride will stop automation for all repositories available to the GitHub App and delete its stored service data.")
        }
    }

    private func setEnabled(_ automation: AutomationService.Automation) {
        Task {
            await setup.setAutomationEnabled(id: automation.id, enabled: !automation.enabled)
        }
    }

    private func reauthorize(_ automation: AutomationService.Automation) {
        Task {
            if let url = await setup.reauthorizeAutomation(id: automation.id) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func statusTitle(for automation: AutomationService.Automation) -> String {
        switch automation.healthState {
        case "ACTIVE": return automation.enabled ? String(localized: "Healthy") : String(localized: "Paused")
        case "CONTENT_VISIBILITY_UNVERIFIED": return automation.enabled
            ? String(localized: "Awaiting first match")
            : String(localized: "Paused")
        case "OAUTH_REAUTH_REQUIRED", "OAUTH_SCOPE_MISSING": return String(localized: "Authorization required")
        default: return automation.enabled ? String(localized: "Needs attention") : String(localized: "Paused with error")
        }
    }

    private func statusIcon(for automation: AutomationService.Automation) -> String {
        switch automation.healthState {
        case "ACTIVE": return automation.enabled ? "checkmark.circle.fill" : "pause.circle"
        case "CONTENT_VISIBILITY_UNVERIFIED": return automation.enabled
            ? "questionmark.circle"
            : "pause.circle"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(for automation: AutomationService.Automation) -> Color {
        switch automation.healthState {
        case "ACTIVE": return automation.enabled ? .green : .secondary
        case "CONTENT_VISIBILITY_UNVERIFIED": return .secondary
        default: return .orange
        }
    }

    private func canResume(_ automation: AutomationService.Automation) -> Bool {
        automation.healthState == "ACTIVE"
            || automation.healthState == "CONTENT_VISIBILITY_UNVERIFIED"
    }

    private func lastDeliveryText(_ delivery: AutomationService.DeliveryStatus) -> String {
        let date = delivery.receivedAt?.formatted(date: .abbreviated, time: .shortened)
        let error = delivery.errorCode.map { " · \($0)" } ?? ""
        let state: String = switch delivery.state {
        case "RECEIVED": String(localized: "Received")
        case "QUEUED": String(localized: "Queued")
        case "PROCESSING": String(localized: "Processing")
        case "RETRYING": String(localized: "Retrying")
        case "COMPLETED": String(localized: "Completed")
        case "FAILED": String(localized: "Failed")
        case "IGNORED": String(localized: "Ignored")
        default: delivery.state
        }
        return String(localized: "Last delivery: \(state)\(error)\(date.map { " · \($0)" } ?? "")")
    }
}
