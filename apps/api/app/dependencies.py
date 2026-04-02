from __future__ import annotations

import os
from functools import lru_cache
from pathlib import Path

from .runtime_paths import ensure_local_pythonpaths

ensure_local_pythonpaths()

from mobile_attendance_biometrics import (
    DemoCapturePipeline,
    ProjectionTemplateProtector,
    default_capture_profile_id,
    default_demo_face_runtime_id,
)

from .repository import JsonRepository
from .service import AttendanceService


@lru_cache(maxsize=1)
def get_service() -> AttendanceService:
    root = Path(__file__).resolve().parents[3]
    repository = JsonRepository(root / "data/runtime/store.json")
    protector = ProjectionTemplateProtector(secret="truepresence-blueprint-secret-2026")
    capture_profile_id = os.getenv("MOBILE_ATTENDANCE_CAPTURE_PROFILE", default_capture_profile_id())
    face_runtime_id = os.getenv(
        "MOBILE_ATTENDANCE_DEMO_FACE_RUNTIME",
        default_demo_face_runtime_id(),
    )
    capture_pipeline = DemoCapturePipeline(profile_id=capture_profile_id)
    bootstrap_path = root / "data/demo/bootstrap.json"
    return AttendanceService(
        repository,
        protector,
        capture_pipeline,
        bootstrap_path,
        capture_profile_id=capture_profile_id,
        face_runtime_id=face_runtime_id,
    )
