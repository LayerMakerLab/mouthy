# Changelog

## 0.1.5

- Sentences no longer break in the middle with a stray period: soft words are no longer taken for pauses, and a word is no longer typed twice where two stretches of speech meet.
- Voice commands work the way people say them: "Hey Mouthy" or "And Mouthy" first, a misheard "Mouthy" fixed by your replacements, and "Mouthy, stop the timer" to stop a running timer. A command Mouthy doesn't understand shows in the notch instead of being typed.
- The notch opens with its content right away, and on Timers or Music while one is running.
- Quitting Mouthy never hangs.
- About and Settings → Privacy link to the privacy policy.
- Mouthy's windows follow the Mac's Light or Dark appearance: a sunlit cream look in Light mode, the night palette in Dark. The notch hub and the recording pill stay dark.
- Spoken clock times are written as digits: "eleven fifty eight", "at 1158" and "ten a.m." become 11:58 and 10 a.m. Counting, years and prices stay as they are.
- Snippets, contractions, addresses and custom words are kept as written: a dictation that is only a snippet's phrase returns the snippet exactly, replacements never cut into a contraction, an email address or URL at the start is not capitalized, and a custom word keeps its capitals mid-sentence. The words beside a custom word are no longer swapped out with it.
- Corrections you make to dictated text are learned as you edit, with Undo in the menu panel.
- Mouthy knows whether an app took a paste. When nothing did, the words stay on the clipboard and the panel says so instead of "Pasted". The Return sent after a paste no longer carries ⌘, so browsers no longer open a new tab.
- Pause only interrupts a player that is actually playing; paused music is never started.
- Clearer messages: the app holding Secure Keyboard Entry is named, a microphone that sent only silence is reported as such instead of "No speech detected", and a dictation stopped at the 10-minute limit says so.
- Dictating through a Bluetooth headset offers the built-in microphone once, for better sound.
- Words, replacements and modes removed on the Mac stay removed after a sync with another computer.
- Windows and Linux: a setting saved while a sync is running is no longer lost.
- Without Accessibility, double-tap right ⌘ and Hold Fn did nothing at all. Now ⌃⌥Space starts dictation until Accessibility is allowed, Mouthy says so, and the Accessibility setup screen comes back at launch (macOS's own prompt shows only once).
- Pressing the shortcut before the speech model was downloaded says so: "Download the model in Settings" instead of "Needs attention".

## 0.1.4

- Only listen to my voice can be trained with a TV or music on: Mouthy keeps your voice and leaves the others out of the voiceprint.

## 0.1.3

- The notch opens when you push the pointer against it from below or from either side, and when there's nothing to show, Mouthy keeps nothing on screen at the notch.

## 0.1.2

- The notch opens when you push the pointer up against it, and Mouthy no longer keeps invisible windows at the top of the screen.
- Words said after a failed mid-dictation send are no longer lost.
- Mouthy never pastes over a clipboard it can't put back, and waits for modifier keys to be released before pasting.
- A quick second Return while a message is being sent no longer submits it early.
- Stopping a meeting while it is still starting turns the microphone off.
- Code dictation keeps line breaks and names like index.html; "scratch that" stops at a spoken "period" or "new line".
- Windows and Linux: Whisper keeps dictations longer than 30 seconds, pasting no longer wipes copied files, Enter works on Linux when there is nothing to send, and removed vocabulary stays removed when syncing.

## 0.1.1

- Setup opens whenever macOS hasn't been asked about the microphone yet, and lets you pick which microphone to use.
- A microphone request that macOS never answers no longer leaves Mouthy waiting; it opens the Microphone settings instead.
- Faster capture and lower idle CPU, and safer typing on Windows (from the performance pass).
- The mascot no longer appears in the waving pose.

## 0.1.0

First public release.

- Mac app (macOS 26+, Apple silicon and Intel) with Apple Speech, NVIDIA Parakeet v3 and OpenAI Whisper.
- Windows and Linux app with NVIDIA Parakeet v3 and OpenAI Whisper.
- Text rules, modes, vocabulary, meetings, file transcription and an MCP server for AI agents.
- Mac notch hub: timers, notes, music, calendar and more in a panel that opens from the notch.
