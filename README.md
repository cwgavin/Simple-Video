# Simple Video

A native macOS app providing a simple UI for common video & audio operations.
Built with **SwiftUI**. Powered by `ffmpeg` and `whisper` under the hood.

## Features

- **Convert** video between formats / codecs (mp4, mov, mkv, webm, avi, flv, m4v, ts)
- **Convert** audio between formats (mp3, aac, wav, flac, ogg, m4a, wma, aiff, opus)
- **Merge** separate video + audio tracks
- **Concatenate** multiple video or audio files
- **Transcribe** audio/video to text using OpenAI Whisper
- Live log output, real-time progress bar, cancel running jobs

## Requirements

- macOS 14+
- Swift 5.9+ (ships with Xcode or Command Line Tools — `xcode-select --install`)
- `ffmpeg` and `ffprobe` (e.g. `brew install ffmpeg`)
- `whisper` for transcription (optional — `pip install openai-whisper`)

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

## Develop

```sh
swift run                 # run from terminal for fast iteration
swift build -c release    # release build (no .app bundle)
```
