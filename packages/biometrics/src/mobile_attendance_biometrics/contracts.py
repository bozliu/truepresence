from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class ProviderManifest(BaseModel):
    model_config = ConfigDict(frozen=True)

    provider: str
    family: str
    version: str
    runtime: str


class BoundingBox(BaseModel):
    x: float
    y: float
    width: float
    height: float
    confidence: float = Field(ge=0.0, le=1.0)


class ProtectedTemplate(BaseModel):
    scheme: str
    dimension: int
    bitstring: str
    digest: str


class CaptureAnalysis(BaseModel):
    embedding_vector: list[float] = Field(min_length=16, max_length=1024)
    quality_score: float = Field(ge=0.0, le=1.0)
    liveness_score: float = Field(ge=0.0, le=1.0)
    bbox_confidence: float = Field(ge=0.0, le=1.0)
    guidance: Literal["pass", "step_up", "reject"] = "pass"
    manifests: list[ProviderManifest]


class BinaryMetricSnapshot(BaseModel):
    threshold: float
    apcer: float
    bpcer: float
    accuracy: float


class OODScenarioObservation(BaseModel):
    scenario: str
    risk: Literal["low", "medium", "high"]
    expected_failure_mode: str
    mitigation: str


class FaceRuntimeUnavailableError(RuntimeError):
    """Raised when the optional image runtime is unavailable."""


class FaceImageAnalysis(BaseModel):
    embedding_vector: list[float] = Field(min_length=16, max_length=4096)
    quality_score: float = Field(ge=0.0, le=1.0)
    detection_score: float = Field(ge=0.0, le=1.0)
    bbox: BoundingBox | None = None
    image_width: int | None = None
    image_height: int | None = None
    detected_face_count: int = 0
    manifests: list[ProviderManifest] = Field(default_factory=list)
