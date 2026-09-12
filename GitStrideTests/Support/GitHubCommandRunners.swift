import Foundation
import Testing
@testable import GitStride

actor FixtureGitHubCommandRunner: GitHubCommandRunning {
    private var responses: [Data]
    private var calls: [[String]] = []
    private var inputs: [Data?] = []

    init(responses: [String]) {
        self.responses = responses.map { Data($0.utf8) }
    }

    func run(arguments: [String], standardInput: Data?) async throws -> GitHubCommandResult {
        calls.append(arguments)
        inputs.append(standardInput)
        guard responses.isEmpty == false else {
            throw FixtureError.missingResponse
        }
        return GitHubCommandResult(
            standardOutput: responses.removeFirst(),
            standardError: Data()
        )
    }

    func recordedInputs() -> [Data?] { inputs }

    func recordedArguments() -> [[String]] {
        calls
    }

    private enum FixtureError: Error {
        case missingResponse
    }
}

enum SuspendingRunnerStep: Sendable {
    case response(String)
    case suspended(String, String)
    case failure(GitHubCommandError)
    case cancelled
}

actor SuspendingGitHubCommandRunner: GitHubCommandRunning {
    private var steps: [SuspendingRunnerStep]
    private var callCount = 0
    private var calls: [[String]] = []
    private var inputs: [Data?] = []
    private var suspendedIDs: Set<String> = []
    private var resultWaiters: [String: CheckedContinuation<GitHubCommandResult, Never>] = [:]
    private var suspensionWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(steps: [SuspendingRunnerStep]) {
        self.steps = steps
    }

    func run(arguments: [String], standardInput: Data?) async throws -> GitHubCommandResult {
        guard steps.isEmpty == false else { throw RunnerError.missingResponse }
        callCount += 1
        calls.append(arguments)
        inputs.append(standardInput)

        switch steps.removeFirst() {
        case .failure(let error):
            throw error
        case .cancelled:
            throw CancellationError()
        case .response(let response):
            return result(response)
        case .suspended(let id, let response):
            suspendedIDs.insert(id)
            suspensionWaiters.removeValue(forKey: id)?.forEach { $0.resume() }
            return await withCheckedContinuation { continuation in
                resultWaiters[id] = continuation
                suspendedResponses[id] = response
            }
        }
    }

    func waitUntilSuspended(_ id: String) async {
        guard suspendedIDs.contains(id) == false else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters[id, default: []].append(continuation)
        }
    }

    func release(_ id: String) {
        guard let continuation = resultWaiters.removeValue(forKey: id),
              let response = suspendedResponses.removeValue(forKey: id) else { return }
        continuation.resume(returning: result(response))
    }

    func recordedArguments() -> [[String]] { calls }

    func recordedInputs() -> [Data?] { inputs }

    func recordedCallCount() -> Int {
        callCount
    }

    private var suspendedResponses: [String: String] = [:]

    private func result(_ response: String) -> GitHubCommandResult {
        GitHubCommandResult(standardOutput: Data(response.utf8), standardError: Data())
    }

    private enum RunnerError: Error {
        case missingResponse
    }
}
