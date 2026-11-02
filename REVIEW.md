# Reviewing Mouthy changes

For every reviewer of a Mouthy change, human or agent. Contributor setup: `CONTRIBUTING.md`.

## What failure looks like here

- **Words are lost or changed:** live recognition drops or adds a word the whole-file pass has, a stop cuts the last
  word, cleanup rewrites what was said, or the same speech and settings give different text in Mouthy and in a host
  app using `MouthyKit` (`DictationText` is the one set of text rules for both).
- **Text lands in the wrong place:** a paste into a password or secure field, a different app than the one that had
  focus, a Return nobody asked for, a clipboard that is not put back.
- **Audio or text leaves the Mac without being asked:** recognition, cleanup and history are on-device; only an
  explicitly chosen provider (Talk) may send audio, and its key is never stored or logged.
- **The microphone stays open** after a stop, cancel or failure, or two owners record at once (`MicrophoneOwner`).
- **It costs power while idle:** per-frame SwiftUI animation, a clock published through the whole model, polling, or
  work on the main thread during a dictation. Continuous motion runs on Core Animation only.
- **A host app breaks:** a public `MouthyKit`, `MouthyCore` or `MouthyNotch` API changes shape without the library
  manifest at the root and `mac/Package.swift` staying identical.
- **The public tree leaks:** a public file names a person, a host, an IP, a home path or a private project
  (`export-public.sh` fails on them).

## How to report

- Start with the count: "2 findings (1 Important, 1 Nit)" or "No findings."
- Every finding names a file and line and the input that breaks it. A guess from a name is not a finding.
- Tag each one **Important**, **Nit** or **Pre-existing** (a bug this change did not introduce).
- At most 3 Nits. Style-only, wording-only and "could add a log" findings are dropped.
- Flag the class of bug, so every instance is fixed, not one line.
- Skip: `mac/.build/`, `dist/`, `ThirdParty/`, model files, `Package.resolved` churn.

## Rounds

- Each finding is checked by two verifiers who read the code; it reaches the author only if both agree it is real.
- At most 3 review-and-fix rounds per change. After round 1, re-review only the new diff and never repeat a finding.
  Still failing after round 3: step back and rethink the approach.

## Depth by risk (set by what the change touches)

| Tier | Touches | Review |
| --- | --- | --- |
| Low | Docs, copy, tests only | One critic + the tests |
| Medium | Views, notch tabs, settings | Parallel critics with verifier votes + the tests |
| High | Speech engines, `DictationText`, text delivery, the microphone, Talk, the updater, signing and packaging, public APIs | The Medium path plus a security pass and the matching hardware or word-loss gate from `AGENTS.md` |
