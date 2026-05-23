# Simple Video

[简体中文](README.zh-CN.md)

A native macOS app providing a simple UI for common video & audio operations.
Built with **SwiftUI**. Powered by `ffmpeg` and `whisper.cpp` under the hood.

## Features

- **Crop** a video visually with draggable crop handles, aspect-ratio presets, auto black-bar detection, a dedicated full-screen crop editor, and previewable start/end trim ranges that can be exported or removed from the final output
- **Crop** audio with previewable start/end trim selection, playback-rate export, and the option to export or remove the selected range
- **Convert** video or audio between formats/codecs from one page using a Type selector (video: mp4, mov, mkv, webm, avi, flv, m4v, ts; audio: mp3, aac, wav, flac, ogg, m4a, wma, aiff, opus)
- **Merge** separate video + audio tracks
- **Concatenate** multiple video or audio files
- **Split** one video into multiple clips from a list of timestamps
- **Transcribe** audio/video to text using Whisper
- Settings for English/Simplified Chinese, log panel visibility, icon-only buttons, and third-party license links
- Collapsible live log output, real-time progress bar, cancel running jobs

## Requirements

For the packaged app:

- macOS 14+
- Bundled `ffmpeg`, `ffprobe`, and `whisper-cli` executables for a self-contained build
- Whisper models are downloaded by users in the app

For local development or packaging:

- Swift 5.9+ (ships with Xcode or Command Line Tools — `xcode-select --install`)
- `ffmpeg` / `ffprobe` available in `Resources/bin/`, via the `SIMPLE_VIDEO_FFMPEG_BIN` / `SIMPLE_VIDEO_FFPROBE_BIN` environment variables, or in a standard local install path
- `whisper-cli` from `whisper.cpp` available in `Resources/bin/`, via `SIMPLE_VIDEO_WHISPER_BIN`, or in a standard local install path

## Build

```sh
./build.sh
```

This produces `Simple Video.app` next to `Package.swift`. Double-click it in
Finder, or run:

```sh
open "Simple Video.app"
```

You can move it into `/Applications` like any other Mac app.

## Installer DMG

To create a simple drag-and-drop installer:

```sh
./dist.sh
```

This builds the app and creates:

```text
dist/Simple Video-1.0.dmg
```

Users open the DMG, then drag `Simple Video.app` onto
`Applications - drop here`. The DMG also includes an `INSTALL - read me.txt`
file with the same instructions for less technical users.

For a **self-contained distributable app**, bundle runtime executables before
or during `./build.sh`:

- Put executables in `Resources/bin/`:
  - `ffmpeg`
  - `ffprobe`
  - `whisper-cli`

`build.sh` copies those files into `Simple Video.app/Contents/Resources/`,
bundles their non-system dynamic libraries into `Contents/Frameworks`, and
ad-hoc signs the result. If `Resources/bin/` does not already contain the
tools, it also tries the environment variables above and standard local install
locations.

Example with Homebrew / a local whisper.cpp checkout:

```sh
mkdir -p Resources/bin
cp /opt/homebrew/bin/ffmpeg Resources/bin/
cp /opt/homebrew/bin/ffprobe Resources/bin/
cp /path/to/whisper.cpp/build/bin/whisper-cli Resources/bin/
./build.sh
```

At runtime the app prefers bundled tools inside the `.app`, then falls back to
system-installed binaries. That means `swift run` still works during
development, while shipped builds can run on machines that do not have ffmpeg
or whisper.cpp installed globally.

Whisper models are **not bundled** by default. When a user opens Transcribe,
they choose a model and click **Download**. Models are saved per user at:

```text
~/Library/Application Support/Simple Video/whisper-models/
```

This keeps the app download small, avoids changing the signed `.app` bundle,
and lets users choose the size/accuracy tradeoff they want.

## Develop

```sh
swift run                 # run from terminal for fast iteration
swift build -c release    # release build (no .app bundle)
```
