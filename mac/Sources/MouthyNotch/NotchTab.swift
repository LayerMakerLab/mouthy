import SwiftUI

/// A small count or dot on a tab's rail icon. The host picks the tint (for example, copper, moss, ember);
/// without one the hub draws neutral grey.
public struct NotchBadge: Equatable, Sendable {
    public enum Tone: Sendable { case neutral, active, attention }
    public var count: Int
    public var tone: Tone
    public var tint: Color?
    public init(count: Int, tone: Tone = .neutral, tint: Color? = nil) {
        self.count = count; self.tone = tone; self.tint = tint
    }
    /// Something running or waiting on you: the only badges the compact rail beside the camera shows.
    public var isLive: Bool { tone != .neutral }
}

/// One page of the notch hub. Tabs push changes with `NotchHub.shared.tabDidChange(id:)`; the hub never polls.
@MainActor public protocol NotchTab: AnyObject {
    /// Stable identifier, e.g. "mouthy.clipboard" or "host.agents".
    var id: String { get }
    var title: String { get }
    /// SF Symbol shown in the tab rail.
    var symbolName: String { get }
    var badge: NotchBadge? { get }
    /// When this turns true the hub briefly opens on this tab (an agent needs you, a timer ended).
    var prefersAttention: Bool { get }
    /// Content inside the open notch. Called when the tab is shown, not continuously.
    func makeBody() -> AnyView
    /// Optional content beside the closed notch, e.g. "2 need you". Keep it to a few words.
    func compactBody() -> AnyView?
    /// When several tabs have compact content, the highest priority shows (a meeting beats a song).
    var compactPriority: Int { get }
    /// The tab's live colour (album art, weather, a running timer) for its own content to use; the panel itself stays black.
    var ambientColor: Color? { get }
    /// Optional live content left of the camera while closed (album art, a timer ring). Nil: the tab's symbol.
    func compactLeading() -> AnyView?
    /// A few words for the middle of the pill on displays without a notch (song title, "Focus").
    var compactCaption: String? { get }
}

public extension NotchTab {
    var badge: NotchBadge? { nil }
    var prefersAttention: Bool { false }
    func compactBody() -> AnyView? { nil }
    var compactPriority: Int { 0 }
    var ambientColor: Color? { nil }
    func compactLeading() -> AnyView? { nil }
    var compactCaption: String? { nil }
}

public extension EnvironmentValues {
    /// True when the open band beside the camera is tight and the host's status should drop its extras.
    @Entry var notchStatusShort = false
}
