import Foundation
import Observation

@MainActor
@Observable
final class AutomationSetupModel {
    enum Phase: Equatable {
        case unavailable
        case disconnected
        case starting
        case waitingForBrowser
        case loadingConfiguration
        case configuring
        case saving
        case connectionStorageFailed
        case connected
    }

    private(set) var phase: Phase
    private(set) var errorMessage: String?
    private(set) var setupSessionID: String?
    private(set) var repositories: [AutomationService.Repository] = []
    private(set) var projects: [AutomationService.Project] = []
    private(set) var statusFields: [AutomationService.StatusField] = []

    var selectedRepositoryID: Int64?
    var selectedProjectID: String?
    var selectedStatusFieldID: String?
    var inProgressOptionID: String?
    var inReviewOptionID: String?
    var doneOptionID: String?

    private let service: AutomationService?
    private let tokenStore: ManagementTokenStore
    private var setupToken: String?
    private var authorizationURL: URL?
    private var loadingProjectID: String?
    private var loadedProjectID: String?
    private var pendingManagementToken: String?

    init(
        service: AutomationService? = AutomationService.configured(),
        tokenStore: ManagementTokenStore = ManagementTokenStore()
    ) {
        self.service = service
        self.tokenStore = tokenStore
        if (try? tokenStore.load()) != nil {
            phase = .connected
        } else {
            phase = service == nil ? .unavailable : .disconnected
        }
    }

    var selectedStatusOptions: [AutomationService.StatusOption] {
        statusFields.first { $0.id == selectedStatusFieldID }?.options ?? []
    }

    var canComplete: Bool {
        phase == .configuring
            && selectedRepositoryID != nil
            && selectedProjectID != nil
            && selectedStatusFieldID != nil
            && inProgressOptionID != nil
            && inReviewOptionID != nil
            && doneOptionID != nil
    }

    func startSetup() async -> URL? {
        guard let service else {
            phase = .unavailable
            return nil
        }
        phase = .starting
        errorMessage = nil
        do {
            let session = try await service.createSetupSession()
            setupSessionID = session.id
            setupToken = session.setupToken
            authorizationURL = session.authorizationURL
            phase = .waitingForBrowser
            return session.authorizationURL
        } catch is CancellationError {
            phase = .disconnected
            return nil
        } catch {
            fail(error)
            return nil
        }
    }

    func observeSetup() async {
        guard let service,
              let sessionID = setupSessionID,
              let setupToken else {
            return
        }
        do {
            while self.setupSessionID == sessionID {
                let status = try await service.sessionStatus(
                    id: sessionID,
                    setupToken: setupToken
                )
                switch status.state {
                case "OAUTH_PENDING", "INSTALLATION_PENDING":
                    phase = .waitingForBrowser
                case "CONFIGURATION_PENDING":
                    try await loadConfiguration(
                        service: service,
                        sessionID: sessionID,
                        setupToken: setupToken
                    )
                    return
                case "COMPLETE", "EXCHANGED":
                    throw AutomationServiceError.server("SETUP_STATE_CHANGED")
                default:
                    throw AutomationServiceError.invalidResponse
                }
                try await Task.sleep(for: .seconds(2))
            }
        } catch is CancellationError {
            return
        } catch {
            fail(error)
        }
    }

    func browserURL() -> URL? {
        authorizationURL
    }

    func selectProject(_ projectID: String?) async {
        if let projectID,
           projectID == loadingProjectID || projectID == loadedProjectID {
            return
        }
        selectedProjectID = projectID
        loadingProjectID = projectID
        loadedProjectID = nil
        selectedStatusFieldID = nil
        statusFields = []
        clearStatusMapping()
        guard let service,
              let project = projects.first(where: { $0.id == projectID }),
              let sessionID = setupSessionID,
              let setupToken else {
            return
        }
        errorMessage = nil
        do {
            let fields = try await service.statusFields(
                id: sessionID,
                setupToken: setupToken,
                project: project
            )
            guard selectedProjectID == projectID else { return }
            statusFields = fields
            selectedStatusFieldID = fields.first?.id
            loadedProjectID = projectID
            loadingProjectID = nil
        } catch is CancellationError {
            if loadingProjectID == projectID { loadingProjectID = nil }
            return
        } catch {
            guard selectedProjectID == projectID else { return }
            loadingProjectID = nil
            fail(error, fallback: .configuring)
        }
    }

    func selectStatusField(_ fieldID: String?) {
        selectedStatusFieldID = fieldID
        clearStatusMapping()
    }

    func completeSetup() async {
        guard let service,
              let sessionID = setupSessionID,
              let setupToken,
              let repositoryID = selectedRepositoryID,
              let project = projects.first(where: { $0.id == selectedProjectID }),
              let statusFieldID = selectedStatusFieldID,
              let inProgressOptionID,
              let inReviewOptionID,
              let doneOptionID else {
            return
        }
        phase = .saving
        errorMessage = nil
        do {
            let completionCode = try await service.completeSetup(
                id: sessionID,
                setupToken: setupToken,
                selection: AutomationService.SetupSelection(
                    sourceRepositoryID: repositoryID,
                    projectNodeID: project.nodeID,
                    projectNumber: project.number,
                    statusFieldNodeID: statusFieldID,
                    inProgressOptionID: inProgressOptionID,
                    inReviewOptionID: inReviewOptionID,
                    doneOptionID: doneOptionID
                )
            )
            let managementToken = try await service.exchangeManagementToken(
                sessionID: sessionID,
                completionCode: completionCode
            )
            pendingManagementToken = managementToken
            try tokenStore.save(managementToken)
            pendingManagementToken = nil
            clearSetupSession()
            phase = .connected
        } catch is CancellationError {
            phase = .configuring
        } catch is ManagementTokenStoreError {
            phase = .connectionStorageFailed
            errorMessage = "GitBoard could not save the connection in Keychain."
        } catch {
            fail(error, fallback: .configuring)
        }
    }

    func retryTokenStorage() {
        guard let pendingManagementToken else { return }
        do {
            try tokenStore.save(pendingManagementToken)
            self.pendingManagementToken = nil
            clearSetupSession()
            errorMessage = nil
            phase = .connected
        } catch {
            errorMessage = "GitBoard could not save the connection in Keychain."
        }
    }

    private func loadConfiguration(
        service: AutomationService,
        sessionID: String,
        setupToken: String
    ) async throws {
        phase = .loadingConfiguration
        let options = try await service.setupOptions(id: sessionID, setupToken: setupToken)
        repositories = options.repositories
        projects = options.projects
        selectedRepositoryID = repositories.first?.id
        phase = .configuring
        await selectProject(projects.first?.id)
    }

    private func clearStatusMapping() {
        inProgressOptionID = nil
        inReviewOptionID = nil
        doneOptionID = nil
    }

    private func clearSetupSession() {
        setupSessionID = nil
        setupToken = nil
        authorizationURL = nil
        repositories = []
        projects = []
        statusFields = []
        loadingProjectID = nil
        loadedProjectID = nil
        selectedRepositoryID = nil
        selectedProjectID = nil
        selectedStatusFieldID = nil
        clearStatusMapping()
    }

    private func fail(_ error: Error, fallback: Phase = .disconnected) {
        phase = fallback
        errorMessage = message(for: error)
    }

    private func message(for error: Error) -> String {
        guard let serviceError = error as? AutomationServiceError,
              case .server(let code) = serviceError else {
            return error.localizedDescription
        }
        switch code {
        case "SETUP_EXPIRED":
            return "This setup session expired. Start again to continue."
        case "OAUTH_SCOPE_MISSING":
            return "GitHub did not grant access to Projects. Authorize GitBoard again."
        case "INSTALLATION_ACCOUNT_MISMATCH":
            return "Install the GitBoard app on the same personal account you authorized."
        case "PROJECT_WRITE_FORBIDDEN":
            return "Your GitHub account cannot update the selected Project."
        case "SOURCE_REPOSITORY_ALREADY_CONFIGURED":
            return "That repository already has an automation."
        case "PROJECT_API_INCOMPATIBLE", "INVALID_OAUTH_RESPONSE":
            return "GitHub returned data that this version of GitBoard cannot use."
        default:
            return "Automation setup failed (\(code))."
        }
    }
}
