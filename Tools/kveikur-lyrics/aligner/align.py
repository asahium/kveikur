"""Word timing for known lyrics.

Reads one JSON request per line on stdin and answers with one JSON line on stdout:
  {"audio": path, "start": s, "end": s|null, "lines": [{"text": str, "time": s|null}, ...]}
  -> {"ok": true, "lines": [[{"text", "start", "end"}, ...] | null, ...], "confidence": x}
  -> {"ok": false, "reason": str}

Vocals are separated with Demucs (htdemucs), then the lyrics are force-aligned to them with the
multilingual MMS aligner (romanized through uroman). When every sung line already has a time, each
line is aligned inside its own window, which keeps repeats and backing vocals from pulling words away.
"""
import gc
import json
import os
import re
import subprocess
import sys
import warnings

warnings.filterwarnings("ignore")
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

import numpy as np
import torch
import torchaudio
from torchaudio.pipelines import MMS_FA

DEVICE = "mps" if torch.backends.mps.is_available() else "cpu"
SR = MMS_FA.sample_rate
torch.set_num_threads(2)

_models = {}


def models():
    if not _models:
        from demucs.pretrained import get_model
        import uroman

        sep = get_model("htdemucs")
        sep.to(DEVICE).eval()
        _models["sep"] = sep
        _models["fa"] = MMS_FA.get_model(with_star=True).to(DEVICE).eval()
        _models["tok"] = MMS_FA.get_tokenizer()
        _models["align"] = MMS_FA.get_aligner()
        _models["uroman"] = uroman.Uroman()
    return _models


def decode(path, start, end, rate):
    cmd = ["ffmpeg", "-v", "error", "-nostdin"]
    if start:
        cmd += ["-ss", str(start)]
    if end:
        cmd += ["-to", str(end)]
    cmd += ["-i", path, "-f", "f32le", "-ac", "2", "-ar", str(rate), "-"]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    return torch.from_numpy(np.frombuffer(raw, dtype=np.float32).reshape(-1, 2).T.copy())


def vocals(path, start, end):
    sep = models()["sep"]
    from demucs.apply import apply_model

    wav = decode(path, start, end, sep.samplerate)
    ref = wav.mean(0)
    mean, std = ref.mean(), ref.std() + 1e-8
    with torch.inference_mode():
        out = apply_model(sep, ((wav - mean) / std)[None].to(DEVICE), device=DEVICE, split=True, overlap=0.25, progress=False)[0]
    voc = (out[sep.sources.index("vocals")].cpu() * std + mean).mean(0, keepdim=True)
    return torchaudio.functional.resample(voc, sep.samplerate, SR)


def emissions(wav):
    fa = models()["fa"]
    hop = SR * 30
    with torch.inference_mode():
        parts = [fa(wav[:, i:i + hop].to(DEVICE))[0].cpu() for i in range(0, wav.shape[1], hop)]
    return torch.cat(parts, 1)[0]


def roman(text):
    r = models()["uroman"].romanize_string(text).lower().replace("’", "'")
    return re.sub(r"[^a-z']", "", r)


def is_sung(text):
    t = text.strip()
    return bool(t) and not (t.startswith("[") and t.endswith("]"))


def force(em, words):
    """Token spans per word; words must be non-empty romanized strings."""
    return models()["align"](em, models()["tok"](words))


def fit(em, spans):
    """Share of words whose aligned frames are nearly as likely as the best symbol there."""
    best = em[:, :28].max(-1).values
    good = 0
    for w in spans:
        gaps = [float(em[f, t.token] - best[f]) for t in w for f in range(t.start, t.end)]
        if gaps and np.mean(gaps) > -1:
            good += 1
    return good / max(1, len(spans))


def align(req):
    lines = req["lines"]
    sung = [i for i, l in enumerate(lines) if is_sung(l["text"])]
    if not sung:
        return {"ok": False, "reason": "no sung lines"}
    tokens = []  # (line, original text with trailing space, romanized)
    for i in sung:
        parts = lines[i]["text"].split()
        for j, p in enumerate(parts):
            tokens.append((i, p + (" " if j + 1 < len(parts) else ""), roman(p)))
    keyed = [k for k, t in enumerate(tokens) if t[2]]
    if len(keyed) < 4:
        return {"ok": False, "reason": "lyrics can't be romanized"}

    wav = vocals(req["audio"], req.get("start") or 0, req.get("end"))
    duration = wav.shape[1] / SR
    starts = [None] * len(tokens)
    ends = [None] * len(tokens)
    fits, nulls, weights = [], [], []

    def place(em, idx, offset, seconds):
        ws = [tokens[k][2] for k in idx]
        spans = force(em, ws)
        ratio = seconds / em.shape[0]
        for k, s in zip(idx, spans):
            starts[k] = offset + s[0].start * ratio
            ends[k] = offset + s[-1].end * ratio
        fits.append(fit(em, spans))
        nulls.append(fit(em.flip(0), force(em.flip(0), ws)))
        weights.append(len(idx))

    timed = all(lines[i].get("time") is not None for i in sung)
    if timed:
        times = sorted({lines[i]["time"] for i in sung})
        for i in sung:
            idx = [k for k in keyed if tokens[k][0] == i]
            if not idx:
                continue
            a = lines[i]["time"]
            later = [t for t in times if t > a + 0.01]
            b = min(duration, (later[0] if later else a + 10) + 0.5)
            a0 = max(0.0, a - 0.5)
            seg = wav[:, int(a0 * SR):int(b * SR)]
            try:
                place(emissions(seg), idx, a0, seg.shape[1] / SR)
            except Exception:
                # Window too short for its letters: spread the line evenly.
                for n, k in enumerate(idx):
                    starts[k] = a + (b - a) * n / len(idx)
                    ends[k] = a + (b - a) * (n + 1) / len(idx)
    else:
        place(emissions(wav), keyed, 0.0, duration)

    score = float(np.average(fits, weights=weights)) if fits else 0.0
    null = float(np.average(nulls, weights=weights)) if nulls else 0.0
    if not (score >= 0.10 or (score >= 0.04 and score >= 2.5 * null)):
        return {"ok": False, "reason": f"lyrics don't match the vocals (fit {score:.2f}, chance {null:.2f})"}

    # Words with nothing to align (symbols, emoji) follow the word before them.
    last = 0.0
    for k in range(len(tokens)):
        if starts[k] is None:
            starts[k] = ends[k] = last
        last = ends[k]

    out = [None] * len(lines)
    for k, (i, text, _) in enumerate(tokens):
        out[i] = out[i] or []
        out[i].append({"text": text, "start": round(starts[k], 3), "end": round(max(ends[k], starts[k]), 3)})
    return {"ok": True, "lines": out, "confidence": round(score, 3)}


def main():
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        fatal = False
        try:
            reply = align(json.loads(raw))
        except Exception as e:
            reply = {"ok": False, "reason": f"{type(e).__name__}: {e}"}
            fatal = "out of memory" in str(e)
        # MPS keeps freed blocks cached; without this the pool grows track after track.
        gc.collect()
        if DEVICE == "mps":
            torch.mps.empty_cache()
        if fatal:
            reply["restart"] = True
        sys.stdout.write(json.dumps(reply, ensure_ascii=False) + "\n")
        sys.stdout.flush()
        if fatal:
            sys.exit(3)


if __name__ == "__main__":
    main()
