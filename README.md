# Kveikur - a folder-first music player for macOS

[![CI](https://github.com/asahium/kveikur/actions/workflows/ci.yml/badge.svg)](https://github.com/asahium/kveikur/actions/workflows/ci.yml)

Kveikur is a native macOS player for music kept in folders. You browse it like [yazi](https://github.com/sxyazi/yazi), with parent columns, the current folder, a preview and vim keys. An inspector on the right shows the track, its lyrics, the queue, a live analysis and the signal path to the DAC. It uses Nord colours, shows no artwork in the browser and imports nothing: the folders are the library.

What it does:

- **Playback.** Gapless, bit-perfect when it can be. It matches the device sample rate, can take exclusive mode, and supports ReplayGain and a 10-band EQ with AutoEQ import.
- **Formats.** FLAC, ALAC, AAC, MP3, WAV, AIFF, Ogg Vorbis and Opus. Single-image rips with a CUE sheet play as separate tracks.
- **Lyrics.** Uses a `.lrc` file or embedded tags, then LRCLIB or Genius. Synced lines scroll, and there is a full-screen karaoke view.
- **Tags and files.** Edit tags, rename and move to Trash from the right-click menu only, so no keystroke can delete anything.
- **Duplicates.** Finds the same album stored twice and marks the copy to keep.
- **History.** Plays are stored locally. You get statistics, Most/Recently Played playlists, and scrobbling to Last.fm and ListenBrainz.
- **Restores state.** On launch the folder, cursor, queue and position come back.

Hold `⌘` for a moment to see every shortcut.

## Install

Download the `.dmg` from [releases](https://github.com/asahium/kveikur/releases) and drag Kveikur into `/Applications`. It needs an Apple Silicon Mac with macOS 15 or later. The build is not notarized, so open it the first time with right-click → Open.

An iPhone beta lives in `iOS/`: run `make ios` and run it from Xcode.

## Build

```sh
make app    # build/Kveikur.app
make test
make dmg    # build/Kveikur-<version>.dmg
```

It needs Xcode 16 or newer and has no dependencies. Pushing a `v*` tag publishes a release.
