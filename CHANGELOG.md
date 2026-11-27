# Changelog

## 0.1.8

- A new look on Mac, Windows and Linux: calm charcoal with one leaf-lime accent in place of the brown and copper. On the Mac, windows are paper white in Light mode, and the giraffe is the only orange thing left on screen.
- Mac: the notch hub is redrawn. Every tab has more room around its content, counts and sections sit on soft tiles, buttons are plain rounded rectangles instead of glass capsules, the selected tab is marked by a small dot, Shortcuts shows three columns, and the Timers tab is laid out again with one control for Focus, Break and Timer. The notch's size and position are unchanged.
- Mac: the close, minimize and full-screen buttons of the main window sit inside the sidebar, in line with the wordmark.
- Mac: Type as I speak (Settings → Writing, off by default). The words go into the text field while you talk instead of all at once when you stop. With Parakeet and Whisper a phrase is typed each time you pause, a second or two after it ends, and stays as it is while you talk; when you stop, the rest is added. With Apple's speech or Show words instantly, words are typed one at a time a moment after you say them, and the text is corrected once when you stop. Typing or clicking yourself stops it; the rest is pasted when you finish.
- Mac with Apple silicon: Show words instantly (Settings → Writing, off by default, English only, a 214 MB download). A second, small speech model shows each word about a tenth of a second after you say it; capitals, punctuation and corrections follow at every pause.
- Mac: while you dictate, the words you have said so far show on a card under the notch, newest at the bottom, so you can see what you already said. The card goes away when you stop.
- Mac: an AI usage tab for the notch (off by default). Pick the AI services you pay for and each shows how much of its 5-hour and weekly or monthly limit is used, as two rings, read only from files those tools already keep on your Mac.
- Mac: "Read agent questions aloud" speaks in Mouthy's own voice, trained for Mouthy and run on your Mac. The system voice remains the fallback.
- Spoken marks, on Mac, Windows and Linux: say "dash", "dot", "slash" or "underscore" where you want the mark and it is written when the words around it make that clear: well-known, example.com, readme.md, --help, example.com/docs, user_name. "A mad dash" and "slash prices" stay words. A dictation that is only "slash clear" is written /clear. Speech still never presses Return.
- Mac: a pause to think in the middle of a sentence no longer ends it with a period.
- Mac: a breath or a key press right after your last word is no longer written as a word ("Yeah.").
- Windows and Linux: spoken years are written as numbers, as on the Mac since 0.1.7: "twenty nineteen" becomes 2019.
- New installs can download the Parakeet speech model again. Its publisher replaced the file on November 7, and Mouthy, which checks every download against a known fingerprint, refused the new one. This affected new installs on Windows, Linux and Intel Macs; copies that already had the model kept working.
- The Chat example mode only inserts. Sending stays your choice.

## 0.1.7

- Spoken years are written as numbers: "twenty nineteen" becomes 2019, "nineteen ninety-eight" 1998, "nineteen oh five" 1905 and "two thousand nine" 2009. Counting ("eighteen, nineteen, twenty") and amounts ("eighteen hundred and fifty dollars") stay in words. On Mac, Windows and Linux.
- Mac: custom words are written the way you spell them. When the speech model hears one of your words as something that isn't a real word ("Alama" for Ollama, "Makerworld" for MakerWorld, "X field" for Pixfield), Mouthy writes your word. Real words and common names are never swapped.
- Mac: a replacement that only changes capitals no longer lowercases a word you said at the start of a sentence or as a name. A rule like "claude" → "claude" leaves "Claude" alone.
- Mac: the spelling check behind custom words uses your dictation language only, not every language installed on the Mac, so made-up words are no longer taken for real ones.

## 0.1.6 (Windows and Linux)

- Mouthy updates itself on Windows and Linux: a minute after it starts and then once a day it asks mouthy.dev for a newer version, downloads the same archive you would download by hand, keeps it only if it carries Mouthy's signature, and swaps it in when you quit or the next time it starts. Settings → "Check for updates automatically" turns it off; Local Only Mode never checks. Copies installed from this version on get updates; earlier ones need one last download by hand.

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
