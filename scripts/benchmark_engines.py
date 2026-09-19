#!/usr/bin/env python3
"""Benchmarks Chirp's recognition engines against each other on the same
audio, following the accuracy/latency/memory/robustness dimensions from the
"Open-Source Speech-to-Text Landscape" report's benchmarking-responsibly
section.

Test audio is synthetic (macOS `say`), so this measures "can the engine
transcribe clear, noise-free speech" — not real-world accuracy under accent,
noise, or far-field conditions. Treat it as a first screening pass, the same
caution the report itself gives about leaderboard numbers: useful for
narrowing candidates, not for a final call.

The fifth row, TheWhisper (TheStageAI), isn't a Chirp engine — there's no
Swift/CoreML path for it that doesn't require an account and API token for
TheStageAI's proprietary AppleSDK (https://app.thestage.ai), which is a
vendor decision this script doesn't make for you. Instead it runs the same
public checkpoint (TheStageAI/thewhisper-large-v3-turbo) through plain
`transformers` on CPU/MPS, so its WER is comparable but its latency/RSS are
not (no ANE acceleration). Needs a separate venv:
    python3.12 -m venv .venv-thewhisper
    .venv-thewhisper/bin/pip install torch transformers soundfile
Missing that venv just skips the row — the other four still run.

Usage:
    ./scripts/benchmark_engines.py [--app path/to/Chirp.app]
    ./scripts/benchmark_engines.py --thewhisper-python .venv-thewhisper/bin/python
"""
import argparse
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import List, Optional

TEST_SENTENCES = [
    "Testing the new Parakeet speech recognition engine for Chirp.",
    "Please schedule a follow-up meeting with the design team for "
    "Thursday afternoon, and send everyone the updated agenda beforehand.",
    "The quarterly revenue increased by twelve percent, driven mostly by "
    "the enterprise segment and a handful of renewals we almost lost.",
]

ENGINE_CONFIGS = [
    ("apple", None),
    ("whisper", "small"),
    ("whispercpp", "small"),
    ("parakeet", "v3"),
]

THEWHISPER_MODEL_ID = "TheStageAI/thewhisper-large-v3-turbo"

WORD_RE = re.compile(r"[a-z0-9']+")


def normalize(text: str) -> List[str]:
    return WORD_RE.findall(text.lower())


def word_error_rate(reference: str, hypothesis: str) -> float:
    ref = normalize(reference)
    hyp = normalize(hypothesis)
    if not ref:
        return 0.0 if not hyp else 1.0
    # Standard Levenshtein edit distance at the word level.
    dp = list(range(len(hyp) + 1))
    for i in range(1, len(ref) + 1):
        prev, dp[0] = dp[0], i
        for j in range(1, len(hyp) + 1):
            cur = dp[j]
            dp[j] = prev if ref[i - 1] == hyp[j - 1] else 1 + min(prev, dp[j], dp[j - 1])
            prev = cur
    return dp[len(hyp)] / len(ref)


def run_once(binary: Path, audio_file: Path, engine: str, model: Optional[str]):
    cmd = [str(binary), "--transcribe", str(audio_file), "--engine", engine]
    if model:
        cmd += ["--whisper-model", model]
    started = time.monotonic()
    result = subprocess.run(
        ["/usr/bin/time", "-l"] + cmd,
        capture_output=True, text=True, timeout=180)
    elapsed = time.monotonic() - started

    formatted = ""
    for line in result.stdout.splitlines():
        if line.startswith("FORMATTED: "):
            formatted = line[len("FORMATTED: "):]
    peak_rss_mb = None
    match = re.search(r"(\d+)\s+maximum resident set size", result.stderr)
    if match:
        peak_rss_mb = int(match.group(1)) / (1024 * 1024)
    return formatted, elapsed, peak_rss_mb


def run_thewhisper(python_bin: Path, audio_files: List[Path]):
    """Runs the TheWhisper worker (a separate venv/process — see the module
    docstring) and returns (texts, latencies), or None if it can't run."""
    worker = Path(__file__).resolve().parent / "_thewhisper_worker.py"
    try:
        result = subprocess.run(
            [str(python_bin), str(worker), *(str(f) for f in audio_files)],
            capture_output=True, text=True, timeout=600)
    except FileNotFoundError:
        return None
    if result.returncode != 0:
        print(f"  TheWhisper worker failed ({python_bin}):", file=sys.stderr)
        print(result.stderr[-2000:], file=sys.stderr)
        return None

    texts, latencies = [], []
    for line in result.stdout.splitlines():
        if not line.startswith("TEXT: "):
            continue
        body = line[len("TEXT: "):]
        text, _, latency_str = body.rpartition("\tLATENCY: ")
        texts.append(text)
        latencies.append(float(latency_str))
    if len(texts) != len(audio_files):
        print(f"  TheWhisper worker returned {len(texts)} results for "
              f"{len(audio_files)} inputs (expected 1:1); skipping.",
              file=sys.stderr)
        return None
    return texts, latencies


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--app", default="build/Chirp.app",
        help="Path to the built Chirp.app (default: build/Chirp.app)")
    parser.add_argument(
        "--thewhisper-python", default=".venv-thewhisper/bin/python",
        help="Python interpreter with TheWhisper's deps installed "
             "(default: .venv-thewhisper/bin/python). Skipped if missing.")
    args = parser.parse_args()

    binary = Path(args.app) / "Contents/MacOS/Chirp"
    if not binary.exists():
        print(f"Chirp binary not found at {binary} — run make_app.sh first. "
              f"Skipping Chirp's own engines, still trying TheWhisper.",
              file=sys.stderr)

    tmp_dir = Path("/tmp/chirp_benchmark")
    tmp_dir.mkdir(exist_ok=True)
    audio_files = []
    for i, sentence in enumerate(TEST_SENTENCES):
        f = tmp_dir / f"sentence_{i}.aiff"
        # Explicit voice: a first run with no `-v` (system default) made
        # every engine — including Apple's own — mangle the same sentence
        # the same way, which points at the input audio rather than any one
        # engine. This machine's system locale isn't US English, so the
        # unnamed default voice is likely a non-English or novelty voice.
        subprocess.run(["say", "-v", "Samantha", "-o", str(f), sentence], check=True)
        audio_files.append(f)

    rows = []
    if binary.exists():
        for engine, model in ENGINE_CONFIGS:
            label = f"{engine}" + (f"/{model}" if model else "")
            print(f"\n=== {label} ===")

            # Warm up first (may trigger a one-time model download) so the
            # timed runs below measure steady-state speed, not a cold download
            # that would otherwise skew whichever sentence happened to run first.
            print("  warming up (downloads the model on first run)...")
            cmd = [str(binary), "--transcribe", str(audio_files[0]), "--engine", engine]
            if model:
                cmd += ["--whisper-model", model]
            subprocess.run(cmd, capture_output=True, text=True, timeout=600)

            wers, latencies, rss_values = [], [], []
            for sentence, audio_file in zip(TEST_SENTENCES, audio_files):
                formatted, elapsed, peak_rss_mb = run_once(binary, audio_file, engine, model)
                wer = word_error_rate(sentence, formatted)
                wers.append(wer)
                latencies.append(elapsed)
                if peak_rss_mb is not None:
                    rss_values.append(peak_rss_mb)
                print(f"  {elapsed:5.2f}s  WER {wer*100:5.1f}%  -> {formatted!r}")
            rows.append({
                "label": label,
                "avg_wer": sum(wers) / len(wers) * 100,
                "avg_latency": sum(latencies) / len(latencies),
                "avg_rss_mb": sum(rss_values) / len(rss_values) if rss_values else None,
            })

    thewhisper_python = Path(args.thewhisper_python)
    label = "thewhisper/large-v3-turbo*"
    print(f"\n=== {label} ===")
    if not thewhisper_python.exists():
        print(f"  no venv at {thewhisper_python} — skipping (see module "
              f"docstring to set one up)")
    else:
        print("  loading (downloads the model on first run)...")
        outcome = run_thewhisper(thewhisper_python, audio_files)
        if outcome is None:
            print("  skipped — see stderr above")
        else:
            texts, latencies = outcome
            wers = [word_error_rate(s, t) for s, t in zip(TEST_SENTENCES, texts)]
            for text, wer, elapsed in zip(texts, wers, latencies):
                print(f"  {elapsed:5.2f}s  WER {wer*100:5.1f}%  -> {text!r}")
            rows.append({
                "label": label,
                "avg_wer": sum(wers) / len(wers) * 100,
                "avg_latency": sum(latencies) / len(latencies),
                "avg_rss_mb": None,
            })

    if not rows:
        raise SystemExit("Nothing ran — no Chirp binary and no TheWhisper venv.")

    print("\n* thewhisper runs via plain `transformers` on CPU/MPS, not "
          "CoreML/ANE through a Swift engine — its WER is comparable to the "
          "rows above, its latency/RSS are not.")
    width = max(16, max(len(row["label"]) for row in rows) + 2)
    total = width + 40
    print("\n" + "=" * total)
    print(f"{'Engine':<{width}}{'Avg WER':>10}{'Avg latency':>14}{'Avg peak RSS':>16}")
    print("-" * total)
    for row in rows:
        rss = f"{row['avg_rss_mb']:.0f} MB" if row["avg_rss_mb"] else "n/a"
        print(f"{row['label']:<{width}}{row['avg_wer']:>9.1f}%{row['avg_latency']:>13.2f}s{rss:>16}")


if __name__ == "__main__":
    main()
