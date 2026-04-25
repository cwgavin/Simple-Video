# FFmpeg GUI (Swift / SwiftUI)

A native macOS app providing a UI for the most common `ffmpeg` operations.
Built with **SwiftUI**. No external dependencies beyond `ffmpeg`/`ffprobe`.

## Features

- **Convert** between formats / codecs
- **Extract audio** (MP3, AAC, WAV, FLAC…)
- **Remove audio** (mute a video)
- **Trim** by start/end timestamps
- **Resize** (set width/height; `-1` keeps aspect)
- **Compress** with H.264 + CRF + preset
- **GIF** export with FPS + width
- **Extract frames** as PNG
- **Merge** separate video + audio
- Live ffmpeg log
- Real-time progress bar
- Cancel running jobs

## Requirements

- macOS 14+
- Swift 5.9+ (ships with Xcode or Command Line Tools — `xcode-select --install`)
- `ffmpeg` and `ffprobe` (e.g. `brew install ffmpeg`)

## Build

```sh
./build.sh
```

This produces `FFmpeg GUI.app` next to `Package.swift`. Double-click it in
Finder, or run:

```sh
open "FFmpeg GUI.app"
```

You can move it into `/Applications` like any other Mac app.

## Develop

```sh
swift run                 # run from terminal for fast iteration
swift build -c release    # release build (no .app bundle)
```
