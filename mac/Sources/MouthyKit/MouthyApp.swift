import SwiftUI
import AppKit
import MouthyCore
import MouthyNotch
import AVFoundation

struct MouthyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared
    var body: some Scene {
        MenuBarExtra(isInserted: .constant(!CommandLine.arguments.contains("--headless"))) {
            MenuBarPanel(model: model)
        } label: {
            Image(nsImage: Mascot.menuBarImage(listening: model.phase == .listening))
                .accessibilityLabel(model.phase == .listening ? "Mouthy, listening" : "Mouthy")
                .help("Mouthy. Press \(model.shortcutLabel) to dictate.")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel.shared
    private var mainWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var activationObserver: NSObjectProtocol?
    private var terminating = false
    private var quitReplied = false
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { model.savePreferences() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task { await model.shutdown(); replyToQuit(sender) }
        // A cleanup step that never finishes must not hold Quit open (the app once stayed in _shouldTerminate until
        // it was killed). Shutdown logs each step, so the stuck one shows in the log.
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard !quitReplied else { return }
            Diagnostics.dictation.error("quit: shutdown still running after 3 s; quitting anyway")
            replyToQuit(sender)
        }
        return .terminateLater
    }
    private func replyToQuit(_ sender: NSApplication) {
        guard !quitReplied else { return }
        quitReplied = true
        sender.reply(toApplicationShouldTerminate: true)
    }
    func applicationDidBecomeActive(_ notification: Notification) { model.refreshPermissions(); model.syncNow(quiet: true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow(); return false
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Windows follow the Mac's Light or Dark appearance (2026-10-21); the notch and pill pin dark.
        NSApp.appearance = nil
        NSApp.setActivationPolicy(.accessory)
        model.openWorkspace = { [weak self] in self?.openMainWindow() }
        model.overlay = OverlayController(model: model)
        model.overlay?.hide()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.model.refreshPermissions() }
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(receiveOpenRequest), name: .init("dev.mouthy.Mouthy.open"), object: nil)
        NotificationCenter.default.addObserver(forName: .mouthyReplayWelcome, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showOnboarding() }
        }
        if CommandLine.arguments.contains("--open") { openMainWindow() }
        // Without Accessibility the global modifier shortcuts receive no key events (⌃⌥Space stands in meanwhile,
        // `HotkeyService.standsIn`). Ask macOS to show its prompt; it shows once per install and never after a
        // Deny, so the setup screen for Accessibility opens as well whenever the chosen shortcut depends on it.
        let headless = CommandLine.arguments.contains("--headless")
        let needsAccessibility = !headless && !TextDelivery.accessibilityAllowed && (model.preferences.shortcut == 4 || model.preferences.shortcut == 5)
        if !TextDelivery.accessibilityAllowed { TextDelivery.requestAccessibility() }
        if model.preferences.agentVoice { model.agentServer.start() }
        Mascot.install()
        model.prewarmSpeech()
        MouthyTabs.setHub(enabled: model.preferences.notchHub)
        // First run, or macOS has never been asked about the microphone for this copy of Mouthy (a reinstall, or a
        // reset permission): setup gets it going instead of leaving the person in Settings.
        if !model.preferences.onboarded || AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { showOnboarding() }
        else if needsAccessibility { showOnboarding(step: .accessibility) }
        model.syncNow(quiet: true)
    }
    /// mouthy://toggle | start | stop | cancel | paste-last | open — for Shortcuts,
    /// launchers such as Raycast.
    func application(_ application: NSApplication, open urls: [URL]) {
        let fromBrowser = Self.linkSenderIsBrowser()
        for url in urls where url.scheme == "mouthy" {
            let command = url.host ?? url.path
            if command == "open" { openMainWindow(); continue }
            // A web page must never receive dictation: whatever is said would be pasted into the page.
            // From browsers only cancel works; everything else is for launchers and Shortcuts.
            if fromBrowser && command != "cancel" { model.status = "Mouthy links only work from launchers and Shortcuts, not web pages."; continue }
            // Opening a link activates Mouthy; step back so the app the person was using is the target.
            if mainWindow?.isVisible != true { NSApp.hide(nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [model] in
                switch command {
                case "toggle": model.toggle(captureTarget: true)
                case "start": if !model.busy { model.begin(captureTarget: true) }
                case "stop": model.stop()
                case "cancel": model.cancel()
                case "paste-last": model.pasteLast()
                default: break
                }
            }
        }
    }
    /// True when the app that opened the link handles web URLs itself (a browser), so a page sent it.
    private static func linkSenderIsBrowser() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let pid = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value,
              let bundleURL = NSRunningApplication(processIdentifier: pid)?.bundleURL,
              let types = Bundle(url: bundleURL)?.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] else { return false }
        return types.contains { ($0["CFBundleURLSchemes"] as? [String] ?? []).contains { ["http", "https"].contains($0.lowercased()) } }
    }
    @objc private func receiveOpenRequest(_ notification: Notification) {
        openMainWindow()
        if let requestedPath = notification.userInfo?["requestedBundlePath"] as? String,
           requestedPath != Bundle.main.bundleURL.standardizedFileURL.path {
            model.status = "Another copy of Mouthy is already running from \(Bundle.main.bundleURL.path). Quit this copy before opening the other build."
        }
    }
    func showOnboarding(step: OnboardingStep = .hello) {
        if let onboardingWindow { onboardingWindow.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        // Get the chosen engine ready while the permissions are allowed, so Try it never waits on a screen of its own.
        Task { [model] in
            await model.refreshCapabilities()
            if !model.speechAssetsReady && !model.preferences.localOnly { model.installAssets() }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden; window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(MouthyTheme.night)
        window.contentView = NSHostingView(rootView: OnboardingView(model: model, step: step) { [weak self] in
            // Leave the button's action before its hosting view is released.
            DispatchQueue.main.async { self?.finishOnboarding() }
        })
        // The red close button runs the same finish path as Done (windowWillClose).
        window.delegate = self
        window.center(); onboardingWindow = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil); NSApp.activate()
    }
    /// Marks setup done, saves, and tears the window down so nothing in it keeps running.
    private func finishOnboarding() {
        guard let window = onboardingWindow else { return }
        onboardingWindow = nil
        model.preferences.onboarded = true
        model.savePreferences()
        window.delegate = nil
        if window.isVisible { window.close() }
        window.contentView = nil
        if mainWindow == nil { NSApp.setActivationPolicy(.accessory) }
    }
    func openMainWindow() {
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Mouthy"; window.identifier = NSUserInterfaceItemIdentifier("main")
            window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.minSize = NSSize(width: 900, height: 640); window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("MainWindow")
            window.contentView = NSHostingView(rootView: WorkspaceView(model: model))
            window.delegate = self; window.center(); mainWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil); NSApp.activate()
        Task { await model.refreshCapabilities() }
    }
    func windowWillClose(_ notification: Notification) {
        let window = notification.object as? NSWindow
        if let window, window === onboardingWindow {
            // Defer so AppKit finishes closing before the content view is released.
            DispatchQueue.main.async { [weak self] in self?.finishOnboarding() }
            return
        }
        if onboardingWindow == nil { NSApp.setActivationPolicy(.accessory) }
        Task { @MainActor [weak self] in self?.mainWindow = nil }
    }
}

extension Notification.Name {
    /// Settings → "Say hi again" replays the welcome tour.
    static let mouthyReplayWelcome = Notification.Name("dev.mouthy.replayWelcome")
}
