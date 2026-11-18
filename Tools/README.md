# Tools

Command-line helpers that work on a Kveikur library but are not part of the app. Each one is its own Swift package, so its dependencies (and any models it downloads) never end up in `Kveikur.app` or the iOS build.

Rules for anything placed here:

- One folder per tool, with its own `Package.swift` and `README.md`. Heavy ML work can live in a Python worker inside the tool, run through uv.
- To reuse app code, symlink `Sources/KveikurCore` into the tool's `Sources/` (see `kveikur-lyrics`). Depending on the repo root by path would tie the build to the checkout's folder name.
- Read the app's settings from the `dev.kveikur.player` defaults and its index from `~/Library/Application Support/Kveikur/library.sqlite`; write results where the app already looks (the lyrics cache, sidecar files), never into the app's preferences.
- Work in the background: low priority, one item at a time, resumable after Ctrl-C.

Build and run any tool with:

```sh
cd Tools/<name> && swift build -c release && .build/release/<name> --help
```

| Tool | What it does |
| --- | --- |
| [kveikur-lyrics](kveikur-lyrics) | Finds lyrics for the whole library and word-syncs them on-device (Demucs + MMS forced alignment). |
