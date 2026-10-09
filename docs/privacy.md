# Privacy and security

Mouthy is built so that what you say stays on your computer.

## What is stored

- **Dictation audio** stays in memory while you speak and is discarded afterwards. It is never written to disk.
- **History** of dictated text is off by default. If you turn it on, it is kept on your computer only.
- **Meetings** save audio only after you press Start, together with the transcript and notes Mouthy writes from it. On the Mac and Linux the folder is readable only by your user account; on Windows it is `Documents\Mouthy Meetings`.
- **Settings** and the agent key are stored in your user's application folder, readable only by you.
- **Notch hub (Mac)** items you create (notes, todos, timers, shelf items, shortcuts, the weather city and the tab layout) are kept as plain files in Mouthy's application folder.
- **Your voiceprint (Mac)**, if you train "Only listen to my voice", is a short list of numbers that describes your voice, not a recording. Mouthy listens while you read three sentences, keeps only those numbers in `voiceprint.json` in its application folder (readable only by you), and drops the audio. It is never sent anywhere. "Forget my voice" in Settings deletes it. The voice model that compares voices (WeSpeaker ResNet34, about 13 MB, on the Neural Engine) ships inside the app; nothing is downloaded for it.

## Network use

Mouthy has no telemetry, analytics or account. It goes online only for these, and Local Only Mode blocks all of them:

- **Speech models** you chose to download, from Hugging Face or GitHub (which, like any download, see your IP address). Desktop and Intel model archives and Mac Whisper tokenizer files use pinned checksums. Mac Core ML model downloads follow their SDK's upstream revisions; see [Speech engines](engines.md#integrity) for the integrity limits.
- **Helper models (Mac).** With Parakeet or Whisper, Mouthy also downloads the small Silero voice-activity model (about 1 MB). The first meeting notes made from a call's audio download a speaker-separation model. Apple Speech's language files are downloaded and managed by macOS.
- **Notch hub (Mac).** While a song plays and the Music tab is on (it is by default), the song's title, artist, album and length go to [LRCLIB](https://lrclib.net) for lyrics, and its title and artist to Apple's iTunes Search for the artwork. The Weather tab, off by default, sends the city you type to [Open-Meteo](https://open-meteo.com) and then its coordinates for the forecast.
- **Updates (Mac).** While "Check for updates automatically" is on (the default; Settings → Privacy), Mouthy asks `https://mouthy.dev/updates/appcast.xml` once a day whether a new version exists. The request is a plain GET with no identifiers: it carries the app's name and version and the updater's (`User-Agent: Mouthy/<version> Sparkle/<version>`) and your preferred languages (`Accept-Language`, added by macOS). It sends no macOS version or hardware details (Sparkle's system profile stays off), though, like any request, it shows your IP address to the server. A new version downloads in the background, is installed only if it carries Mouthy's signature, and replaces the app when you quit. If the feed cannot be reached, nothing is shown and the next check waits a day.

Everything else stays on your computer or goes where you point it:

- the [agent bridge](agents.md) and an optional local Ollama model talk over the loopback address `127.0.0.1`,
- the optional sync writes to a folder you choose,
- questions you ask the notch ("Mouthy, …") are answered by Apple Intelligence's model on your Mac. Only the question is given to it, never your history, clipboard, screen or apps; nothing goes online, and neither the question nor the answer is saved.

## Typing into other apps

- Mouthy pastes into the focused app only when you finish dictating, and checks that focus has not moved elsewhere before it pastes and before it presses Return.
- On the Mac it refuses password fields and secure input. Windows refuses password fields and stops automatic insertion when the field's protection cannot be read. Linux provides no portable password-field check. Automatic Return is withheld when the original target can no longer be verified; on Linux this requires a desktop that reports the focused app.
- Your clipboard is restored after pasting, unless something else changed it in the meantime.
- Nothing you say can send, click or run anything in other apps. Mouthy only pastes the text (⌘V on the Mac, Ctrl+V or `wtype` elsewhere) and, while you dictate, acts on Enter (send) and Escape (cancel). The one exception on the Mac is the notch's own commands (a timer, a note, or a reminder saved to Reminders), and outside the notch only when you start with "Mouthy".

## Links and web pages

On the Mac, `mouthy://` links opened from a web page are refused (except `cancel`), so a page cannot start a recording or receive what you said.

## Permissions

- **Mac:** Microphone (used only while dictating or recording a meeting), Speech Recognition (for Apple Speech), Accessibility (to paste into other apps), Input Monitoring (while you dictate, Mouthy watches key presses so Enter sends and Escape cancels; every other key passes straight through and nothing is stored) and, for meetings, system audio recording (for the call's audio). The notch hub asks for Calendars and Reminders when you connect them in the Calendar tab, and for permission to ask Spotify or Music what is playing while one of them runs.
- **Windows and Linux:** microphone access. On Windows a keyboard hook, installed only while you dictate, takes Enter the same way; on Hyprland, Enter is bound to Mouthy only while you dictate. On Wayland, pasting needs `wl-clipboard` and `wtype`; X11 needs nothing extra.

## Reporting a problem

See [SECURITY.md](../SECURITY.md).
