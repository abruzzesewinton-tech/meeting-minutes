#!/usr/bin/env python3
"""Shared local-only audio and CAM++ helpers for speaker attribution."""

from __future__ import annotations

import hashlib
import math
import sys
from pathlib import Path

import numpy as np
import soundfile as sf
import torch
import torchaudio


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalized(vector: np.ndarray) -> np.ndarray:
    norm = float(np.linalg.norm(vector))
    return vector if norm == 0 else vector / norm


def cosine(left: np.ndarray, right: np.ndarray) -> float:
    return float(np.dot(normalized(left), normalized(right)))


def load_audio(path: Path) -> tuple[torch.Tensor, int]:
    audio, sample_rate = sf.read(path, dtype="float32", always_2d=True)
    return torch.from_numpy(audio.T.copy()), sample_rate


def crop(waveform: torch.Tensor, sample_rate: int, start: float, end: float) -> torch.Tensor:
    first = max(0, round(start * sample_rate))
    last = min(waveform.shape[-1], round(end * sample_rate))
    return waveform[:, first:last]


def windows(start: float, end: float, size: float = 4.0, hop: float = 3.0) -> list[tuple[float, float]]:
    duration = end - start
    if duration <= size + 0.25:
        return [(start, end)]
    result = []
    cursor = start
    while cursor + size < end:
        result.append((cursor, cursor + size))
        cursor += hop
    if not result or result[-1][1] < end - 0.25:
        result.append((max(start, end - size), end))
    return result


class VoiceEncoder:
    """Minimal CAM++ encoder using the existing local 3D-Speaker checkout."""

    def __init__(self, tool_root: Path, model_path: Path):
        sys.path.insert(0, str(tool_root))
        from speakerlab.models.campplus.DTDNN import CAMPPlus
        from speakerlab.process.processor import FBank

        self.device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
        self.model = CAMPPlus(feat_dim=80, embedding_size=192)
        state = torch.load(model_path, map_location="cpu", weights_only=True)
        self.model.load_state_dict(state)
        self.model.to(self.device).eval()
        self.features = FBank(80, sample_rate=16000, mean_nor=True)

    def encode_waveform(self, waveform: torch.Tensor, sample_rate: int) -> np.ndarray:
        if waveform.shape[0] > 1:
            waveform = waveform.mean(dim=0, keepdim=True)
        if sample_rate != 16000:
            waveform = torchaudio.functional.resample(waveform, sample_rate, 16000)
        if waveform.shape[-1] < 8000:
            repeats = math.ceil(8000 / waveform.shape[-1])
            waveform = waveform.repeat(1, repeats)[:, :8000]
        feat = self.features(waveform).unsqueeze(0).to(self.device)
        with torch.inference_mode():
            vector = self.model(feat).squeeze(0).detach().cpu().numpy()
        return normalized(vector)

    def encode_interval(
        self,
        waveform: torch.Tensor,
        sample_rate: int,
        start: float,
        end: float,
    ) -> np.ndarray:
        vectors = [
            self.encode_waveform(crop(waveform, sample_rate, left, right), sample_rate)
            for left, right in windows(start, end)
        ]
        return normalized(np.mean(vectors, axis=0))
