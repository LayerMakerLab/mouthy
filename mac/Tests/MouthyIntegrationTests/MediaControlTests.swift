import Testing
@testable import MouthyKit

/// Pause sends the play/pause key, which goes to the Now Playing app: only real players count as playing, so a call
/// or a notification sound never makes Mouthy start a paused player. Reads only; never sends a key.
@MainActor @Test func onlyMediaPlayersCountAsPlaying() {
    for id in ["com.spotify.client", "com.apple.Music", "com.apple.WebKit.GPU", "com.google.Chrome.helper", "com.brave.Browser.helper.Renderer"] {
        #expect(MediaControl.isPlayer(id), "\(id)")
    }
    for id in ["us.zoom.xos", "com.apple.FaceTime", "com.tinyspeck.slackmacgap", "com.apple.notificationcenterui", "com.spotify.clientx", ""] {
        #expect(!MediaControl.isPlayer(id), "\(id)")
    }
    _ = MediaControl.mediaIsPlaying()  // reads the system's audio processes without failing
}
