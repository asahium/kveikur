# kveikur-lyrics

Walks the Kveikur library, downloads missing lyrics (LRCLIB, NetEase, Genius when a token is set in the app) and gives word timing to lyrics that only have line timing or none. Results go to Kveikur's lyrics cache, so the app shows them as word-synced without any setup, and to `<track>.lyricsfile.yaml` next to each track ([Lyricsfile](https://lrclib.net), the format LRCGET uses), so they survive moving or renaming folders. Files it didn't write itself (marked by a `# kveikur-lyrics` first line) are never overwritten; `--no-sidecar` turns this off.

Needs [uv](https://docs.astral.sh/uv/) and ffmpeg (`brew install uv ffmpeg`).

```sh
swift build -c release
.build/release/kveikur-lyrics --dry-run          # what would be done
.build/release/kveikur-lyrics                    # the whole library, except folders named OST
.build/release/kveikur-lyrics ~/Music/Bleachers  # one folder or file
```

## How the timing is made

The lyrics are known, so nothing is transcribed: [Demucs](https://github.com/adefossez/demucs) separates the vocals, then the [MMS forced aligner](https://pytorch.org/audio/stable/tutorials/forced_alignment_for_multilingual_data_tutorial.html) finds where each word of the given text is sung (any language, romanized through uroman). With line-synced lyrics every line is aligned inside its own window. A fit score against a time-reversed baseline rejects lyrics that don't belong to the recording. This runs in `aligner/align.py`, which uv sets up on first use (about 1.5 GB of packages and models).

Checked against ten human word-synced LRCLIB tracks (English, Korean, Japanese, rap):

| Method | Median word-start error | Per track |
| --- | --- | --- |
| Whisper transcription (WhisperKit small/turbo) on the mix | often no alignment at all | 10 s – 3 min |
| stable-ts forced alignment with Whisper turbo | 70–200 ms, some tracks off by tens of seconds | 20–140 s |
| Demucs + MMS, line windows | 30–100 ms, no failures | ~25 s |

## Behaviour

- Runs in the Darwin background band (`taskpolicy -b`), one track at a time, and waits while the Mac is on battery. `--fast` and `--battery` turn that off.
- Run it unattended with `nohup caffeinate -i .build/release/kveikur-lyrics > ~/Library/Logs/Kveikur/lyrics-batch.log 2>&1 &`.
- Tracks that already have word-synced lyrics are skipped; tracks that failed are remembered in `~/Library/Application Support/Kveikur/lyrics-batch.json` and skipped next time unless `--retry` is given. Ctrl-C and rerun to continue.

`--help` lists every option.
