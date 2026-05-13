# Simple Video

A native macOS app providing a simple UI for common video & audio operations.
Built with **SwiftUI**. Powered by `ffmpeg` and `whisper.cpp` under the hood.

## Features

- **Convert** video between formats / codecs (mp4, mov, mkv, webm, avi, flv, m4v, ts)
- **Convert** audio between formats (mp3, aac, wav, flac, ogg, m4a, wma, aiff, opus)
- **Merge** separate video + audio tracks
- **Concatenate** multiple video or audio files
- **Split** one video into multiple clips from a list of timestamps
- **Remove** a section between two timestamps and keep the rest as one video
- **Transcribe** audio/video to text using Whisper
- Live log output, real-time progress bar, cancel running jobs

## Requirements

- macOS 14+
- Swift 5.9+ (ships with Xcode or Command Line Tools — `xcode-select --install`)
- `ffmpeg` / `ffprobe` for local development if you do not bundle them
- `whisper.cpp` CLI for transcription; Whisper models are downloaded by users in the app

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

`build.sh` copies those files into `Simple Video.app/Contents/Resources/`.
If `Resources/bin/` does not already contain them, it also tries standard local
install locations.

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
