# Kveikur

A small native macOS music player for people who keep their music in folders. Browsing works like
[yazi](https://github.com/sxyazi/yazi): parent columns on the left, the current folder in the middle, a preview of the
folder under the cursor, and vim keys everywhere. A Nyquist-style inspector on the right shows what is playing, its
lyrics, the queue, a loudness and spectrum analysis, and the full signal path to the DAC.

Nord colours, no artwork in the browser, no library management beyond reading your folders.

## Features

- **Folder-first browser.** 1–3 ancestor columns depending on depth, a preview column for folders, fuzzy jump to any
  folder (`z`), fuzzy track search (`s`), filter (`f`), find (`/`), marks and visual selection, M3U8 playlists.
- **Playback.** AVAudioEngine with sample-accurate gapless playback, automatic device sample-rate matching, exclusive
  (hog) mode, output device selection with fallback, media keys and Now Playing.
- **Formats.** Whatever Core Audio opens: FLAC, ALAC, AAC, MP3, WAV/W64, AIFF, CAF, Ogg Vorbis/Opus/FLAC.
- **ReplayGain.** Track or album mode from `REPLAYGAIN_*` / Opus `R128_*` tags, with a preamp and peak-based clipping
  protection. Untagged files get an EBU R128 measurement in the background (cached), so the next track is ready by the
  time it starts. The gain is fixed per track and applied to the samples, so gapless transitions stay intact.
- **Equalizer.** 10-band graphic EQ with presets and live response curve, plus AutoEQ `ParametricEQ.txt` import for
  headphone correction (up to 16 parametric filters).
- **Lyrics.** Sidecar `.lrc`, embedded tags, then LRCLIB (synced) and optionally Genius. Fetched automatically and
  prefetched for the next track. Full-screen karaoke view (`⌘L`) where the current line fills as it is sung.
- **Scrobbling.** Last.fm and ListenBrainz. A play counts after half the track or 4 minutes of actual listening;
  offline plays are queued on disk and sent later.
- **Inspector.** Info and tags, lyrics, queue, analysis (live spectrum, meters, goniometer, waveform, loudness,
  spectrogram), and output (device capabilities, bit-perfect status, DSP in the path).
- **CUE sheets.** Single-image rips (`.cue` + one FLAC/APE/WAV) show up as separate tracks and play sample-accurate
  segments. Sheet encodings (UTF-8/16, CP1251, Shift-JIS, CP1252) are detected; per-file sheets are ignored.
- **File actions, mouse only.** Right-click a track, folder or selection for Edit Tags…, Rename… and Move to Trash….
  None of them has a key binding, so nothing gets renamed or deleted by a stray keystroke. Tags are written in place
  for FLAC, MP3 (ID3v2.3/2.4) and MP4/M4A; renames carry `.lrc`/`.cue` sidecars along and update queue and playlists.
- **Duplicates.** `gD` (File → Find Duplicates…) finds albums and tracks stored more than once and marks the copy to
  keep: lossless first, then bit depth and sample rate, then the most complete edition. Trash the rest from the
  right-click menu.
- **History and statistics.** Every counted play is stored locally (no account needed). `gs` opens listening
  statistics: plays and hours per day, top artists, albums and tracks for 7 days, 30 days, a year or all time.
  Playlists also lists smart playlists: Most Played, Recently Played, Recently Added (by file date), Never Played.
- **Restores state.** Folder, cursor, queue and position come back on launch, paused.
- **Updates.** Kveikur → Check for Updates… (and a daily check) looks at the latest GitHub release.

## Keys

Hold `⌘` for a moment to see every shortcut. The basics:

| Keys | Action |
| --- | --- |
| `h` `j` `k` `l` / arrows | Navigate |
| `Enter` / `l` | Open folder or play track |
| `p` / `P` | Play selection / whole folder |
| `a` / `A` | Add to queue / play next |
| `c`, `⌃Space` | Play / pause |
| `[` `]` | Previous / next track |
| `,` `.` | Seek 5 s |
| `z`, `s`, `:` | Jump to folder, search tracks, command palette |
| `Tab`, `1`–`5` | Inspector tabs |
| `⌘L` | Full-screen lyrics |
| `⌘E`, `E`, `gR` | Equalizer window, EQ on/off, cycle ReplayGain |
| `⌘0` | Toggle inspector |
| `gD`, `gs` | Duplicates, listening statistics |

## Building

Requires macOS 15 and Xcode 16 or newer (Swift 6 toolchain). No third-party dependencies.

```sh
make app      # build/Kveikur.app (release, ad-hoc signed)
make run      # build and open
make test     # unit tests
make dmg      # build/Kveikur-<version>.dmg
make icon     # regenerate Resources/AppIcon.icns
```

To install, copy `build/Kveikur.app` to `/Applications`.

Network tests (LRCLIB) are skipped unless `KVEIKUR_NETWORK=1` is set.

### CI and releases

`.github/workflows/ci.yml` runs the tests and builds the macOS bundle and the iOS app (simulator, unsigned) on every
push to `main` that touches code, and on pull requests. Pushing a tag publishes a release with a DMG:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

The version comes from the tag. The app is ad-hoc signed, not notarized: on first launch right-click → Open, or run
`xattr -dr com.apple.quarantine /Applications/Kveikur.app`. While the repository is private, the update check needs a
GitHub token with read access to its contents (Settings → Updates).

### iOS (beta)

The iOS app lives in `iOS/` and uses the same `KveikurCore`. The Xcode project is generated with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and is not committed.

```sh
make ios-sim  # build, install and launch in the simulator (IOS_SIM="iPhone 17 Pro")
make ios      # generate and open iOS/KveikurMobile.xcodeproj
```

On a real iPhone: `make ios`, select the `KveikurMobile` target → Signing & Capabilities → your personal team
(a free Apple ID works), connect the phone and Run. Enable Developer Mode on the phone when asked. With a free
account the build expires after 7 days — run it again from Xcode. TestFlight needs a paid developer account.

Music comes from the Files app: copy albums to *On My iPhone → Kveikur*, or tap **+** and pick any folder
(iCloud Drive, external drive, SMB share). Picked folders are remembered through security-scoped bookmarks;
iCloud files that are not downloaded yet are fetched on play.

The iOS app has the folder browser with search, queue, background playback with lock-screen controls,
synced lyrics, ReplayGain, EQ presets, AirPlay and scrobbling. Simulator debug launch:
`SIMCTL_CHILD_KVEIKUR_OPEN="Artist/Album" SIMCTL_CHILD_KVEIKUR_PLAY=1 SIMCTL_CHILD_KVEIKUR_SHEET=lyrics`
(`playing`, `lyrics`, `queue`, `info`, `settings`).

## Layout

```
Sources/KveikurCore   audio engine, decoders, DSP, library (SQLite), metadata, lyrics, playlists, scrobbling
Sources/Kveikur       AppKit/SwiftUI app: browser, inspector, transport, settings, overlays
iOS/                  SwiftUI iPhone app (XcodeGen project.yml)
Tests/                XCTest suite for the core
scripts/              bundle.sh (app bundle + signing), dmg.sh, make-icon.swift
.github/workflows/    CI (tests, macOS + iOS builds) and tag releases
```

`KveikurCore` has no UI. The macOS-only parts are output device control (Core Audio HAL), FSEvents folder watching and
`NSImage` artwork; on iOS they are replaced by `AVAudioSession` routing, a no-op watcher and `UIImage`.

## Data

| What | Where |
| --- | --- |
| Settings, last state | `UserDefaults` domain `dev.kveikur.player` |
| Library index, listening history | `~/Library/Application Support/Kveikur/library.sqlite` |
| Lyrics cache, ReplayGain measurements, scrobble queue | `~/Library/Application Support/Kveikur/` |
| Artwork cache | `~/Library/Caches/Kveikur/` |
| Playlists | `~/Music/Kveikur Playlists/` (configurable) |

## Debugging

`KVEIKUR_SNAPSHOT=/tmp/shot.png` writes a PNG of the main window two seconds after launch.
`KVEIKUR_SNAPSHOT_ACTIONS=parent,karaoke` runs commands first (raw `Command` values),
`KVEIKUR_SNAPSHOT_WINDOW=Equalizer` captures another window by title, `KVEIKUR_SNAPSHOT_SHORTCUTS=1` shows the
shortcut overlay, and `KVEIKUR_SNAPSHOT_FILE=tags|rename|trash` opens a context-menu action on the cursor and captures
its sheet (nothing is changed unless you confirm).

## Roadmap

- iOS: full-screen karaoke, AutoEQ import, CarPlay, Last.fm connect flow polish.
