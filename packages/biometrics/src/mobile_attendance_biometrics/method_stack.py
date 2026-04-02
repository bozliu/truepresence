from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class MethodComponent(BaseModel):
    role: Literal[
        "detector",
        "embedder",
        "liveness",
        "step_up",
        "template_protection",
        "evaluation",
        "training_guidance",
    ]
    name: str
    status: Literal["production_baseline", "latest_candidate", "evaluation_anchor", "guidance"]
    selected_on: str
    paper_date: str | None = None
    rationale: str
    source_url: str


class MethodStackProfile(BaseModel):
    profile_id: str
    effective_date: str
    summary: str
    components: list[MethodComponent] = Field(default_factory=list)


def latest_method_stack_profile() -> MethodStackProfile:
    return MethodStackProfile(
        profile_id="mobile-attendance-2026-03-28",
        effective_date="2026-03-28",
        summary=(
            "Latest repo method profile for the mobile attendance blueprint as of March 28, 2026. "
            "Uses SCRFD-class detection, FaceLiVT-oriented mobile face recognition, a ViT-based passive "
            "RGB PAD path with M3FAS step-up, and protected templates aligned to FaceCloak and IDFace."
        ),
        components=[
            MethodComponent(
                role="detector",
                name="SCRFD-class detector and aligner",
                status="production_baseline",
                selected_on="2026-03-28",
                rationale=(
                    "Kept as the production detector baseline because it remains the practical edge/mobile "
                    "choice and was not clearly displaced by a better commercial-ready detector in 2024-2026."
                ),
                source_url="https://github.com/deepinsight/insightface",
            ),
            MethodComponent(
                role="embedder",
                name="FaceLiVT",
                status="latest_candidate",
                selected_on="2026-03-28",
                paper_date="2025-06-12",
                rationale=(
                    "Promoted ahead of EdgeFace for the repo's latest mobile-recognition profile because it "
                    "targets mobile devices directly and reports faster inference than EdgeFace while staying "
                    "in the lightweight face-recognition regime."
                ),
                source_url="https://arxiv.org/abs/2506.10361",
            ),
            MethodComponent(
                role="liveness",
                name="Intermediate-Feature ViT-PAD",
                status="latest_candidate",
                selected_on="2026-03-28",
                paper_date="2025-05-30",
                rationale=(
                    "Selected as the passive liveness direction because recent 2025 work shows stronger spoof "
                    "generalization by using intermediate ViT features plus spoof-specific augmentation, which "
                    "fits a front-camera mobile attendance flow better than relying on older static RGB baselines."
                ),
                source_url="https://arxiv.org/abs/2505.24402",
            ),
            MethodComponent(
                role="step_up",
                name="M3FAS",
                status="latest_candidate",
                selected_on="2026-03-28",
                paper_date="2024-03-21",
                rationale=(
                    "Used as the active step-up path on supported phones because it combines camera, speaker, "
                    "and microphone on commodity devices, which is well suited to higher-risk mobile attendance "
                    "checks when passive RGB liveness is not enough."
                ),
                source_url="https://arxiv.org/abs/2301.12831",
            ),
            MethodComponent(
                role="template_protection",
                name="FaceCloak / IDFace",
                status="latest_candidate",
                selected_on="2026-03-28",
                paper_date="2025-04-08",
                rationale=(
                    "Updated to a split strategy: FaceCloak is the lightweight default for 1:1 verification "
                    "and renewable protected templates, while IDFace remains the encrypted 1:N server-side "
                    "anchor when large-scale identification is required."
                ),
                source_url="https://arxiv.org/abs/2504.06131",
            ),
            MethodComponent(
                role="evaluation",
                name="OODFace",
                status="evaluation_anchor",
                selected_on="2026-03-28",
                paper_date="2024-12-03",
                rationale=(
                    "Used to drive OOD-style robustness expectations for blur, low light, replay, and "
                    "appearance variation instead of evaluating only on clean captures."
                ),
                source_url="https://arxiv.org/abs/2412.02479",
            ),
            MethodComponent(
                role="training_guidance",
                name="LVFace + LAFS + FSFM",
                status="guidance",
                selected_on="2026-03-28",
                paper_date="2025-01-23",
                rationale=(
                    "Retained as training-time guidance: LVFace improves large-ViT face recognition training, "
                    "LAFS improves unlabeled facial representation learning, and FSFM improves generalizable "
                    "face-security pretraining without forcing these heavier models into on-device inference."
                ),
                source_url="https://arxiv.org/abs/2501.13420",
            ),
        ],
    )
