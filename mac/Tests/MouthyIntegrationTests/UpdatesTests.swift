import Combine
import Foundation
import Network
import Sparkle
import Testing
@testable import MouthyCore
@testable import MouthyKit
@testable import MouthyUpdates

// Automatic updates: Sparkle 2 behind MouthyKit's AppUpdater hook. Nothing here touches the network beyond
// 127.0.0.1, and nothing shows UI: Sparkle runs against a throwaway host bundle and a user driver spy.

private let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Test func infoPlistDeclaresTheSignedDailyFeed() throws {
    let data = try Data(contentsOf: sourceRoot.appendingPathComponent("Resources/Info.plist"))
    let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    #expect(plist["SUFeedURL"] as? String == "https://mouthy.dev/updates/appcast.xml")
    let key = try #require(plist["SUPublicEDKey"] as? String)
    #expect(Data(base64Encoded: key)?.count == 32)
    #expect(plist["SUEnableAutomaticChecks"] as? Bool == true)
    #expect(plist["SUScheduledCheckInterval"] as? Int == 86_400)
    // A signed feed, and archives verified before they are unpacked (Sparkle requires both together).
    #expect(plist["SURequireSignedFeed"] as? Bool == true)
    #expect(plist["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
    // Sparkle's anonymous system profile stays off: the request carries no macOS version or hardware facts.
    #expect(plist["SUEnableSystemProfiling"] == nil || plist["SUEnableSystemProfiling"] as? Bool == false)
}

@MainActor @Test func updateCheckPreferenceDefaultsOnAndPersistsOff() throws {
    #expect(Preferences().checkForUpdates)
    // Settings saved before this preference existed decode as on.
    let old = try JSONDecoder().decode(Preferences.self, from: Data(#"{"localOnly":false,"playSounds":true,"keepHistory":false}"#.utf8))
    #expect(old.checkForUpdates)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-updates-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LocalStore(directory: directory)
    var off = Preferences(); off.checkForUpdates = false
    try store.save(off, as: "preferences.json")
    #expect(try store.load("preferences.json", as: Preferences.self)?.checkForUpdates == false)
    #expect(!AppUpdater.automaticChecks(off))
    #expect(AppUpdater.automaticChecks(Preferences()))
    var localOnly = Preferences(); localOnly.localOnly = true
    #expect(!AppUpdater.automaticChecks(localOnly))
}

@MainActor @Test func settingsDriveTheInstalledUpdater() {
    final class Spy: AppUpdating {
        var states: [Bool] = []
        var started = 0
        func setAutomaticChecks(_ enabled: Bool) { states.append(enabled) }
        func start() { started += 1 }
    }
    let spy = Spy()
    let settings = CurrentValueSubject<Preferences, Never>(Preferences())
    let following = AppUpdater.follow(settings, with: spy)
    defer { following.cancel() }
    #expect(spy.states == [true])
    #expect(spy.started == 1)
    var next = settings.value; next.playSounds.toggle(); settings.send(next)
    #expect(spy.states == [true], "Unrelated changes do not touch the updater")
    next.localOnly = true; settings.send(next)
    next.localOnly = false; next.checkForUpdates = false; settings.send(next)
    next.checkForUpdates = true; settings.send(next)
    #expect(spy.states == [true, false, true])
    #expect(spy.started == 1)
}

// MARK: - Sparkle against a throwaway host bundle

/// Records every call Sparkle makes to its user interface. All of them would be visible to a person.
private final class UserDriverSpy: NSObject, SPUUserDriver {
    var calls: [String] = []
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) { calls.append("permission") }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { calls.append("userInitiatedCheck") }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) { calls.append("updateFound") }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) { calls.append("releaseNotes") }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) { calls.append("releaseNotesFailed") }
    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) { calls.append("notFound"); acknowledgement() }
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) { calls.append("error"); acknowledgement() }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { calls.append("download") }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { calls.append("downloadLength") }
    func showDownloadDidReceiveData(ofLength length: UInt64) { calls.append("downloadData") }
    func showDownloadDidStartExtractingUpdate() { calls.append("extract") }
    func showExtractionReceivedProgress(_ progress: Double) { calls.append("extractProgress") }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { calls.append("readyToInstall") }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) { calls.append("installing") }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { calls.append("installed"); acknowledgement() }
    func showUpdateInFocus() { calls.append("focus") }
    func dismissUpdateInstallation() {}
}

/// Answers every request with 404 and counts them, like the feed URL before launch.
private final class NotFoundServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var count = 0
    private(set) var lastRequest = ""
    var requests: Int { lock.withLock { count } }
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                self?.lock.withLock { self?.count += 1; self?.lastRequest = String(decoding: data ?? Data(), as: UTF8.self) }
                let reply = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: .global())
        guard ready.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileReadUnknown) }
    }
    var port: UInt16 { listener.port?.rawValue ?? 0 }
    func stop() { listener.cancel() }
}

/// A minimal app bundle Sparkle can host: Mouthy's own feed settings, but the feed at `feed` and its own
/// defaults domain, so the real app's Sparkle state is never touched.
private func hostBundle(feed: String, name: String) throws -> (Bundle, URL, String) {
    let real = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: sourceRoot.appendingPathComponent("Resources/Info.plist")),
                                                                    format: nil) as? [String: Any])
    // A fixed defaults domain per test, emptied before and after each use, so runs leave no stray preference files.
    let identifier = "dev.mouthy.updates-test.\(name)"
    UserDefaults.standard.removePersistentDomain(forName: identifier)
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("MouthyUpdatesTest-\(UUID().uuidString).app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    var info = real
    info["CFBundleIdentifier"] = identifier
    info["CFBundleVersion"] = "1"
    info["SUFeedURL"] = feed
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
    return (try #require(Bundle(url: app)), app, identifier)
}

/// Runs one background check and waits until Sparkle finishes its cycle (or 10 s pass).
@MainActor private func backgroundCheck(_ sparkle: SparkleUpdater) async -> (finished: Bool, error: (any Error)?) {
    var outcome: (Bool, (any Error)?) = (false, nil)
    sparkle.cycleFinished = { outcome = (true, $0) }
    sparkle.updater.checkForUpdatesInBackground()
    for _ in 0..<100 where !outcome.0 { try? await Task.sleep(for: .milliseconds(100)) }
    sparkle.cycleFinished = nil
    return outcome
}

@MainActor @Test func sparkleFollowsThePreferenceAndFeedFailuresStaySilent() async throws {
    let server = try NotFoundServer()
    defer { server.stop() }
    let (bundle, app, identifier) = try hostBundle(feed: "http://127.0.0.1:\(server.port)/updates/appcast.xml", name: "missing")
    defer { try? FileManager.default.removeItem(at: app); UserDefaults.standard.removePersistentDomain(forName: identifier) }
    let spy = UserDriverSpy()
    let sparkle = SparkleUpdater(hostBundle: bundle, userDriver: spy)

    sparkle.setAutomaticChecks(true)
    #expect(sparkle.updater.automaticallyChecksForUpdates)
    #expect(sparkle.updater.automaticallyDownloadsUpdates, "Updates install on quit")
    #expect(sparkle.updater.updateCheckInterval == 86_400)
    #expect(!sparkle.updater.sendsSystemProfile)
    sparkle.start()
    #expect(sparkle.updater.canCheckForUpdates, "Sparkle starts with Mouthy's Info.plist settings")

    // The feed answers 404 (it will until launch): the check ends with an error nobody sees, once.
    let missing = await backgroundCheck(sparkle)
    #expect(missing.finished)
    #expect(missing.error != nil)
    #expect(server.requests == 1)
    try await Task.sleep(for: .seconds(2))
    #expect(server.requests == 1, "No retries after a failed check")
    #expect(spy.calls.isEmpty, "Feed failures show nothing: \(spy.calls)")
    // What reaches the feed (docs/privacy.md): a plain GET, no query or cookies, and these headers only. The
    // user agent is "<app name>/<app version> Sparkle/<version>" (here the test runner, in the app "Mouthy").
    let lines = server.lastRequest.components(separatedBy: "\r\n").filter { !$0.isEmpty }
    #expect(lines.first == "GET /updates/appcast.xml HTTP/1.1")
    let headers = Set(lines.dropFirst().compactMap { $0.split(separator: ":").first.map { $0.lowercased() } })
    #expect(headers == ["host", "accept", "accept-language", "accept-encoding", "connection", "user-agent"], "\(lines)")
    #expect(lines.contains { $0.hasPrefix("User-Agent: ") && $0.hasSuffix(" Sparkle/2.10.0") })

    // Turning the setting off (or Local Only Mode, through AppUpdater.automaticChecks) stops every check.
    sparkle.setAutomaticChecks(false)
    #expect(!sparkle.updater.automaticallyChecksForUpdates)
    #expect(!sparkle.updater.automaticallyDownloadsUpdates)
    let refused = await backgroundCheck(sparkle)
    #expect(refused.finished)
    #expect(server.requests == 1, "Off means no request at all")
    #expect(spy.calls.isEmpty)
    sparkle.setAutomaticChecks(true)
    #expect(sparkle.updater.automaticallyChecksForUpdates)
}

@MainActor @Test func unreachableFeedStaysSilent() async throws {
    // A port nothing listens on: grab a free one, then close it.
    let closed = try NotFoundServer()
    let port = closed.port
    closed.stop()
    try await Task.sleep(for: .milliseconds(200))
    let (bundle, app, identifier) = try hostBundle(feed: "http://127.0.0.1:\(port)/updates/appcast.xml", name: "unreachable")
    defer { try? FileManager.default.removeItem(at: app); UserDefaults.standard.removePersistentDomain(forName: identifier) }
    let spy = UserDriverSpy()
    let sparkle = SparkleUpdater(hostBundle: bundle, userDriver: spy)
    sparkle.setAutomaticChecks(true)
    sparkle.start()
    let outcome = await backgroundCheck(sparkle)
    #expect(outcome.finished)
    #expect(outcome.error != nil)
    #expect(spy.calls.isEmpty, "An unreachable feed shows nothing: \(spy.calls)")
}

