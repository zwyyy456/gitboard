import Foundation

actor ProjectMonitor {
    private var task: Task<Void, Never>?

    func events(
        currentUserLogin: String,
        policy: MonitoringPolicy,
        readSnapshots: @escaping @Sendable () async throws -> [Project]?
    ) -> AsyncStream<ProjectMonitorEvent> {
        task?.cancel()

        let (stream, continuation) = AsyncStream<ProjectMonitorEvent>.makeStream()
        let producerTask = Task {
            var previousStates: [String: MonitoredItemState]?
            var pendingChanges: [ProjectChange] = []
            var lastFailure: String?

            while Task.isCancelled == false {
                do {
                    guard let snapshots = try await readSnapshots() else {
                        try await Task.sleep(for: policy.interval)
                        continue
                    }
                    try Task.checkCancellation()

                    let now = Date()
                    let currentStates = ProjectChangeDetector.states(
                        for: snapshots,
                        currentUserLogin: currentUserLogin,
                        now: now
                    )
                    if let previousStates {
                        let changes = ProjectChangeDetector.changes(
                            from: previousStates,
                            to: currentStates,
                            projects: snapshots
                        )
                        if policy.isQuiet(at: now) {
                            pendingChanges.append(contentsOf: changes)
                        } else {
                            if pendingChanges.isEmpty == false {
                                continuation.yield(.digest(pendingChanges))
                                pendingChanges.removeAll()
                            }
                            for change in changes {
                                continuation.yield(.change(change))
                            }
                        }
                    }
                    previousStates = currentStates
                    lastFailure = nil
                } catch is CancellationError {
                    break
                } catch GitHubError.rateLimited(let resetDescription) {
                    continuation.yield(.rateLimited(resetDescription))
                    break
                } catch {
                    let message = error.localizedDescription
                    if message != lastFailure {
                        continuation.yield(.failed(message))
                        lastFailure = message
                    }
                }

                do {
                    try await Task.sleep(for: policy.interval)
                } catch {
                    break
                }
            }
            continuation.finish()
        }

        task = producerTask
        continuation.onTermination = { _ in
            producerTask.cancel()
        }
        return stream
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
