from __future__ import annotations

import hashlib
from typing import Iterable

from .contracts import CaptureAnalysis, ProviderManifest
from .providers import capture_manifests_for_profile, default_capture_profile_id


def normalize(values: Iterable[float]) -> list[float]:
    vector = list(values)
    norm = sum(value * value for value in vector) ** 0.5
    if norm == 0:
        return [0.0 for _ in vector]
    return [value / norm for value in vector]


def stable_embedding_from_token(token: str, dimensions: int = 128) -> list[float]:
    chunks: list[float] = []
    counter = 0
    while len(chunks) < dimensions:
        digest = hashlib.sha256(f"{token}:{counter}".encode("utf-8")).digest()
        for byte in digest:
            chunks.append((byte / 127.5) - 1.0)
            if len(chunks) == dimensions:
                break
        counter += 1
    return normalize(chunks)


class DemoCapturePipeline:
    def __init__(
        self,
        profile_id: str | None = None,
        manifests: list[ProviderManifest] | None = None,
    ) -> None:
        self.profile_id = profile_id or default_capture_profile_id()
        self._manifests = manifests or capture_manifests_for_profile(self.profile_id)

    def analyze(
        self,
        capture_token: str | None = None,
        embedding_vector: list[float] | None = None,
        quality_score: float | None = None,
        liveness_score: float | None = None,
        bbox_confidence: float | None = None,
    ) -> CaptureAnalysis:
        token = capture_token or "demo-capture"
        vector = normalize(embedding_vector or stable_embedding_from_token(token))

        if quality_score is None:
            quality_score = 0.35 if "blur" in token else 0.93
        if liveness_score is None:
            liveness_score = 0.25 if "spoof" in token else 0.94
        if bbox_confidence is None:
            bbox_confidence = 0.97

        guidance = "pass"
        if liveness_score < 0.5 or quality_score < 0.5:
            guidance = "step_up"
        if liveness_score < 0.3:
            guidance = "reject"

        return CaptureAnalysis(
            embedding_vector=vector,
            quality_score=quality_score,
            liveness_score=liveness_score,
            bbox_confidence=bbox_confidence,
            guidance=guidance,
            manifests=self._manifests,
        )
