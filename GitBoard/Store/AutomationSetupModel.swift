import Foundation
import Observation

@MainActor
@Observable
final class AutomationSetupModel {
    enum Phase: Equatable {
        case unavailable
        case disconnected
        case loadingConnection
        case connectionLoadFailed
        case starting
        case waitingForBrowser
        case loadingConfiguration
        case configuring
        case saving
        case connectionStorageFailed
        case connected
    }

    private enum SetupIntent {
        case initial
        case add
        case reauthorize
    }

    private(set) var phase: Phase
    private(set) var errorMessage: String?
    private(set) var setupSessionID: String?
    private(set) var repositories: [AutomationService.Repository] = []
    private(set) var projects: [AutomationService.Project] = []
    private(set) var statusFields: [AutomationService.StatusField] = []
    private(set) var automations: [AutomationService.Automation] = []
    private(set) var busyAutomationIDs: Set<String> = []

    var selectedRepositoryID: Int64?
    var selectedProjectID: String?
    var selectedStatusFieldID: String?
    var inProgressOptionID: String?
    var inReviewOptionID: String?
    var doneOptionID: String?

    private let service: AutomationService?
    private let tokenStore: any ManagementTokenStoring
    private let makeManagementToken: () throws -> String
    private var setupToken: String?
    private var authorizationURL: URL?
    private var loadingProjectID: String?
    private var loadedProjectID: String?
    private var pendingManagementToken: String?
    private var setupIntent: SetupIntent?

    init(
        service: AutomationService? = AutomationService.configured(),
        tokenStore: any ManagementTokenStoring = ManagementTokenStore(),
        makeManagementToken: @escaping () throws -> String = ManagementTokenStore.makeToken
    ) {
        self.service = service
        self.tokenStore = tokenStore
        self.makeManagementToken = makeManagementToken
        guard service != nil else {
            phase = .unavailable
            return
        }
        do {
            phase = try tokenStore.load() == nil ? .disconnected : .loadingConnection
        } catch {
            phase = .connectionLoadFailed
            errorMessage = "GitBoard could not access the saved automation connection in Keychain."
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
        setupIntent = .initial
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

    func startAddSetup() async -> URL? {
        guard let service else { return nil }
        phase = .starting
        setupIntent = .add
        errorMessage = nil
        do {
            let managementToken = try requireManagementToken()
            let session = try await service.createSetupSession(
                managementToken: managementToken
            )
            setupSessionID = session.id
            setupToken = session.setupToken
            authorizationURL = session.authorizationURL
            phase = .waitingForBrowser
            return session.authorizationURL
        } catch is CancellationError {
            phase = .connected
            return nil
        } catch {
            phase = .connected
            handleManagementFailure(error)
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
                case "COMPLETE" where setupIntent == .reauthorize:
                    clearSetupSession()
                    errorMessage = nil
                    phase = .connected
                    await loadAutomations()
                    return
                case "COMPLETE":
                    return
                default:
                    throw AutomationServiceError.invalidResponse
                }
                try await Task.sleep(for: .seconds(2))
            }
        } catch is CancellationError {
            return
        } catch {
            fail(error, fallback: setupIntent == .initial ? .disconnected : .connected)
        }
    }

    func browserURL() -> URL? {
        authorizationURL
    }

    func loadConnection() async {
        guard phase == .loadingConnection || phase == .connectionLoadFailed,
              let service else {
            return
        }
        phase = .loadingConnection
        errorMessage = nil
        do {
            let managementToken = try requireManagementToken()
            automations = try await service.automations(managementToken: managementToken)
            phase = .connected
        } catch is CancellationError {
            return
        } catch {
            if isManagementAuthFailure(error) {
                handleManagementFailure(error)
            } else {
                phase = .connectionLoadFailed
                errorMessage = message(for: error)
            }
        }
    }

    func loadAutomations() async {
        guard phase == .connected, let service else {
            return
        }
        do {
            let managementToken = try requireManagementToken()
            automations = try await service.automations(managementToken: managementToken)
        } catch is CancellationError {
            return
        } catch {
            handleManagementFailure(error)
        }
    }

    func setAutomationEnabled(id: String, enabled: Bool) async {
        guard let service else { return }
        busyAutomationIDs.insert(id)
        errorMessage = nil
        defer { busyAutomationIDs.remove(id) }
        do {
            let managementToken = try requireManagementToken()
            let updated = try await service.setAutomation(
                id: id,
                enabled: enabled,
                managementToken: managementToken
            )
            if let index = automations.firstIndex(where: { $0.id == id }) {
                automations[index] = updated
            }
        } catch is CancellationError {
            return
        } catch {
            handleManagementFailure(error)
        }
    }

    func deleteAutomation(id: String) async {
        guard let service else { return }
        busyAutomationIDs.insert(id)
        errorMessage = nil
        defer { busyAutomationIDs.remove(id) }
        do {
            let managementToken = try requireManagementToken()
            try await service.deleteAutomation(id: id, managementToken: managementToken)
            automations.removeAll { $0.id == id }
            if automations.isEmpty {
                try tokenStore.delete()
                phase = .disconnected
            }
        } catch is CancellationError {
            return
        } catch {
            handleManagementFailure(error)
        }
    }

    func reauthorizeAutomation(id: String) async -> URL? {
        guard let service else { return nil }
        phase = .starting
        errorMessage = nil
        do {
            let managementToken = try requireManagementToken()
            let session = try await service.beginReauthorization(
                id: id,
                managementToken: managementToken
            )
            setupSessionID = session.id
            setupToken = session.setupToken
            authorizationURL = session.authorizationURL
            setupIntent = .reauthorize
            phase = .waitingForBrowser
            return session.authorizationURL
        } catch is CancellationError {
            phase = .connected
            return nil
        } catch {
            phase = .connected
            handleManagementFailure(error)
            return nil
        }
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
            let selection = AutomationService.SetupSelection(
                sourceRepositoryID: repositoryID,
                projectNodeID: project.nodeID,
                projectNumber: project.number,
                statusFieldNodeID: statusFieldID,
                inProgressOptionID: inProgressOptionID,
                inReviewOptionID: inReviewOptionID,
                doneOptionID: doneOptionID
            )
            let managementToken: String?
            switch setupIntent {
            case .initial:
                let token = try pendingManagementToken ?? makeManagementToken()
                pendingManagementToken = token
                try tokenStore.save(token)
                managementToken = token
            case .add:
                managementToken = nil
            case .reauthorize, nil:
                return
            }
            _ = try await service.completeSetup(
                id: sessionID,
                setupToken: setupToken,
                selection: selection,
                managementToken: managementToken
            )
            pendingManagementToken = nil
            clearSetupSession()
            phase = .connected
            await loadAutomations()
        } catch is CancellationError {
            phase = .configuring
        } catch is ManagementTokenStoreError {
            phase = .connectionStorageFailed
            errorMessage = "GitBoard could not save the connection in Keychain."
        } catch {
            fail(error, fallback: .configuring)
        }
    }

    func retryTokenStorage() async {
        guard pendingManagementToken != nil else { return }
        await completeSetup()
    }

    func cancelSetup() async {
        let intent = setupIntent
        let shouldReconcile = intent == .initial && pendingManagementToken != nil
        pendingManagementToken = nil
        clearSetupSession()
        errorMessage = nil
        if shouldReconcile {
            phase = .loadingConnection
            await loadConnection()
        } else {
            phase = intent == .initial ? .disconnected : .connected
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
        setupIntent = nil
        selectedRepositoryID = nil
        selectedProjectID = nil
        selectedStatusFieldID = nil
        clearStatusMapping()
    }

    private func fail(_ error: Error, fallback: Phase = .disconnected) {
        phase = fallback
        errorMessage = message(for: error)
    }

    private func handleManagementFailure(_ error: Error) {
        if isManagementAuthFailure(error) {
            try? tokenStore.delete()
            automations = []
            phase = .disconnected
            errorMessage = "The saved automation connection is no longer valid. Connect again."
            return
        }
        errorMessage = message(for: error)
    }

    private func isManagementAuthFailure(_ error: Error) -> Bool {
        guard let serviceError = error as? AutomationServiceError,
              case .server("MANAGEMENT_AUTH_REQUIRED") = serviceError else {
            return false
        }
        return true
    }

    private func requireManagementToken() throws -> String {
        guard let token = try tokenStore.load() else {
            throw AutomationServiceError.server("MANAGEMENT_AUTH_REQUIRED")
        }
        return token
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
        case "AUTOMATION_NOT_READY":
            return "Resolve the connection error before resuming this automation."
        case "OAUTH_ACCOUNT_MISMATCH":
            return "Authorize the same personal GitHub account used by this automation."
        case "PROJECT_API_INCOMPATIBLE", "INVALID_OAUTH_RESPONSE":
            return "GitHub returned data that this version of GitBoard cannot use."
        default:
            return "Automation setup failed (\(code))."
        }
    }
}
