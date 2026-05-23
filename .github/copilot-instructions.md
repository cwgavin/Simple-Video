# Copilot instructions for Simple Video

## Build, test, and lint commands

- **Fast dev run:** `swift run`
- **Debug build:** `swift build`
- **Release build:** `swift build -c release`
- **App bundle build (preferred for real app behavior):** `./build.sh`
- **Build + launch app:** `./build-and-restart.sh`
- **Build installer DMG:** `./dist.sh`

- **Run all tests (when tests exist):** `swift test`
- **Run one test (when tests exist):** `swift test --filter <TestCase>/<testMethod>`

`Package.swift` currently defines no test target, so `swift test` will fail until a `Tests/` target is added.

Linting: there is no configured lint command/tool in this repository (no SwiftLint config, no lint script target).

## High-level architecture

- This is a single-target Swift Package app (`Package.swift`) with one executable target: `Sources/SimpleVideo`.
- App entry is `App/SimpleVideoApp.swift`:
  - `SimpleVideoApp` injects shared state objects (`CropVideoSession`, `CropAudioSession`) into `ContentView`.
  - `SimpleVideoAppDelegate` handles quit confirmation for unsaved crop changes and terminates running subprocesses on exit.
- Main navigation is in `Views/Main/ContentView.swift`:
  - Sidebar task selection is driven by `FFTask` in `Models/Models.swift`.
  - A single shared `FFmpegRunner` is provided via `@EnvironmentObject` to task views.
  - Crop and concat workflows also use dedicated session objects (`CropVideoSession`, `CropAudioSession`, `ConcatSession`) to preserve page-local state.
- Command execution lives in `Core/FFmpegSupport.swift`:
  - `FFmpegRunner` launches subprocesses, streams logs, parses ffmpeg progress, and updates shared UI status/progress.
  - `BinaryCache` resolves `ffmpeg`, `ffprobe`, and `whisper` by checking bundled resources first, then common system paths, then `command -v`.
  - Whisper model catalog/download logic is centralized here (`WhisperModelCatalog`, `ModelDownloadDelegate`).
- Feature pages live under `Views/Tasks/`:
  - Most operations call `runner.run(...)` with ffmpeg args.
  - Transcription (`TranscribeView`) runs a two-step pipeline: ffmpeg audio extraction then whisper CLI transcription, while still writing to the shared runner log/status.
  - Crop video/audio flows are more stateful and AVFoundation-heavy (timeline, preview, proxy generation, temporary artifact cleanup).

## Key conventions in this codebase

- **Localization is explicit in code, not string tables.** Use `AppLanguage` + `L.text(...)` (and related helpers) with English + Simplified Chinese text paired inline.
- **Shared job state comes from `FFmpegRunner`.** New processing features should surface status/progress/log through this runner so they integrate with the global bottom status/log panel.
- **Never overwrite source inputs.** Output files are generated via timestamped helpers (`makeOutputPath`, `makeOutputDirectory`), and `FFmpegRunner` has a safety guard that refuses commands where output equals an input path.
- **Prefer reusable form primitives from `Views/Common/CommonViews.swift`.** Existing task UIs consistently use `FilePickerRow`, `OutputHintRow`, `RunButton`, and `formLabelWidth`.
- **Persist user preferences via `@AppStorage`.** Language and UI preferences (e.g., log panel visibility, icon-only buttons) use keys defined in `AppStorageKey`.
- **Crop workflows track unsaved state explicitly.** `CropVideoSession` and `CropAudioSession` maintain baseline snapshots (`markCurrentStateAsBaseline`) to drive quit warnings and change detection.
- **Temporary crop artifacts are tracked globally.** Proxy/preview files are registered via `CropPreviewArtifacts` and cleaned up on app termination.
- **Concat strategy depends on input homogeneity.** Same-format concat uses concat demuxer + stream copy; mixed formats switch to concat filter + re-encode.
- **Bundled binary preference is intentional.** Runtime tool resolution prioritizes app/project `Resources/bin` so shipped apps remain self-contained while local development can still use system installs.
