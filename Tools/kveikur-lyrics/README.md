# kveikur-lyrics

Walks the Kveikur library, downloads missing lyrics (LRCLIB, NetEase, Genius when a token is set in the app) and gives word timing to lyrics that only have line timing or none, using Whisper on the Neural Engine ([WhisperKit](https://github.com/argmaxinc/WhisperKit)). Results go to Kveikur's lyrics cache, so the app shows them as word-synced without any setup.

```sh
swift build -c release
.build/release/kveikur-lyrics --dry-run          # what would be done
.build/release/kveikur-lyrics                    # the whole library, except folders named OST
.build/release/kveikur-lyrics ~/Music/Bleachers  # one folder or file
```

- Runs in the Darwin background band (throttled CPU and disk), one track at a time, and waits while the Mac is on battery. `--fast` and `--battery` turn that off.
- Tracks that already have word-synced lyrics are skipped; tracks Whisper couldn't match are remembered in `~/Library/Application Support/Kveikur/lyrics-batch.json` and skipped next time unless `--retry` is given. Ctrl-C and rerun to continue.
- Whisper only provides anchors: recognized words are matched to the known lyrics, and words it missed are spread between them by length. With line-synced lyrics every word stays inside its line.
- Models download on first use into `~/Library/Application Support/Kveikur/whisper`: `small` (216 MB, default) or `--model turbo` (632 MB, hears singing better).

`--help` lists every option.
