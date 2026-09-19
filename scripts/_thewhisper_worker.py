#!/usr/bin/env python3
"""Runs TheStageAI/thewhisper-large-v3-turbo (plain `transformers`, not
TheStageAI's account-gated AppleSDK) over one or more audio files. Invoked
by benchmark_engines.py as a subprocess in a separate venv — see that
script's module docstring for setup. Not part of Chirp; this only exists
to screen the model's accuracy before deciding whether it's worth a real
Swift engine.

Prints one line per input: `TEXT: <transcription><TAB>LATENCY: <seconds>`
"""
import sys
import time

import torch
from transformers import pipeline

MODEL_ID = "TheStageAI/thewhisper-large-v3-turbo"


def main():
    audio_paths = sys.argv[1:]
    if not audio_paths:
        raise SystemExit("usage: _thewhisper_worker.py AUDIO_FILE...")

    device = "mps" if torch.backends.mps.is_available() else "cpu"
    pipe = pipeline(
        "automatic-speech-recognition", model=MODEL_ID, device=device,
        dtype=torch.float16 if device == "mps" else torch.float32)

    for path in audio_paths:
        started = time.monotonic()
        result = pipe(path)
        elapsed = time.monotonic() - started
        text = result["text"].strip().replace("\n", " ").replace("\t", " ")
        print(f"TEXT: {text}\tLATENCY: {elapsed:.4f}")


if __name__ == "__main__":
    main()
