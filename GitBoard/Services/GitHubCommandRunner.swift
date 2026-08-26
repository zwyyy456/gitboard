@preconcurrency import Foundation

struct GitHubCommandResult: Sendable {
    let standardOutput: Data
    let standardError: Data
}

enum GitHubCommandError: Error, LocalizedError {
    case executableNotFound
    case launchFailed(String)
    case failed(status: Int32, message: String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "GitHub CLI (gh) was not found."
        case .launchFailed(let message):
            return "GitHub CLI could not be launched: \(message)"
        case .failed(_, let message):
            return message.isEmpty ? "GitHub CLI command failed." : message
        case .timedOut:
            return "GitHub CLI command timed out."
        }
    }
}

protocol GitHubCommandRunning: Sendable {
    func run(arguments: [String]) async throws -> GitHubCommandResult
}

actor ProcessGitHubCommandRunner: GitHubCommandRunning {
    private let timeout: Duration
    private var executableURL: URL?
    private var runningProcesses: [UUID: Process] = [:]

    init(timeout: Duration = .seconds(60)) {
        self.timeout = timeout
    }

    func run(arguments: [String]) async throws -> GitHubCommandResult {
        let executableURL = try locateExecutable()
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let processID = UUID()

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        runningProcesses[processID] = process

        let outputTask = Task.detached {
            outputPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let errorTask = Task.detached {
            errorPipe.fileHandleForReading.readDataToEndOfFile()
        }

        do {
            let status = try await withTaskCancellationHandler {
                try await waitForExit(process)
            } onCancel: {
                Task { await self.terminate(processID) }
            }

            runningProcesses[processID] = nil
            let output = await outputTask.value
            let error = await errorTask.value

            guard status == 0 else {
                throw GitHubCommandError.failed(
                    status: status,
                    message: Self.safeMessage(from: error)
                )
            }

            return GitHubCommandResult(
                standardOutput: output,
                standardError: error
            )
        } catch {
            terminate(processID)
            runningProcesses[processID] = nil
            _ = await outputTask.value
            _ = await errorTask.value

            if error is CancellationError {
                throw CancellationError()
            }
            throw error
        }
    }

    private func locateExecutable() throws -> URL {
        if let executableURL {
            return executableURL
        }

        let standardPaths = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh"
        ]
        let environmentPaths = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map { String($0) + "/gh" } ?? []

        guard let path = (standardPaths + environmentPaths).first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw GitHubCommandError.executableNotFound
        }

        let url = URL(fileURLWithPath: path)
        executableURL = url
        return url
    }

    private func waitForExit(_ process: Process) async throws -> Int32 {
        try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask {
                try await Self.launchAndWait(process)
            }
            group.addTask { [timeout] in
                try await Task.sleep(for: timeout)
                if process.isRunning {
                    process.terminate()
                }
                throw GitHubCommandError.timedOut
            }

            guard let status = try await group.next() else {
                throw GitHubCommandError.launchFailed("No process result was produced.")
            }
            group.cancelAll()
            return status
        }
    }

    private nonisolated static func launchAndWait(_ process: Process) async throws -> Int32 {
        try Task.checkCancellation()

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(
                    throwing: GitHubCommandError.launchFailed(error.localizedDescription)
                )
            }
        }
    }

    private func terminate(_ processID: UUID) {
        guard let process = runningProcesses[processID], process.isRunning else {
            return
        }
        process.terminate()
    }

    private nonisolated static func safeMessage(from data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(500))
    }
}
