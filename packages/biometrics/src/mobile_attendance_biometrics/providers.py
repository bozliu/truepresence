from __future__ import annotations

from typing import Literal, Protocol

from pydantic import BaseModel, Field

from .contracts import CaptureAnalysis, ProtectedTemplate, ProviderManifest


class CaptureAnalyzer(Protocol):
    def analyze(
        self,
        capture_token: str | None = None,
        embedding_vector: list[float] | None = None,
        quality_score: float | None = None,
        liveness_score: float | None = None,
        bbox_confidence: float | None = None,
    ) -> CaptureAnalysis: ...


class TemplateProtector(Protocol):
    def protect(self, embedding_vector: list[float]) -> ProtectedTemplate: ...

    def similarity(self, left: ProtectedTemplate, right: ProtectedTemplate) -> float: ...


class RuntimeBinding(BaseModel):
    role: str
    provider: str
    family: str
    version: str
    runtime: Literal["device", "server", "hybrid", "demo", "test"]
    artifact_format: Literal["coreml", "onnx", "tflite", "ncnn", "python", "service", "contract"]
    commercial_release_safe: bool
    repo_status: Literal["contract_only", "external_artifact", "demo_optional", "test_override"]
    source_url: str | None = None
    summary: str


class DeploymentProfile(BaseModel):
    profile_id: str
    label: str
    stage: Literal["public_release", "production_extension", "demo_only", "test_only"]
    commercial_release_safe: bool
    summary: str
    target_devices: list[str] = Field(default_factory=list)
    recommended_for: list[str] = Field(default_factory=list)
    env_overrides: dict[str, str] = Field(default_factory=dict)
    bindings: list[RuntimeBinding] = Field(default_factory=list)


class RuntimeSelectionStatus(BaseModel):
    runtime_id: str
    label: str
    status: Literal["ready", "disabled", "external_setup_required", "test_override", "unknown"]
    commercial_release_safe: bool
    summary: str
    profile_id: str | None = None
    detail: str | None = None
    bindings: list[RuntimeBinding] = Field(default_factory=list)


DEFAULT_CAPTURE_PROFILE_ID = "public-prod-safe-mobile-2026-03-28"
SERVER_EXTENSION_PROFILE_ID = "public-prod-safe-server-1n-2026-03-28"
IPHONE_TRUEDEPTH_DEMO_PROFILE_ID = "iphone-truedepth-coreml-demo-2026-03-30"
LAPTOP_DEMO_PROFILE_ID = "laptop-demo-insightface-2026-03-28"
DEFAULT_DEMO_FACE_RUNTIME_ID = "insightface-buffalo_l"
DEFAULT_DEMO_FACE_RUNTIME_SELECTION = "disabled"


def _profile_catalog() -> tuple[DeploymentProfile, ...]:
    return (
        DeploymentProfile(
            profile_id=DEFAULT_CAPTURE_PROFILE_ID,
            label="Public Release Mobile Capture",
            stage="public_release",
            commercial_release_safe=True,
            summary=(
                "Default public-release-safe mobile capture profile. Uses the repo's current 2026 "
                "recommendation stack contracts, but expects externally managed model artifacts rather than "
                "shipping weights inside this repository."
            ),
            target_devices=[
                "iPhone 14 Pro or newer",
                "Apple Silicon Macs for local validation",
                "Android flagships in the Snapdragon 8 Gen 2/3, Tensor G4, or Dimensity 9300+ class",
            ],
            recommended_for=[
                "employee mobile attendance",
                "remote work verification",
                "field workforce check-in",
            ],
            env_overrides={
                "MOBILE_ATTENDANCE_CAPTURE_PROFILE": DEFAULT_CAPTURE_PROFILE_ID,
                "MOBILE_ATTENDANCE_DEMO_FACE_RUNTIME": "disabled",
            },
            bindings=[
                RuntimeBinding(
                    role="detector",
                    provider="scrfd-coreml",
                    family="scrfd-class-detector",
                    version="profile-2026-03-28",
                    runtime="device",
                    artifact_format="coreml",
                    commercial_release_safe=True,
                    repo_status="external_artifact",
                    source_url="https://github.com/deepinsight/insightface",
                    summary="Edge/mobile detector-alignment baseline for phone-side capture.",
                ),
                RuntimeBinding(
                    role="embedder",
                    provider="facelivt-coreml",
                    family="facelivt-mobile-embedder",
                    version="2506.10361-profile-2026-03-28",
                    runtime="device",
                    artifact_format="coreml",
                    commercial_release_safe=True,
                    repo_status="external_artifact",
                    source_url="https://arxiv.org/abs/2506.10361",
                    summary="Latest mobile-oriented face recognition direction retained by the repo.",
                ),
                RuntimeBinding(
                    role="liveness",
                    provider="intermediate-vit-pad-coreml",
                    family="vit-pad-passive-liveness",
                    version="2505.24402-profile-2026-03-28",
                    runtime="device",
                    artifact_format="coreml",
                    commercial_release_safe=True,
                    repo_status="external_artifact",
                    source_url="https://arxiv.org/abs/2505.24402",
                    summary="Passive RGB PAD path for phone-side spoof resistance.",
                ),
                RuntimeBinding(
                    role="step_up",
                    provider="m3fas-step-up",
                    family="multimodal-active-fas",
                    version="2301.12831-profile-2026-03-28",
                    runtime="hybrid",
                    artifact_format="contract",
                    commercial_release_safe=True,
                    repo_status="contract_only",
                    source_url="https://arxiv.org/abs/2301.12831",
                    summary="Challenge-response escalation path for higher-risk mobile checks.",
                ),
                RuntimeBinding(
                    role="template_protection",
                    provider="facecloak-protected-template",
                    family="renewable-1to1-template-protection",
                    version="2504.06131-profile-2026-03-28",
                    runtime="hybrid",
                    artifact_format="contract",
                    commercial_release_safe=True,
                    repo_status="contract_only",
                    source_url="https://arxiv.org/abs/2504.06131",
                    summary="Protected-template default for public-release-safe 1:1 verification.",
                ),
            ],
        ),
        DeploymentProfile(
            profile_id=SERVER_EXTENSION_PROFILE_ID,
            label="Public Release Server 1:N Extension",
            stage="production_extension",
            commercial_release_safe=True,
            summary=(
                "Optional backend extension for larger encrypted 1:N search and review operations. "
                "This is a server-side complement to the public mobile capture profile."
            ),
            target_devices=[
                "x86 mini servers",
                "Jetson Orin class edge servers",
                "private tenant backend clusters",
            ],
            recommended_for=[
                "encrypted 1:N identification",
                "review queues",
                "operations backends",
            ],
            env_overrides={
                "MOBILE_ATTENDANCE_CAPTURE_PROFILE": DEFAULT_CAPTURE_PROFILE_ID,
                "MOBILE_ATTENDANCE_DEMO_FACE_RUNTIME": "disabled",
            },
            bindings=[
                RuntimeBinding(
                    role="detector",
                    provider="scrfd-onnx-server",
                    family="scrfd-class-detector",
                    version="profile-2026-03-28",
                    runtime="server",
                    artifact_format="onnx",
                    commercial_release_safe=True,
                    repo_status="external_artifact",
                    source_url="https://github.com/deepinsight/insightface",
                    summary="Server-side detector option for admin and 1:N workflows.",
                ),
                RuntimeBinding(
                    role="embedder",
                    provider="facelivt-onnx-server",
                    family="facelivt-mobile-embedder",
                    version="2506.10361-profile-2026-03-28",
                    runtime="server",
                    artifact_format="onnx",
                    commercial_release_safe=True,
                    repo_status="external_artifact",
                    source_url="https://arxiv.org/abs/2506.10361",
                    summary="Server deployment of the repo's current recommended recognition family.",
                ),
                RuntimeBinding(
                    role="template_protection",
                    provider="idface-encrypted-index",
                    family="encrypted-1toN-template-search",
                    version="2507.12050-profile-2026-03-28",
                    runtime="server",
                    artifact_format="contract",
                    commercial_release_safe=True,
                    repo_status="contract_only",
                    source_url="https://arxiv.org/abs/2507.12050",
                    summary="Encrypted 1:N search anchor for larger galleries and review flows.",
                ),
                RuntimeBinding(
                    role="evaluation",
                    provider="oodface-eval-suite",
                    family="oodface-robustness-evaluation",
                    version="2412.02479-profile-2026-03-28",
                    runtime="server",
                    artifact_format="contract",
                    commercial_release_safe=True,
                    repo_status="contract_only",
                    source_url="https://arxiv.org/abs/2412.02479",
                    summary="Robustness expectations for low light, replay, blur, and appearance shift.",
                ),
            ],
        ),
        DeploymentProfile(
            profile_id=IPHONE_TRUEDEPTH_DEMO_PROFILE_ID,
            label="iPhone TrueDepth Core ML Demo",
            stage="demo_only",
            commercial_release_safe=False,
            summary=(
                "Real iPhone demo profile that uses the front TrueDepth camera, bundled Core ML "
                "face embedding, and depth-assisted liveness for on-device 1:1 verification. "
                "This profile exists to power the connected-device demo path and should be treated "
                "as demo/runtime-specific until a team swaps in its own reviewed model artifacts."
            ),
            target_devices=[
                "iPhone 14 Pro or newer with Face ID class front TrueDepth hardware",
                "modern iPhones that can run Core ML on the Apple Neural Engine",
            ],
            recommended_for=[
                "on-device sales demos",
                "LAN-backed iPhone attendance walkthroughs",
                "field verification demos that need hardware depth liveness",
            ],
            env_overrides={
                "MOBILE_ATTENDANCE_CAPTURE_PROFILE": DEFAULT_CAPTURE_PROFILE_ID,
                "MOBILE_ATTENDANCE_DEMO_FACE_RUNTIME": "disabled",
            },
            bindings=[
                RuntimeBinding(
                    role="detector",
                    provider="apple-vision-face",
                    family="vision-face-detection",
                    version="ios17-26.4-demo",
                    runtime="device",
                    artifact_format="service",
                    commercial_release_safe=False,
                    repo_status="demo_optional",
                    source_url="https://developer.apple.com/documentation/vision/tracking-the-user-s-face-in-real-time",
                    summary="Largest-face selection and crop on the iPhone demo path using Apple's on-device Vision stack.",
                ),
                RuntimeBinding(
                    role="embedder",
                    provider="arcface-mobileface-coreml",
                    family="arcface-mobileface-embedder",
                    version="w600k_mbf-coreml-2026-03-30",
                    runtime="device",
                    artifact_format="coreml",
                    commercial_release_safe=False,
                    repo_status="demo_optional",
                    source_url="https://github.com/yakhyo/face-reidentification",
                    summary="Bundled Core ML demo embedder used for live iPhone 1:1 face verification on ANE-capable devices.",
                ),
                RuntimeBinding(
                    role="liveness",
                    provider="apple-truedepth-depth-gate",
                    family="truedepth-depth-assisted-liveness",
                    version="depth-heuristic-2026-03-30",
                    runtime="device",
                    artifact_format="service",
                    commercial_release_safe=False,
                    repo_status="demo_optional",
                    source_url="https://developer.apple.com/documentation/avfoundation/streaming-depth-data-from-the-truedepth-camera",
                    summary="Uses the front TrueDepth depth stream to reject flat spoof surfaces during the iPhone demo flow.",
                ),
                RuntimeBinding(
                    role="template_protection",
                    provider="local-protected-template",
                    family="signed-random-projection-v1",
                    version="demo-2026-03-30",
                    runtime="device",
                    artifact_format="contract",
                    commercial_release_safe=False,
                    repo_status="demo_optional",
                    source_url="https://arxiv.org/abs/2504.06131",
                    summary="Local protected-template calibration for demo 1:1 verification before claims are sent to the backend.",
                ),
            ],
        ),
        DeploymentProfile(
            profile_id=LAPTOP_DEMO_PROFILE_ID,
            label="Laptop Demo Local Face Registry",
            stage="demo_only",
            commercial_release_safe=False,
            summary=(
                "Optional local-only runtime that keeps the browser laptop demo usable out of the box. "
                "It is suitable for sales/demo validation, not for the repo's commercial release path."
            ),
            target_devices=[
                "Apple Silicon Macs",
                "developer laptops with Python + ONNX Runtime",
            ],
            recommended_for=[
                "local sales demos",
                "browser validation",
                "face-registry smoke tests",
            ],
            env_overrides={
                "MOBILE_ATTENDANCE_CAPTURE_PROFILE": DEFAULT_CAPTURE_PROFILE_ID,
                "MOBILE_ATTENDANCE_DEMO_FACE_RUNTIME": DEFAULT_DEMO_FACE_RUNTIME_ID,
            },
            bindings=[
                RuntimeBinding(
                    role="detector",
                    provider="demo-scrfd",
                    family="scrfd-class-detector",
                    version="buffalo_l@0.7.3",
                    runtime="demo",
                    artifact_format="python",
                    commercial_release_safe=False,
                    repo_status="demo_optional",
                    source_url="https://github.com/deepinsight/insightface",
                    summary="Local detector path used only by the laptop face-registry demo.",
                ),
                RuntimeBinding(
                    role="embedder",
                    provider="demo-arcface",
                    family="arcface-class-embedder",
                    version="buffalo_l@0.7.3",
                    runtime="demo",
                    artifact_format="python",
                    commercial_release_safe=False,
                    repo_status="demo_optional",
                    source_url="https://github.com/deepinsight/insightface",
                    summary="Local recognition embedding path for demo registration and recognition.",
                ),
            ],
        ),
    )


def deployment_profiles() -> list[DeploymentProfile]:
    return [profile.model_copy(deep=True) for profile in _profile_catalog()]


def get_deployment_profile(profile_id: str | None = None) -> DeploymentProfile:
    selected_id = profile_id or DEFAULT_CAPTURE_PROFILE_ID
    for profile in _profile_catalog():
        if profile.profile_id == selected_id:
            return profile.model_copy(deep=True)
    available = ", ".join(profile.profile_id for profile in _profile_catalog())
    raise ValueError(f"Unknown deployment profile `{selected_id}`. Available: {available}")


def default_capture_profile_id() -> str:
    return DEFAULT_CAPTURE_PROFILE_ID


def default_demo_face_runtime_id() -> str:
    return DEFAULT_DEMO_FACE_RUNTIME_SELECTION


def capture_manifests_for_profile(profile_id: str | None = None) -> list[ProviderManifest]:
    profile = get_deployment_profile(profile_id)
    manifests: list[ProviderManifest] = []
    for binding in profile.bindings:
        if binding.role not in {"detector", "embedder", "liveness"}:
            continue
        manifests.append(
            ProviderManifest(
                provider=binding.provider,
                family=binding.family,
                version=binding.version,
                runtime=binding.runtime,
            )
        )
    return manifests


def demo_face_runtime_status(
    runtime_id: str | None,
    *,
    runtime_ready: bool,
    error_detail: str | None = None,
) -> RuntimeSelectionStatus:
    selected_id = (runtime_id or "disabled").strip() or "disabled"
    if selected_id in {"disabled", "none"}:
        return RuntimeSelectionStatus(
            runtime_id="disabled",
            label="Demo Face Registry Disabled",
            status="disabled",
            commercial_release_safe=True,
            summary=(
                "The optional local face-registry runtime is disabled. This is the recommended public "
                "release posture when you only want the reusable contracts and API surface."
            ),
            detail=error_detail,
        )

    if selected_id == DEFAULT_DEMO_FACE_RUNTIME_ID:
        profile = get_deployment_profile(LAPTOP_DEMO_PROFILE_ID)
        return RuntimeSelectionStatus(
            runtime_id=selected_id,
            label="InsightFace buffalo_l local demo runtime",
            status="ready" if runtime_ready else "external_setup_required",
            commercial_release_safe=False,
            summary=profile.summary,
            profile_id=profile.profile_id,
            detail=error_detail,
            bindings=profile.bindings,
        )

    if selected_id == "test-fake-face-runtime":
        return RuntimeSelectionStatus(
            runtime_id=selected_id,
            label="Test fake face runtime",
            status="test_override",
            commercial_release_safe=False,
            summary="Synthetic runtime used only inside automated tests.",
            detail=error_detail,
            bindings=[
                RuntimeBinding(
                    role="embedder",
                    provider="fake-face-runtime",
                    family="test-face-runtime",
                    version="1.0",
                    runtime="test",
                    artifact_format="contract",
                    commercial_release_safe=False,
                    repo_status="test_override",
                    summary="Stable fake runtime for test-only face registration and recognition.",
                )
            ],
        )

    return RuntimeSelectionStatus(
        runtime_id=selected_id,
        label="Unknown face demo runtime",
        status="unknown",
        commercial_release_safe=False,
        summary="The configured face demo runtime is not part of the repo's supported catalog.",
        detail=error_detail or f"Unknown runtime id `{selected_id}`.",
    )
