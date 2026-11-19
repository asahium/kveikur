# Kveikur - a folder-first music player for macOS

[![CI](https://github.com/asahium/kveikur/actions/workflows/ci.yml/badge.svg)](https://github.com/asahium/kveikur/actions/workflows/ci.yml) · **[asahium.github.io/kveikur](https://asahium.github.io/kveikur/)**

Kveikur is a native macOS player for music kept in folders. You browse it like [yazi](https://github.com/sxyazi/yazi), with parent columns, the current folder, a preview and vim keys. An inspector on the right shows the track, its lyrics, the queue, a live analysis and the signal path to the DAC. It uses Nord colours, shows no artwork in the browser and imports nothing: the folders are the library.

What it does:

- **Playback.** Gapless, bit-perfect when it can be. It matches the device sample rate, can take exclusive mode, and supports ReplayGain and a 10-band EQ with AutoEQ import.
- **Formats.** FLAC, ALAC, AAC, MP3, WAV, AIFF, Ogg Vorbis and Opus. Single-image rips with a CUE sheet play as separate tracks.
- **Lyrics.** Uses a `.lyricsfile.yaml` or `.lrc` file or embedded tags, then LRCLIB, NetEase or Genius, preferring word-synced over line-synced. Words light up as they are sung, and there is a full-screen karaoke view.
- **Tags and files.** Edit tags, rename and move to Trash from the right-click menu only, so no keystroke can delete anything.
- **Duplicates.** Finds the same album stored twice and marks the copy to keep.
- **Missing albums.** Lists each artist's studio albums from MusicBrainz that aren't in your folders.
- **History.** Plays are stored locally. You get statistics, Most/Recently Played playlists, and scrobbling to Last.fm and ListenBrainz.
- **Restores state.** On launch the folder, cursor, queue and position come back.

Hold `⌘` for a moment to see every shortcut.

## Install

```sh
brew install --cask asahium/tap/kveikur
```

Or download the `.dmg` from [releases](https://github.com/asahium/kveikur/releases) and drag Kveikur into `/Applications`. It needs an Apple Silicon Mac with macOS 15 or later. The build is not notarized: the cask clears the quarantine flag itself, and a downloaded `.dmg` needs right-click → Open the first time.

An iPhone beta lives in `iOS/`: `make ios-device` builds and installs it on a paired iPhone. A free Apple ID signs it for 7 days; `make ios-autosign` re-signs it over Wi‑Fi before that runs out.

## Build

```sh
make app    # build/Kveikur.app
make test
make dmg    # build/Kveikur-<version>.dmg
```

It needs Xcode 16 or newer and has no dependencies. Pushing a `v*` tag publishes a release.

## Tools

[`Tools/`](Tools) holds command-line helpers that are not part of the app, each its own Swift package. [`kveikur-lyrics`](Tools/kveikur-lyrics) finds lyrics for the whole library and word-syncs them on-device.

## License

[MIT](LICENSE)
