# Contributing to Mouthy

Thanks for helping. These rules keep Mouthy fast, private and predictable:

- **Local only.** No cloud calls, telemetry or accounts. The network may be used only to download a model the user asked for.
- **Speech only types.** Nothing a person says may send, click or run anything. Keys such as Enter and Escape act; words do not.
- **Near-zero idle cost.** No timers, polling or animation while nothing is being dictated.
- **Same rules on every platform.** Text rules live in `mac/Sources/MouthyCore` (Swift) and `windows-linux/core` (Rust). Add a case to `shared/text-rules.json` for every change, so both test suites check it.
- **Tests never touch your screen.** Tests must not take keyboard focus or type into real apps; use the hidden test app (`./scripts/test.sh --delivery`).

## Before you open a pull request

```sh
cd mac && ./scripts/test.sh
cd ../windows-linux && cargo test
```

Keep one change per pull request, and describe what you changed and how you verified it. [Building and testing](docs/building.md) covers setup.

Found a bug? Open an issue with your platform, engine and steps to reproduce. Security problems go through [SECURITY.md](SECURITY.md) instead.

By contributing you agree that your work is licensed under the GPL-3.0.
