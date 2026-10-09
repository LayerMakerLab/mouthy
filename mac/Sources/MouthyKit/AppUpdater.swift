import Combine
import Foundation
import MouthyCore

/// An app updater. The Mouthy app installs its Sparkle one (MouthyUpdates) before launch; MouthyKit and the
/// apps that embed it never link Sparkle, and with nothing installed nothing ever checks.
@MainActor public protocol AppUpdating: AnyObject {
    /// True: a daily background check, quiet download and install on quit. False: no checks at all.
    func setAutomaticChecks(_ enabled: Bool)
    /// Starts the updater once, after the app has launched.
    func start()
}

@MainActor public enum AppUpdater {
    /// Set by the Mouthy executable before `MouthyLauncher.main()`.
    public static var installed: (any AppUpdating)?
    private static var following: AnyCancellable?

    /// Checks run only while "Check for updates automatically" is on and Local Only Mode is off.
    public static func automaticChecks(_ preferences: Preferences) -> Bool {
        preferences.checkForUpdates && !preferences.localOnly
    }

    /// Applies the current settings, starts the updater, then follows every change that matters to it.
    static func follow<P: Publisher>(_ preferences: P, with updater: any AppUpdating) -> AnyCancellable where P.Output == Preferences, P.Failure == Never {
        var started = false
        return preferences.map(automaticChecks).removeDuplicates().sink { enabled in
            updater.setAutomaticChecks(enabled)
            if !started { started = true; updater.start() }
        }
    }

    /// Called just before the app runs: once launching has finished, the installed updater follows Settings.
    static func startAfterLaunch() {
        guard let updater = installed else { return }
        // Main-queue work runs only once NSApplication has finished launching and entered its run loop.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { following = follow(AppModel.shared.$preferences, with: updater) }
        }
    }
}
