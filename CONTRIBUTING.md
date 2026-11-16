# Contributing to SimpleWhispr

Thanks for wanting to help. SimpleWhispr is intentionally small, so the bar for a
good contribution is low. This guide covers how to build, test, and open a pull
request. The full build and architecture reference lives in `AGENTS.md` and
`README.md`; read those first.

## Before you start

- Keep the design contract: **local-first**. No telemetry, no cloud calls, and no
  API keys in the core transcription path. Nothing about audio or transcripts
  should leave the machine.
- Write source, comments, variables, and commit messages in **English**.
- No emojis and no em-dashes in code, comments, or docs.
- The Swift target runs in **Swift 5 language mode** on purpose (see
  `Package.swift`). Do not flip it to Swift 6 mode.
- Do not move or rename the install path (`~/Applications/SimpleWhispr.app`); it
  is tied to TCC permissions.

## Prerequisites

- macOS 15+ (Sequoia), Apple Silicon.
- Xcode 15+ (for the `swift` toolchain).
- The Metal Toolchain Xcode component:
  `xcodebuild -downloadComponent MetalToolchain`.
- One-time model download (~1.6 GB for INT5) on first use.

## Build

```bash
./build.sh            # release build, installs to ~/Applications/SimpleWhispr.app
./build.sh --debug    # faster debug build
./build.sh --open     # install, then relaunch
```

## Test

There is no unit-test target. Validate the pipeline with the hidden CLI mode:

```bash
say -v Anna -o /tmp/test_de.aiff "Guten Morgen, das ist ein Test."
say -v Samantha -o /tmp/test_en.aiff "Good morning, this is a test."

BIN=~/Library/Developer/SimpleWhispr/build/debug/SimpleWhispr
"$BIN" --transcribe /tmp/test_de.aiff --language de --variant int5
"$BIN" --transcribe /tmp/test_en.aiff --language en
```

Verify the global hotkey without a keypress:

```bash
~/Applications/SimpleWhispr.app/Contents/MacOS/SimpleWhispr --hotkey-selftest
```

## Pull request checklist

- [ ] The build succeeds (`./build.sh`).
- [ ] The CLI self-tests still pass (German and English).
- [ ] No new telemetry, network calls, or API keys were added.
- [ ] Code, comments, and commit messages are in English; no emojis or em-dashes.
- [ ] New on-device engines are added behind the `Transcriber` protocol and
      registered in `TranscriberRegistry`, without touching the recording or UI
      layers.
- [ ] If you changed the UI or layout, you checked the menu bar panel and the
      Settings window in light and dark mode.

## Signing and credentials

Signing and notarization read credentials from `.env.signing`, which is
gitignored. Copy `.env.signing.example` to `.env.signing` and fill in your own
values. **Never commit real credentials.**

## Issues

Please search open issues before filing a new one, and use the bug report or
feature request template. Report security concerns as described in
`SECURITY.md`, not as a public issue.
