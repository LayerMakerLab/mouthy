import Foundation
import MouthyKit
import Sparkle

/// Sparkle 2 for the Mouthy app. One static feed signed with Mouthy's EdDSA key (SUFeedURL, SUPublicEDKey and
/// SURequireSignedFeed in Info.plist), checked once a day in the background while automatic checks are on.
/// Updates download quietly and install when Mouthy quits. A feed that is missing, unreachable or invalid
/// ends the check silently: Sparkle's background checks show an error only after showing an update, and the
/// next try waits for the next daily check. Sparkle's system profile stays off.
@MainActor public final class SparkleUpdater: AppUpdating {
    let updater: SPUUpdater
    private let gate = Gate()
    /// Test hook: called when an update cycle ends, with its error.
    var cycleFinished: ((Error?) -> Void)? {
        get { gate.finished }
        set { gate.finished = newValue }
    }

    public convenience init() { self.init(hostBundle: .main, userDriver: nil) }

    init(hostBundle: Bundle, userDriver: (any SPUUserDriver)?) {
        updater = SPUUpdater(hostBundle: hostBundle, applicationBundle: hostBundle,
                             userDriver: userDriver ?? SPUStandardUserDriver(hostBundle: hostBundle, delegate: nil), delegate: gate)
        updater.sendsSystemProfile = false
    }

    public func setAutomaticChecks(_ enabled: Bool) {
        gate.allowed = enabled
        updater.automaticallyChecksForUpdates = enabled
        updater.automaticallyDownloadsUpdates = enabled
    }

    public func start() {
        // A misconfigured bundle (no key or feed) simply never checks.
        try? updater.start()
    }
}

/// Refuses every check while automatic checks are off, whatever starts it.
private final class Gate: NSObject, SPUUpdaterDelegate {
    var allowed = false
    var finished: ((Error?) -> Void)?

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard allowed else { throw NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue)) }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        finished?(error)
    }
}
