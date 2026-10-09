# Features

Where a feature differs between platforms, the difference is noted.

## Dictation

- **Start and stop.** Press the shortcut, speak, press it again. Defaults: double-tap the right ⌘ on the Mac (⌃⌥Space and Hold Fn are in Settings → Shortcut), Ctrl+Alt+Space on Windows. On Wayland, apps cannot register global shortcuts, so bind a key to `mouthy --toggle` in your compositor.
- **Double-tap Right ⌘ (Mac, the default).** Two quick taps of the right Command key start dictation and two more stop it. Each tap must be short (under 0.3 s) and the second must follow within 0.4 s; holding left ⌘, ⌃, ⌥ or ⇧ at the same time does not count, so ordinary ⌘ shortcuts never start a recording. Like Hold Fn, it uses the Accessibility permission.
- **Where text goes.** The text is pasted wherever your cursor is when you finish. Mouthy never types into a password field on the Mac or Windows. Linux offers no way to detect one, so take care there.
- **Fitted to the surrounding text.** Spacing and capitals match the text already around the cursor (Mac and Windows).
- **Your clipboard is put back.** Mouthy pastes through the clipboard and then restores what was there before. Text and images are restored everywhere; on the Mac, every type the clipboard can hand over. On the Mac the dictated words are marked as transient while they pass through the clipboard, so clipboard history apps that follow the nspasteboard.org convention do not record them, and the restored contents are not listed as a new copy.
- **Enter sends, Escape cancels.** While you dictate into another app, Enter pastes what you have said so far, presses Return and keeps listening. On the Mac this works from the first moment, before any live text has appeared (Parakeet and Whisper show their preview a little later); if nothing has been said yet, Enter simply reaches the app once. Shift, Option, Command or Control with Return pass through untouched. Escape throws the recording away. On the Mac, Enter-to-send needs the Input Monitoring permission.
- **"Sent" when you finish.** If everything you said was already sent with Enter, finishing reports **Sent** and keeps the last sent text as the result, instead of offering an old preview.
- **Speech only types.** Nothing you say can send, click or run anything; only the keys do.
- **Only listen to my voice (Mac, Parakeet and Whisper).** In Settings → Speech, click "Train my voice" and read three short sentences out loud (about 15 seconds). A TV or music can stay on: Mouthy keeps the voice it hears most while you read and leaves other voices out. Then switch on "Only listen to my voice": other voices, a TV and music are turned down while you dictate, so only your words are typed. When Mouthy isn't sure whose voice it hears, it keeps the words. "Retrain" and "Forget my voice" sit beside the switch. Mouthy keeps a voiceprint, never the recording (see [Privacy](privacy.md)).
- **Paste last.** ⌃⌘V on the Mac and Ctrl+Super+V on Windows and X11 paste the last result again; on Wayland, bind a key to `mouthy --paste-last`.

## Text rules

The same rules on every platform:

- **Spoken punctuation:** "comma", "period", "question mark", "new line", "new paragraph" and more.
- **Corrections:** "scratch that" drops the last sentence.
- **Filler removal:** "um", "uh", "erm" and similar are dropped; words like "umbrella" are left alone.
- **Replacements:** exact phrases you define, for example "my sig" → your sign-off.
- **Code dictation:** "camel case user name" → `userName`, "file dot swift" → `file.swift`.

## Vocabulary

Add names and terms Mouthy should spell correctly.

- **Mac:** your list steers Apple Speech and Parakeet toward those words, and Mouthy learns from corrections you make right after dictating.
- **Windows and Linux:** the list is kept and synced, but does not yet steer recognition.

## Modes

A mode is a profile with its own writing style, engine and result: insert, insert and press Return, copy only, or history only. A mode is chosen by:

1. a spoken trigger word at the start of what you say,
2. its own shortcut,
3. the website you are on (the page address on the Mac; the window title on Windows and Linux),
4. the app you are in.

A mode chosen by a trigger word or a window title inserts but never presses Return.

## Writing styles (optional)

The default style, Natural, keeps your words as spoken and uses no AI model. Grammar, Clean up, Concise and your own instructions rewrite the text with Apple Intelligence on the Mac, or with a local [Ollama](https://ollama.com) model on Windows and Linux.

On the Mac, cleanup and selection rewrites get 20 seconds. If the model takes longer, your original words are used and Mouthy says so ("Cleanup took too long; original wording kept."); a slow rewrite leaves the selection unchanged. The dictation itself never fails because of it.

## Notch hub (Mac)

A panel that opens from the notch at the top of the screen: hover over the notch or click it, or press ⌃⌥N from anywhere; Esc closes it. On a display without a notch, nothing is shown at rest and the hub drops down from the top centre of the screen. It hides while an app is in full screen.

- **Tabs:** five show by default: Mouthy, Timers and Pomodoro, Todos and notes, Music with lyrics, and Calendar and Reminders. Clipboard, Shelf with AirDrop, Weather, Shortcuts and AI usage are one switch away in Settings. ⌘1–9, ⌃Tab and a sideways swipe switch tabs.
- **Your choice:** Settings turns the hub on or off and sets the tab order, hidden tabs, hover delay and haptics.
- **Private:** the Clipboard tab keeps its list in memory only and skips passwords and transient items. Weather uses a city you type, not your location.
- **Talk to it:** dictate from the Mouthy tab's mic and say "timer 10 minutes", "note call mom" or "remind me at 5 to call mom" (a bare hour is the next one on a 12-hour clock). The timer starts, the note is added to Todos and notes, the reminder goes to Reminders (Mouthy asks for access the first time), and the notch confirms in one line; nothing is pasted. Anything else you say is pasted as usual.
- **From any app:** start with "Mouthy", as in "Mouthy, note buy milk" or "Mouthy, timer 5 minutes", and the same commands work in any dictation, with the hub open or closed (with it open, the confirmation shows once it closes). Without the name, dictation is never taken as a command. Commands stay out of history and Paste last.
- **Questions:** "Mouthy, what's 12 times 12?" is answered in the notch by Apple Intelligence on your Mac in one or two sentences: "Thinking…", then the answer for 12 seconds. Only the question goes to the model; it runs on the Mac, nothing goes online, and the answer is never pasted or saved. Escape or starting a new dictation drops a question still being answered. With the hub open, the answer waits and shows when it closes, for the rest of its 12 seconds. With Apple Intelligence off, the notch says how to turn it on.
- **Local Only Mode:** turns off every network request the tabs make (lyrics, artwork and weather).
- **Idle cost:** the hub does not poll in the background, with one exception: if you turn the Clipboard tab on, Mouthy reads the clipboard's change counter every 1.5 seconds, because macOS has no notification for copies.

## The Mac app

- **Look.** Mouthy is themed around its giraffe mascot: warm cocoa, giraffe orange and mic-glow amber, floating tiles and Liquid Glass controls. The giraffe shows what is happening: it sleeps when idle, listens while you speak, cheers when text lands and looks sleepy when something did not.
- **Where you see a recording.** On a display with the notch hub running, the recording shows as a pill in the notch; otherwise as an island at the top edge of the screen or in a corner.
- **First run.** Eight short steps cover the microphone, Accessibility, speech, the shortcut, a practice box and what Mouthy does while you are quiet; Hello shows a live 3D giraffe that turns toward your pointer.
- **Menu bar.** The panel shows one Record/Stop button, the mode for the next dictation, the last result and the few before it. Those recent results are kept in memory only.
- **Pages.** Dictate, Modes, Files, Meetings, History (grouped by day), Vocabulary and Settings. Settings save themselves as you change them.

## Meetings

Records your microphone and the system audio as separate files, only after you press Start, and transcribes them. On the Mac, the transcript also separates speakers and comes with a summary and action items. While a meeting records, the dictation shortcuts and Escape are ignored, so a stray key cannot stop it; stop it from Mouthy.

## File transcription

- **Mac:** audio and video files to text, JSON, SRT or VTT, from the app or the [command line](command-line.md).
- **Windows and Linux:** WAV files from the command line.

## AI agents

Agents such as Claude Code can ask you a question and get your spoken answer. See [AI agents](agents.md).

## Links (Mac)

`mouthy://toggle`, `start`, `stop`, `cancel`, `paste-last` and `open` work from Shortcuts, Raycast and similar launchers. Links opened from a web page are refused (except `cancel`), so a page cannot start dictation or read what you said.

## Sync

Vocabulary and replacements can be shared between your computers through any folder you sync yourself, such as a cloud drive folder. Modes sync between Macs.

## Idle cost

Nothing listens or draws while you are not dictating; the recording overlay exists only while you speak. The only idle work is the optional sync, which checks its folder every ten minutes on Windows and Linux.
