# Changelog

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
