# AGENTS.md

Guidance for AI agents and contributors working in this repository.
Human-friendly overview lives in `README.md`; this file is the operational
cheat sheet for making and verifying changes.

## What this is

SimpleWhispr is a tiny, local-first dictation app for macOS (Apple Silicon,
macOS 15+). Hold the **right Command** key, speak, release; the transcript is
typed into the active text field. Transcription runs on-device with the Cohere
Transcribe 2B model via MLX. It is a menu bar app (no dock icon).

## Language and conventions

- Source, comments, variables, and commit messages are in English.
- No emojis, no em-dashes in code, comments, or docs.
- The Swift target uses Swift 5 language mode (see `Package.swift`) on purpose,
  to avoid heavy strict-concurrency churn in AppKit / Carbon / AVAudio code.
  Do not flip it to Swift 6 mode casually.
- Do not add telemetry, cloud calls, or API keys. The design contract is
  local-first: nothing about audio or transcripts leaves the machine.

## Build

```bash
./build.sh            # release build, installs to ~/Applications/SimpleWhispr.app
./build.sh --debug    # faster debug build, installs
./build.sh --open     # install, then quit the running copy and open the new one
```

Notes:

- Build products live in `~/Library/Developer/SimpleWhispr/build`, outside the
  repo (scratch path is fixed in `build.sh`).
- The first build fetches MLX and the Swift toolchain dependencies and can take
  several minutes.
- The Metal Toolchain Xcode component must be installed:
  `xcodebuild -downloadComponent MetalToolchain`.
- If a build then fails on a stale `metal` compiler path (a missing
  `.../MetalToolchain-*/Metal.xctoolchain/usr/bin/metal`), the SwiftPM / Xcode
  cache points at an old cryptex mount. Clear it without refetching MLX, then
  rebuild:

  ```bash
  SCRATCH=~/Library/Developer/SimpleWhispr/build
  rm -rf "$SCRATCH/out/Intermediates.noindex/XCBuildData" \
         "$SCRATCH/out/Intermediates.noindex/mlx-swift.build" \
         "$SCRATCH/.buildSystem_release" "$SCRATCH/.buildSystem_debug"
  ```
- `build.sh` bundles `mlx.metallib` into the `.app` so MLX can load its GPU
  kernels at runtime. If a build warns that the metallib was not found, the
  installed app may fail to load the model.
- `build.sh` signs the app with a Developer ID certificate (from
  `.env.signing`) when one is available, otherwise an Apple Development
  identity, otherwise ad hoc. A real signature uses the hardened runtime plus
  `SimpleWhispr.entitlements`. See the signing section below. Signature and
  install path are tied to TCC permissions, so keep both stable.

## Test

No unit-test target exists. The pipeline is validated with the hidden CLI mode:

```bash
# German and English test clips from the system voices
say -v Anna -o /tmp/test_de.aiff "Guten Morgen, das ist ein Test."
say -v Samantha -o /tmp/test_en.aiff "Good morning, this is a test."

BIN=~/Library/Developer/SimpleWhispr/build/debug/SimpleWhispr
"$BIN" --transcribe /tmp/test_de.aiff --language de --variant int5
"$BIN" --transcribe /tmp/test_en.aiff --language en
```

Verify the global hotkey without a real keypress:

```bash
~/Applications/SimpleWhispr.app/Contents/MacOS/SimpleWhispr --hotkey-selftest
```

It prints `PASSED` / `FAILED` with the Accessibility state. A `FAILED` with
`trusted=false` means Accessibility permission is not granted yet.

Logs: `~/Library/Logs/SimpleWhispr.log`.

After changing UI or layout, confirm visually: build, install, relaunch
(`./build.sh --open`), and check the menu bar panel and the Settings window in
both light and dark mode.

## Signing and notarization

`build.sh` resolves a signing identity in priority order and signs the app
bundle in `~/Applications/SimpleWhispr.app`:

1. `DEVELOPER_ID_APPLICATION` from `.env.signing` (Developer ID, the default).
2. `SIGN_IDENTITY` environment override.
3. The auto-detected `Apple Development:` identity.
4. Ad hoc (`-`) when no certificate is present.

A real signature (anything but ad hoc) is signed with `--options runtime`
(hardened runtime) plus `SimpleWhispr.entitlements`:

- `com.apple.security.app-sandbox = false` - the app types into the frontmost
  app via a CGEventTap and pastes with Cmd-V, which needs Accessibility and is
  incompatible with the sandbox.
- `com.apple.security.device.audio-input = true` - AVAudioEngine microphone
  access under the hardened runtime.

There is intentionally no `network.client` or `keychain-access-groups`: the app
is local-first and keeps that contract.

Credentials live in `.env.signing` (gitignored via `.env*`), following the
pattern from `freelancetimewise/macos-app`:

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: Name (TEAMID)"
export APPLE_ID="apple-id@example.com"
export APPLE_TEAM_ID="TEAMID"
export APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
```

Notarization is optional and only runs when `NOTARIZE=1`:

```bash
NOTARIZE=1 ./build.sh
```

It requires a Developer ID certificate plus `APPLE_ID`, `APPLE_TEAM_ID`, and
`APPLE_APP_PASSWORD` from `.env.signing`, then zips the app, submits it with
`xcrun notarytool ... --wait`, and staples the ticket with `xcrun stapler`.

TCC caveat: Microphone and Accessibility are tied to the signature. Switching
the identity (for example Apple Development to Developer ID) or the install path
changes the signature and resets TCC, so you must re-grant Microphone and
Accessibility once after the first signed build.

A stale TCC entry (still shown as on in System Settings but tied to a previous
signature) makes `CGPreflightListenEventAccess()` return false, so the hotkey
silently does not fire. The app self-heals this with a "Reset permissions..."
action (menu bar and Settings > Permissions): it runs `tccutil reset` for its
own Input Monitoring, Accessibility, and Microphone entries, then re-requests
them. One reset is enough as long as the signing identity and install path stay
the same; a new identity or path re-breaks TCC and needs one more reset.

Verify a signed build locally:

```bash
codesign --verify --deep --strict ~/Applications/SimpleWhispr.app
codesign -dv --verbose=4 ~/Applications/SimpleWhispr.app  # shows the runtime
```

## Architecture

Pipeline:

```
hold right Cmd  ->  AVAudioEngine records the mic (mono Float32)
release Cmd     ->  Cohere Transcribe 2B (MLX) transcribes locally
                  ->  text goes on the pasteboard and is pasted with Cmd-V
                      (the previous clipboard content is restored afterwards)
```

The source tree (`Sources/SimpleWhispr/`):

- `App/`        menu bar scene, app delegate, hotkey wiring, `AppState`.
- `Hotkey/`     `CGEventTap` on flags-changed; hold right Cmd. Needs Accessibility.
- `Recording/`  `AVAudioEngine` mic capture plus the `WAVWriter`.
- `Transcription/`  `Transcriber` protocol, `CohereTranscriber` (MLX), an Apple
  on-device fallback (currently a placeholder), and the registry.
- `Input/`      pasteboard plus synthetic Cmd-V injection.
- `UI/`         menu bar panel and Settings window.
- `CLI/`        hidden `--transcribe <file>` test mode.
- `Permissions/`  microphone, accessibility, and login-item handling.
- `Util/`       settings (`UserDefaults`), logger, enums.

Engine pluggability: transcription is behind the `Transcriber` protocol, so a new
on-device engine can be added without touching the recording or UI layers. Add a
new engine and register it in `TranscriberRegistry`.

## Current status and known limitations

- Default and recommended engine: Cohere Transcribe 2B (MLX), verified
  end-to-end for German and English.
- Apple on-device engine: placeholder. On macOS 26+ Apple replaced the classic
  `SFSpeechRecognizer` API with a streaming `SpeechAnalyzer`, so it is not wired
  up yet. Keep Cohere as the default.
- Both the hotkey and pasting require Accessibility permission. Without it, the
  hotkey does not fire and the transcript is only copied to the clipboard.
- Launch-at-login persistence is not guaranteed with an ad-hoc signature,
  because each rebuild changes the signature and can reset TCC permissions. For a
  stable experience sign with a stable identity (a Developer ID from
  `.env.signing`, or an Apple Development identity) and install to the same path
  every time.

## Do and do not

- Do: build and run the CLI self-tests after changing the transcription,
  recording, or hotkey paths.
- Do: keep the app menu-bar-only and local-first.
- Do not: delete or move files, folders, or the install path without explicit
  user permission.
- Do not: add cloud dependencies, telemetry, or network calls for the core
  transcription path.
- When proposing code changes, present a short plan first and wait for
  confirmation before editing.
