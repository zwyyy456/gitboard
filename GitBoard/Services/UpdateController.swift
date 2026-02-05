import Foundation
#if canImport(Sparkle)
import Sparkle

/// Controller for managing app updates via Sparkle framework
class UpdateController: ObservableObject {
    static let shared = UpdateController()

    private var updaterController: SPUStandardUpdaterController

    private init() {
        // Initialize Sparkle updater
        // startingUpdater: true means it will automatically check for updates on launch
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Check for updates manually (user-initiated via menu)
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    /// Access to the underlying SPUUpdater for settings
    var updater: SPUUpdater {
        updaterController.updater
    }

    /// Whether automatic update checks are enabled
    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    /// Last update check date
    var lastUpdateCheckDate: Date? {
        updater.lastUpdateCheckDate
    }

    /// Whether an update check can be performed right now
    var canCheckForUpdates: Bool {
        updater.canCheckForUpdates
    }
}
#endif
