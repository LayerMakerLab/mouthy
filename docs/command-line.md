# Command line

## Mac

The app binary doubles as a command-line tool. From a source checkout, `mac/scripts/mouthy` runs the installed app (or your local build) with the same arguments.

```sh
Mouthy models                                  # list downloaded models
Mouthy download parakeet
Mouthy download whisper --model base.en        # base.en, small, medium or turbo
Mouthy transcribe meeting.m4a --engine parakeet
Mouthy transcribe talk.mp4 --engine whisper --model small --format srt --output talk.srt
Mouthy --help
```

`transcribe` options:

| Option | Meaning |
| --- | --- |
| `--engine apple\|parakeet\|whisper` | Speech engine (default: apple) |
| `--model base.en\|small\|medium\|turbo` | Whisper model; download it first |
| `--language auto\|en\|en-US\|…` | Language; Whisper can detect it |
| `--prompt TEXT` | Vocabulary and spelling hints |
| `--translate` | Translate into English (Whisper small and medium) |
| `--format text\|json\|srt\|vtt` | Output format (default: text) |
| `--output FILE` | Write to a new file; never overwrites |
| `--output-dir DIR` | Output folder, required for several inputs |

Transcription only uses models that are already downloaded. Results from the command line are not added to history or typed into apps.

Other commands: `Mouthy --open` opens the main window, `Mouthy --headless` runs shortcut dictation with no windows or menu, `Mouthy mic-test [seconds] [apple|parakeet|whisper]` records from the default microphone and prints what it heard, and `Mouthy bench-live recording.wav [parakeet|whisper]` replays a recording in real time and prints how long the text takes to be ready after you stop, with and without live recognition.

The running app also responds to links: `open mouthy://toggle` (also `start`, `stop`, `cancel`, `paste-last`, `open`).

## Windows and Linux

```sh
mouthy --toggle                  # start or finish dictation (bind this to a key on Wayland)
mouthy --cancel                  # throw the current recording away
mouthy --paste-last              # paste the last result again
mouthy --background              # start in the tray without opening the window
mouthy download parakeet
mouthy download whisper base.en  # tiny.en, base.en, small, medium or turbo
mouthy transcribe recording.wav  # uses the engine chosen in Settings
mouthy mic-test 6                # record 6 seconds and print the transcript
mouthy --mcp-bridge              # stdio bridge for AI agents, see agents.md
```
