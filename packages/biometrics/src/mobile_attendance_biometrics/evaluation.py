from __future__ import annotations

from .contracts import BinaryMetricSnapshot, OODScenarioObservation


def compute_binary_metrics(
    scores: list[float], labels: list[int], threshold: float
) -> BinaryMetricSnapshot:
    if len(scores) != len(labels):
        raise ValueError("scores and labels must have equal length")

    attack_total = sum(1 for label in labels if label == 0) or 1
    bona_total = sum(1 for label in labels if label == 1) or 1

    false_accepts = 0
    false_rejects = 0
    correct = 0

    for score, label in zip(scores, labels):
        predicted = 1 if score >= threshold else 0
        if label == 0 and predicted == 1:
            false_accepts += 1
        if label == 1 and predicted == 0:
            false_rejects += 1
        if predicted == label:
            correct += 1

    return BinaryMetricSnapshot(
        threshold=threshold,
        apcer=false_accepts / attack_total,
        bpcer=false_rejects / bona_total,
        accuracy=correct / len(scores) if scores else 0.0,
    )


def default_ood_observations() -> list[OODScenarioObservation]:
    return [
        OODScenarioObservation(
            scenario="low_light",
            risk="high",
            expected_failure_mode="quality degradation drives match volatility and PAD uncertainty",
            mitigation="force step-up capture or flash-assisted recapture before attendance submission",
        ),
        OODScenarioObservation(
            scenario="screen_replay",
            risk="high",
            expected_failure_mode="passive PAD confidence can collapse under high-quality replays",
            mitigation="combine passive PAD with device trust and challenge-response escalation",
        ),
        OODScenarioObservation(
            scenario="motion_blur",
            risk="medium",
            expected_failure_mode="detector confidence and embedding stability degrade together",
            mitigation="quality gate before template comparison and request a re-capture",
        ),
        OODScenarioObservation(
            scenario="gps_mismatch",
            risk="high",
            expected_failure_mode="valid face signal but invalid worksite claim",
            mitigation="reject or review regardless of biometric confidence",
        ),
    ]
