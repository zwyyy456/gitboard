@preconcurrency import Foundation

struct GitHubCommandResult: Sendable {
    let standardOutput: Data
    let standardError: Data
}

enum GitHubCommandError: Error, LocalizedError {
    case executableNotFound
    case launchFailed(String)
    case failed(status: Int32, message: String, standardOutput: Data)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "GitHub CLI (gh) was not found."
        case .launchFailed(let message):
            return "GitHub CLI could not be launched: \(message)"
        case .failed(_, let message, _):
            return message.isEmpty ? "GitHub CLI command failed." : message
        case .timedOut:
            return "GitHub CLI command timed out."
        }
    }
}

protocol GitHubCommandRunning: Sendable {
    func run(arguments: [String], standardInput: Data?) async throws -> GitHubCommandResult
}

actor ProcessGitHubCommandRunner: GitHubCommandRunning {
    private let timeout: Duration
    private var executableURL: URL?
    private var runningProcesses: [UUID: Process] = [:]

    init(timeout: Duration = .seconds(60), executableURL: URL? = nil) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    func run(arguments: [String], standardInput: Data?) async throws -> GitHubCommandResult {
        let executableURL = try locateExecutable()
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()
        let processID = UUID()

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe
        runningProcesses[processID] = process

        let outputTask = Task.detached {
            outputPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let errorTask = Task.detached {
            errorPipe.fileHandleForReading.readDataToEndOfFile()
        }

        do {
            let status = try await withTaskCancellationHandler {
                try await waitForExit(process, input: standardInput, inputPipe: inputPipe)
            } onCancel: {
                Task { await self.terminate(processID) }
            }

            runningProcesses[processID] = nil
            let output = await outputTask.value
            let error = await errorTask.value

            guard status == 0 else {
                throw GitHubCommandError.failed(
                    status: status,
                    message: Self.safeMessage(from: error),
                    standardOutput: output
                )
            }

            return GitHubCommandResult(
                standardOutput: output,
                standardError: error
            )
        } catch {
            terminate(processID)
            try? inputPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
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

    private func waitForExit(_ process: Process, input: Data?, inputPipe: Pipe) async throws -> Int32 {
        let (exits, continuation) = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = { process in
            continuation.yield(process.terminationStatus)
            continuation.finish()
        }
        defer {
            process.terminationHandler = nil
            continuation.finish()
        }
        try Task.checkCancellation()
        do {
            try process.run()
        } catch {
            throw GitHubCommandError.launchFailed(error.localizedDescription)
        }

        return try await withThrowingTaskGroup(of: Int32?.self) { group in
            group.addTask {
                for await status in exits { return status }
                throw CancellationError()
            }
            group.addTask { [timeout] in
                try await Task.sleep(for: timeout)
                if process.isRunning { process.terminate() }
                throw GitHubCommandError.timedOut
            }
            group.addTask {
                defer { try? inputPipe.fileHandleForWriting.close() }
                if let input {
                    do {
                        try inputPipe.fileHandleForWriting.write(contentsOf: input)
                    } catch {
                        if process.isRunning { process.terminate() }
                        throw GitHubCommandError.launchFailed("Could not write the request to GitHub CLI.")
                    }
                }
                return nil
            }
            defer { group.cancelAll() }
            while let result = try await group.next() {
                if let status = result { return status }
            }
            throw CancellationError()
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
