from __future__ import annotations

import base64
import io
from typing import Any

import numpy as np
from PIL import Image

from .contracts import BoundingBox, FaceImageAnalysis, FaceRuntimeUnavailableError, ProviderManifest
from .demo import normalize


def decode_image_base64(image_base64: str) -> np.ndarray:
    payload = image_base64.strip()
    if payload.startswith("data:") and "," in payload:
        payload = payload.split(",", 1)[1]

    raw_bytes = base64.b64decode(payload, validate=False)
    try:
        with Image.open(io.BytesIO(raw_bytes)) as image:
            rgb_image = image.convert("RGB")
            return np.array(rgb_image)
    except Exception as error:
        raise ValueError("Could not decode image payload.") from error


class InsightFaceImageRuntime:
    def __init__(
        self,
        model_name: str = "buffalo_l",
        providers: list[str] | None = None,
    ) -> None:
        try:
            from insightface.app import FaceAnalysis
            import insightface
        except Exception as error:  # pragma: no cover - optional dependency path
            raise FaceRuntimeUnavailableError(
                "Optional demo face runtime is unavailable. Install insightface in the dl env."
            ) from error

        self._face_analysis_cls = FaceAnalysis
        self._insightface_version = getattr(insightface, "__version__", "unknown")
        self.model_name = model_name
        self.providers = providers or ["CPUExecutionProvider"]
        self._app: Any | None = None
        self._manifests = [
            ProviderManifest(
                provider="demo-scrfd",
                family="scrfd-class-detector",
                version=f"{self.model_name}@{self._insightface_version}",
                runtime="server",
            ),
            ProviderManifest(
                provider="demo-arcface",
                family="arcface-class-embedder",
                version=f"{self.model_name}@{self._insightface_version}",
                runtime="server",
            ),
        ]

    def _app_instance(self) -> Any:
        if self._app is None:
            self._app = self._face_analysis_cls(
                name=self.model_name,
                allowed_modules=["detection", "recognition"],
                providers=self.providers,
            )
            self._app.prepare(ctx_id=-1, det_size=(640, 640))
        return self._app

    def analyze(self, image_base64: str) -> FaceImageAnalysis:
        image = decode_image_base64(image_base64)
        faces = self._app_instance().get(image)
        if not faces:
            raise ValueError("No face detected in the provided image.")

        face = max(
            faces,
            key=lambda candidate: float(
                (candidate.bbox[2] - candidate.bbox[0]) * (candidate.bbox[3] - candidate.bbox[1])
            ),
        )

        embedding = getattr(face, "normed_embedding", None)
        if embedding is None:
            embedding = getattr(face, "embedding", None)
        if embedding is None:
            raise ValueError("Face runtime did not return an embedding.")

        bbox_array = getattr(face, "bbox", None)
        bbox = None
        bbox_ratio = 0.0
        if bbox_array is not None:
            x1, y1, x2, y2 = [float(value) for value in bbox_array.tolist()]
            width = max(0.0, x2 - x1)
            height = max(0.0, y2 - y1)
            bbox = BoundingBox(
                x=x1,
                y=y1,
                width=width,
                height=height,
                confidence=float(getattr(face, "det_score", 0.0)),
            )
            image_area = max(1.0, float(image.shape[0] * image.shape[1]))
            bbox_ratio = (width * height) / image_area

        detection_score = float(getattr(face, "det_score", 0.0))
        quality_score = max(0.45, min(0.99, 0.58 + detection_score * 0.22 + bbox_ratio * 0.8))

        return FaceImageAnalysis(
            embedding_vector=normalize(embedding.tolist()),
            quality_score=quality_score,
            detection_score=detection_score,
            bbox=bbox,
            image_width=int(image.shape[1]),
            image_height=int(image.shape[0]),
            detected_face_count=len(faces),
            manifests=self._manifests,
        )
