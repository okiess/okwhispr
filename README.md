# SimpleWhispr

A tiny, local-first dictation app for macOS. One job: **speak, and the text
appears at your cursor in any app.**

- **Global hold-to-talk hotkey** — hold the **right Command** key (⌘), speak,
  release. The transcript is typed into whatever field you are using.
- **Local AI model** — [Cohere Transcribe 2B](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026)
  runs on Apple Silicon through [MLX](https://github.com/ml-explore/mlx-swift).
  After the first download, everything runs on your machine. No cloud, no API
  keys, no telemetry.
- **14 languages** including German, English, French, Spanish, Italian,
  Portuguese, Dutch, Polish, Greek, Vietnamese, Chinese, Arabic, Japanese, Korean.
- **Menu bar app** — lives in the menu bar (no dock icon), lightweight.

This is intentionally minimal. It is inspired by
[OpenWhispr](https://github.com/OpenWhispr/openwhispr) but does only one thing:
dictation.

---

## Requirements

- macOS 15+ (Sequoia), Apple Silicon.
- Xcode 15+ (for the `swift` toolchain) to build.
- One-time model download (~1.6 GB for the INT5 variant) on first use. The
  model is cached in `~/Library/Caches/qwen3-speech/models/`.

## Build and install

```bash
./build.sh            # release build, installs to ~/Applications/SimpleWhispr.app
./build.sh --debug    # faster debug build
./build.sh --open     # install, then relaunch
```

The first build fetches MLX and the Swift toolchain dependencies and can take a
few minutes. The **Metal Toolchain** Xcode component must be installed:

```bash
xcodebuild -downloadComponent MetalToolchain
```

If a build fails with a stale `metal` compiler path after a toolchain update,
clear the stale cache and retry (MLX is not re-downloaded):

```bash
SCRATCH=~/Library/Developer/SimpleWhispr/build
rm -rf "$SCRATCH/out/Intermediates.noindex/XCBuildData" \
       "$SCRATCH/out/Intermediates.noindex/mlx-swift.build" \
       "$SCRATCH/.buildSystem_release" "$SCRATCH/.buildSystem_debug"
```

## Signing

`./build.sh` signs the app with a Developer ID certificate from `.env.signing`
(gitignored) when one is present, otherwise an Apple Development identity, and
only falls back to an ad-hoc signature. A real signature uses the hardened
runtime plus `SimpleWhispr.entitlements`. To notarize for distribution:

```bash
NOTARIZE=1 ./build.sh
```

Credentials (`DEVELOPER_ID_APPLICATION`, `APPLE_ID`, `APPLE_TEAM_ID`,
`APPLE_APP_PASSWORD`) go in `.env.signing`. Because Microphone and Accessibility
are tied to the signature, re-grant both once after the first build with a new
identity. See `AGENTS.md` for the full signing and notarization notes.

## First run

1. Open SimpleWhispr from Launchpad (or `open ~/Applications/SimpleWhispr.app`).
2. Grant the **Microphone** permission when macOS asks.
3. Grant **Accessibility** permission (System Settings → Privacy & Security →
   Accessibility → enable SimpleWhispr). This is required for **two** things: the
   global right-⌘ hotkey (macOS delivers the modifier press through an event
   tap, which needs Accessibility) and pasting the transcript with ⌘V. The menu
   bar and Settings window guide you through it.
4. In Settings you can choose the model precision (INT5 recommended), language,
   and whether to paste automatically.

Then, in any text field: **hold the right ⌘ key, speak, release.** The text is
transcribed locally and pasted where your cursor is.

## How it works

```
hold right ⌘ ──► AVAudioEngine records the mic (mono Float32)
release ⌘   ──► Cohere Transcribe 2B (MLX) transcribes locally
              ──► text is put on the pasteboard and pasted with ⌘V
                  (the previous clipboard content is restored afterwards)
```

The transcription engine is pluggable behind a small `Transcriber` protocol, so
other on-device models can be added without touching the recording or UI layers.

## Testing the pipeline without a microphone

A hidden CLI mode transcribes an audio file end-to-end. It is used to validate
the build:

```bash
# generate German and English test clips with the system voices
say -v Anna -o /tmp/test_de.aiff "Guten Morgen, das ist ein Test."
say -v Samantha -o /tmp/test_en.aiff "Good morning, this is a test."

BIN=~/Library/Developer/SimpleWhispr/build/debug/SimpleWhispr
"$BIN" --transcribe /tmp/test_de.aiff --language de --variant int5
# → Guten Morgen, das ist ein Test.
"$BIN" --transcribe /tmp/test_en.aiff --language en
```

Logs are written to `~/Library/Logs/SimpleWhispr.log`.

## Permissions

| Permission      | Why                                                    |
|-----------------|--------------------------------------------------------|
| Microphone      | to record your speech                                   |
| Accessibility   | to type the transcript into the active app via ⌘V       |

Both are standard macOS privacy prompts. Nothing about your audio or transcripts
ever leaves your machine.

## Project layout

```
Sources/SimpleWhispr/
  App/            menu bar scene, app delegate, hotkey wiring, AppState
  Hotkey/         CGEventTap on flags-changed (hold right ⌘, needs Accessibility)
  Recording/      AVAudioEngine mic capture + WAV writer
  Transcription/  Transcriber protocol, CohereTranscriber (MLX), Apple fallback, registry
  Input/          pasteboard + synthetic ⌘V
  UI/             menu bar panel + Settings window
  CLI/            hidden --transcribe <file> test mode
  Permissions/    microphone / accessibility / login item
  Util/           settings (UserDefaults), logger, enums
build.sh          swift build → .app bundle → codesign → ~/Applications
```

## Status / limitations

- **The default and recommended engine is Cohere Transcribe 2B (MLX)** and it
  is verified end-to-end for German and English (release build, installed
  `.app`). The MLX `mlx.metallib` is bundled into the `.app` by `build.sh`, so
  the installed app loads its GPU kernels without any extra setup.
- The **Apple on-device** engine is a placeholder for now: on macOS 26+ Apple
  replaced the classic `SFSpeechRecognizer` API with a streaming
  `SpeechAnalyzer`, so it is not wired up yet. Select Cohere (the default).
- Both the **hotkey and pasting** require **Accessibility** permission; without it
  the hotkey does not fire and the transcript is only copied to the clipboard
  (and you can paste it yourself). Grant it in System Settings → Privacy &
  Security → Accessibility.
- **Verify the hotkey without a keypress:** run
  `~/Applications/SimpleWhispr.app/Contents/MacOS/SimpleWhispr --hotkey-selftest`.
  It registers the right-⌘ tap, posts a synthetic down/up, and prints
  `PASSED`/`FAILED` with the Accessibility state. A `FAILED` with `trusted=false`
  means Accessibility is not granted yet.
- Launch-at-login persistence is not guaranteed with an **ad-hoc signature**
  (each rebuild changes the signature, which can reset TCC permissions). For a
  stable experience sign with a stable identity (a Developer ID from
  `.env.signing`, or an Apple Development identity via Xcode Sign In) and always
  install to the same path.
- **Hold-a-modifier consideration:** right ⌘ is also a normal system modifier.
  Holding it *alone* dictates; if your muscle memory uses right ⌘ as part of
  other key combinations you may notice brief interference. This is the
  tradeoff of a single-key dictation shortcut and is configurable later.
- No login-item persistence across app updates is guaranteed with an ad-hoc
  signature; grant a stable signature (Xcode → Sign In) for that.

## Contributing

Contributions are welcome. See `CONTRIBUTING.md` for how to build, test, and open
a pull request, and `SECURITY.md` for reporting security issues.

- `CONTRIBUTING.md` - how to contribute (build, test, PR checklist).
- `CODE_OF_CONDUCT.md` - the community code of conduct.
- `SECURITY.md` - how to report security issues privately.
- `AGENTS.md` - the build, test, and architecture reference.

## License

The source code of SimpleWhispr is released under the **MIT License**
(see `LICENSE`).

Two things sit outside that license and are distributed under their own terms:

- **The on-device model.** SimpleWhispr does not bundle or redistribute the
  Cohere Transcribe 2B model. It is downloaded at first use (~1.6 GB for INT5)
  and is governed by its own license, available on the model's page on
  Hugging Face. Review that license before relying on the model for production use.
- **Runtime dependencies.** MLX (via `speech-swift`) and its Swift bindings are
  licensed under the Apache 2.0 license. See `Package.resolved` for the exact
  revisions.
