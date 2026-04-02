from .contracts import (
    BinaryMetricSnapshot,
    BoundingBox,
    CaptureAnalysis,
    FaceImageAnalysis,
    FaceRuntimeUnavailableError,
    OODScenarioObservation,
    ProtectedTemplate,
    ProviderManifest,
)
from .demo import DemoCapturePipeline, stable_embedding_from_token
from .evaluation import compute_binary_metrics, default_ood_observations
from .method_stack import MethodComponent, MethodStackProfile, latest_method_stack_profile
from .providers import (
    DEFAULT_CAPTURE_PROFILE_ID,
    DEFAULT_DEMO_FACE_RUNTIME_ID,
    CaptureAnalyzer,
    DeploymentProfile,
    RuntimeBinding,
    RuntimeSelectionStatus,
    TemplateProtector,
    capture_manifests_for_profile,
    default_capture_profile_id,
    default_demo_face_runtime_id,
    demo_face_runtime_status,
    deployment_profiles,
    get_deployment_profile,
)
from .protection import ProjectionTemplateProtector

__all__ = [
    "BinaryMetricSnapshot",
    "BoundingBox",
    "CaptureAnalysis",
    "CaptureAnalyzer",
    "DEFAULT_CAPTURE_PROFILE_ID",
    "DEFAULT_DEMO_FACE_RUNTIME_ID",
    "DemoCapturePipeline",
    "DeploymentProfile",
    "FaceImageAnalysis",
    "FaceRuntimeUnavailableError",
    "InsightFaceImageRuntime",
    "MethodComponent",
    "MethodStackProfile",
    "OODScenarioObservation",
    "ProjectionTemplateProtector",
    "ProtectedTemplate",
    "ProviderManifest",
    "RuntimeBinding",
    "RuntimeSelectionStatus",
    "TemplateProtector",
    "capture_manifests_for_profile",
    "compute_binary_metrics",
    "decode_image_base64",
    "default_capture_profile_id",
    "default_demo_face_runtime_id",
    "default_ood_observations",
    "demo_face_runtime_status",
    "deployment_profiles",
    "get_deployment_profile",
    "latest_method_stack_profile",
    "stable_embedding_from_token",
]


def __getattr__(name: str):
    if name in {"InsightFaceImageRuntime", "decode_image_base64"}:
        from . import image_runtime as _image_runtime

        return getattr(_image_runtime, name)
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
