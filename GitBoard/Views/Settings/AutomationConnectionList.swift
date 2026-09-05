import AppKit
import SwiftUI

struct AutomationConnectionList: View {
    @Bindable var setup: AutomationSetupModel
    @State private var pendingDeletion: AutomationService.Automation?
    @State private var isShowingDeletionConfirmation = false

    var body: some View {
        ForEach(setup.automations) { automation in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(automation.accountLogin)
                            .font(.headline)
                        Text("Repositories: \(automation.repositoryCount) · Status mapping from Project #\(automation.mappingProjectNumber)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label(
                        statusTitle(for: automation),
                        systemImage: statusIcon(for: automation)
                    )
                    .foregroundStyle(statusColor(for: automation))
                }

                if let delivery = automation.lastDelivery {
                    Text(lastDeliveryText(delivery))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button(
                        automation.enabled ? "Pause" : "Resume",
                        systemImage: automation.enabled ? "pause" : "play",
                        action: { setEnabled(automation) }
                    )
                    .disabled(!automation.enabled && !canResume(automation))
                    Button(
                        "Reauthorize",
                        systemImage: "person.badge.key",
                        action: { reauthorize(automation) }
                    )
                    Spacer()
                    Button(
                        "Delete",
                        systemImage: "trash",
                        role: .destructive,
                        action: {
                            pendingDeletion = automation
                            isShowingDeletionConfirmation = true
                        }
                    )
                }
                .disabled(setup.busyAutomationIDs.contains(automation.id))
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
            Text("GitBoard will stop automation for all repositories available to the GitHub App and delete its stored service data.")
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
        case "ACTIVE": return automation.enabled ? "Healthy" : "Paused"
        case "CONTENT_VISIBILITY_UNVERIFIED": return automation.enabled
            ? "Awaiting first match"
            : "Paused"
        case "OAUTH_REAUTH_REQUIRED", "OAUTH_SCOPE_MISSING": return "Authorization required"
        default: return automation.enabled ? "Needs attention" : "Paused with error"
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
        return "Last delivery: \(delivery.state)\(error)\(date.map { " · \($0)" } ?? "")"
    }
}
