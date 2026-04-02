from __future__ import annotations

from datetime import datetime, timezone
import os
from pathlib import Path

from fastapi.testclient import TestClient

from app.dependencies import get_service
from app.main import create_app
from app.models import AttendanceClaimRequest, DeviceAttestation, EnrollmentSessionCreate, GeoPoint
from app.repository import JsonRepository
from app.security import sign_claim
from app.service import AttendanceService
from mobile_attendance_biometrics import (
    BoundingBox,
    DemoCapturePipeline,
    FaceImageAnalysis,
    ProjectionTemplateProtector,
    ProviderManifest,
    stable_embedding_from_token,
)


def make_service(tmp_path: Path) -> AttendanceService:
    os.environ["MOBILE_ATTENDANCE_LAN_IP"] = "192.168.50.10"
    os.environ["MOBILE_ATTENDANCE_PORT"] = "8000"
    os.environ["MOBILE_ATTENDANCE_BIND_HOST"] = "0.0.0.0"
    repository = JsonRepository(tmp_path / "runtime/store.json")
    protector = ProjectionTemplateProtector(secret="test-secret-2026")
    capture_pipeline = DemoCapturePipeline(profile_id="public-prod-safe-mobile-2026-03-28")
    bootstrap_path = Path(__file__).resolve().parents[3] / "data/demo/bootstrap.json"
    return AttendanceService(
        repository,
        protector,
        capture_pipeline,
        bootstrap_path,
        capture_profile_id="public-prod-safe-mobile-2026-03-28",
        face_runtime_id="disabled",
    )


def make_client(tmp_path: Path) -> tuple[TestClient, AttendanceService]:
    service = make_service(tmp_path)
    app = create_app()
    app.dependency_overrides[get_service] = lambda: service
    return TestClient(app), service


class FakeFaceRuntime:
    def analyze(self, image_base64: str) -> FaceImageAnalysis:
        marker = image_base64.lower()
        identity = "unknown"
        if "studentone" in marker:
            identity = "studentone"
        elif "studenttwo" in marker:
            identity = "studenttwo"
        elif "studentthree" in marker:
            identity = "studentthree"
        return FaceImageAnalysis(
            embedding_vector=stable_embedding_from_token(identity),
            quality_score=0.96,
            detection_score=0.98,
            bbox=BoundingBox(x=120.0, y=80.0, width=220.0, height=260.0, confidence=0.98),
            image_width=640,
            image_height=480,
            detected_face_count=2,
            manifests=[
                ProviderManifest(
                    provider="fake-face-runtime",
                    family="test-face-runtime",
                    version="1.0",
                    runtime="test",
                )
            ],
        )


def signed_claim(service: AttendanceService, **overrides) -> dict:
    payload = {
        "tenant_id": "truepresence-demo",
        "person_id": "student-one",
        "site_id": "classroom-a",
        "claimed_identity_mode": "1:1",
        "client_timestamp": datetime(2026, 3, 28, 9, 0, tzinfo=timezone.utc).isoformat(),
        "gps": {
            "latitude": 31.2305,
            "longitude": 121.4738,
            "accuracy_m": 15.0,
            "is_mocked": False,
        },
        "device_attestation": {
            "provider": "demo-attestation",
            "token": "ok",
            "secure_enclave_backed": True,
            "is_trusted": True,
            "device_id": "ios-demo-1",
        },
        "app_version": "1.0.0",
        "capture_token": "E1001",
        "optional_evidence_ref": "encrypted://evidence/1",
    }
    payload.update(overrides)
    claim = AttendanceClaimRequest.model_validate(
        {
            **payload,
            "request_signature": "placeholder",
        }
    )
    payload["request_signature"] = sign_claim(claim, service.get_tenant("truepresence-demo"))
    return payload


def test_enrollment_flow_stores_protected_templates_only(tmp_path: Path) -> None:
    client, service = make_client(tmp_path)

    person = client.post(
        "/v1/people",
        json={
            "tenant_id": "truepresence-demo",
            "employee_code": "E2001",
            "display_name": "Student Three",
            "site_ids": ["classroom-a"],
        },
    ).json()
    session = client.post(
        "/v1/enrollment/sessions",
        json={
            "tenant_id": "truepresence-demo",
            "person_id": person["id"],
            "consent_reference": "consent-v1",
            "retention_approved": True,
        },
    ).json()
    capture = client.post(
        f"/v1/enrollment/sessions/{session['id']}/captures",
        json={
            "capture_token": None,
            "embedding_vector": None,
            "protected_template": service.protector.protect(
                stable_embedding_from_token("E2001")
            ).model_dump(mode="json"),
            "device_model": "iPhone 17 Pro",
        },
    ).json()
    assert "protected_template" in capture
    assert "embedding_vector" not in capture

    finalized = client.post(f"/v1/enrollment/sessions/{session['id']}/finalize").json()
    assert finalized["templates_created"] == 1

    state = service.repository.snapshot()
    stored_template = next(iter(state.templates.values()))
    assert "protected_template" in stored_template
    assert "embedding_vector" not in stored_template


def test_accepts_valid_onsite_claim(tmp_path: Path) -> None:
    client, service = make_client(tmp_path)
    response = client.post("/v1/attendance/claims", json=signed_claim(service))
    body = response.json()
    assert response.status_code == 200
    assert body["accepted"] is True
    assert body["reason_code"] == "accepted"
    assert body["geofence_result"] == "pass"
    assert body["decision_origin"] == "server"


def test_accepts_protected_template_claim_without_raw_embedding(tmp_path: Path) -> None:
    client, service = make_client(tmp_path)
    protected = service.protector.protect(stable_embedding_from_token("E1001"))
    response = client.post(
        "/v1/attendance/claims",
        json=signed_claim(
            service,
            capture_token=None,
            embedding_vector=None,
            protected_template=protected.model_dump(mode="json"),
        ),
    )
    body = response.json()
    assert response.status_code == 200
    assert body["accepted"] is True
    assert body["matched_person_id"] == "student-one"


def test_accepts_ios_claim_with_face_image_when_demo_runtime_is_disabled(tmp_path: Path) -> None:
    client, service = make_client(tmp_path)
    protected = service.protector.protect(stable_embedding_from_token("E1001"))
    response = client.post(
        "/v1/attendance/claims",
        json=signed_claim(
            service,
            capture_token="ios-live-e1001",
            embedding_vector=None,
            protected_template=protected.model_dump(mode="json"),
            face_image_base64="data:image/jpeg;base64,ios_live_verify_frame",
            optional_evidence_ref=None,
        ),
    )
    body = response.json()

    assert response.status_code == 200
    assert body["accepted"] is True
    assert body["matched_person_id"] == "student-one"


def test_attendance_window_uses_tenant_local_time(tmp_path: Path) -> None:
    client, service = make_client(tmp_path)
    response = client.post(
        "/v1/attendance/claims",
        json=signed_claim(
            service,
            client_timestamp=datetime(2026, 3, 28, 23, 0, tzinfo=timezone.utc).isoformat(),
        ),
    )
    body = response.json()
    assert response.status_code == 200
    assert body["accepted"] is True
    assert body["reason_code"] == "accepted"


def test_rejects_offsite_claim(tmp_path: Path) -> None:
    client, service = make_client(tmp_path)
    response = client.post(
        "/v1/attendance/claims",
        json=signed_claim(
            service,
            gps={
                "latitude": 40.7128,
                "longitude": -74.0060,
                "accuracy_m": 10.0,
                "is_mocked": False,
            },
        ),
    )
    assert response.json()["reason_code"] == "outside_geofence"


def test_step_up_for_low_liveness_and_review_resolution(tmp_path: Path) -> None:
    client, service = make_client(tmp_path)
    response = client.post(
        "/v1/attendance/claims",
        json=signed_claim(service, capture_token="E1001-spoof"),
    )
    body = response.json()
    assert body["accepted"] is False
    assert body["step_up_required"] is True
    assert body["review_ticket"] is not None

    resolved = client.post(
        f"/v1/review-tickets/{body['review_ticket']}/resolve",
        json={"resolution": "manual_override_after_supervisor_review"},
    ).json()
    assert resolved["status"] == "resolved"


def test_export_contains_attendance_rows(tmp_path: Path) -> None:
    client, service = make_client(tmp_path)
    client.post("/v1/attendance/claims", json=signed_claim(service))
    export = client.get("/v1/attendance/export.csv")
    assert export.status_code == 200
    assert "event_id,tenant_id,person_id" in export.text
    assert "truepresence-demo" in export.text


def test_method_stack_reports_latest_profile(tmp_path: Path) -> None:
    client, _ = make_client(tmp_path)
    response = client.get("/v1/method-stack")
    body = response.json()
    assert response.status_code == 200
    assert body["method_stack"]["profile_id"] == "mobile-attendance-2026-03-28"
    component_names = [component["name"] for component in body["method_stack"]["components"]]
    assert "FaceLiVT" in component_names
    assert "M3FAS" in component_names
    assert body["capture_profile"]["profile_id"] == "public-prod-safe-mobile-2026-03-28"
    assert body["capture_profile"]["commercial_release_safe"] is True
    profile_ids = [profile["profile_id"] for profile in body["deployment_profiles"]]
    assert "public-prod-safe-server-1n-2026-03-28" in profile_ids
    assert "laptop-demo-insightface-2026-03-28" in profile_ids
    assert body["face_demo_runtime"]["runtime_id"] == "disabled"
    assert body["face_demo_runtime"]["status"] == "disabled"


def test_mobile_bootstrap_returns_tenant_people_sites_and_runtime(tmp_path: Path) -> None:
    client, _ = make_client(tmp_path)
    response = client.get("/v1/mobile/bootstrap", params={"tenant_id": "truepresence-demo"})
    body = response.json()

    assert response.status_code == 200
    assert body["tenant"]["id"] == "truepresence-demo"
    assert "api_secret" not in body["tenant"]
    assert body["policy"]["thresholds"]["min_quality_score"] == 0.35
    assert [person["id"] for person in body["people"]] == ["student-one", "student-two"]
    assert [site["id"] for site in body["sites"]] == ["classroom-a", "classroom-b"]
    assert body["method_stack"]["profile_id"] == "mobile-attendance-2026-03-28"
    assert body["capture_profile"]["profile_id"] == "public-prod-safe-mobile-2026-03-28"
    assert body["linked_person"] is None
    assert body["active_class_session"] is None
    assert body["live_person"] is None
    assert body["live_site"] is None
    assert body["wifi_ipv4"] == "192.168.50.10"
    assert body["canonical_lan_url"] == "http://192.168.50.10:8000"
    assert body["backend_bind_host"] == "0.0.0.0"
    assert body["lan_ready"] is True
    assert body["server_time"]


def test_binding_token_claim_and_class_session_flow_extend_mobile_bootstrap(tmp_path: Path) -> None:
    client, _ = make_client(tmp_path)
    person = client.post(
        "/v1/demo/control/people",
        json={"tenant_id": "truepresence-demo", "display_name": "Student One"},
    ).json()
    session = client.post(
        "/v1/demo/control/class-session/start",
        json={
            "tenant_id": "truepresence-demo",
            "site_id": "classroom-a",
            "class_label": "Math 101",
        },
    )
    session_body = session.json()
    assert session.status_code == 200
    assert session_body["active_class_session"]["site_id"] == "classroom-a"
    assert session_body["active_class_session"]["class_label"] == "Math 101"

    token_response = client.post(
        f"/v1/demo/control/people/{person['id']}/binding-token",
        params={"tenant_id": "truepresence-demo"},
    )
    token_body = token_response.json()
    assert token_response.status_code == 200
    assert token_body["person"]["id"] == person["id"]
    assert token_body["token"].startswith("bind_")
    assert token_body["qr_payload"].startswith("{\"type\":\"truepresence-binding\"")

    claimed = client.post(
        "/v1/mobile/device-link/claim",
        json={
            "token": token_body["qr_payload"],
            "device_attestation": {
                "provider": "real_app_attest",
                "token": "claim-token",
                "secure_enclave_backed": True,
                "is_trusted": True,
                "device_id": "student-device-1",
            },
        },
    )
    claimed_body = claimed.json()
    assert claimed.status_code == 200
    assert claimed_body["linked_person"]["id"] == person["id"]
    assert claimed_body["bootstrap"]["linked_person"]["id"] == person["id"]
    assert claimed_body["bootstrap"]["active_class_session"]["class_label"] == "Math 101"

    bootstrap = client.get(
        "/v1/mobile/bootstrap",
        params={"tenant_id": "truepresence-demo", "device_id": "student-device-1"},
    )
    bootstrap_body = bootstrap.json()
    assert bootstrap.status_code == 200
    assert bootstrap_body["linked_person"]["id"] == person["id"]
    assert bootstrap_body["active_class_session"]["site_id"] == "classroom-a"

    cleared = client.post(
        "/v1/mobile/device-link/clear",
        json={
            "tenant_id": "truepresence-demo",
            "device_attestation": {
                "provider": "real_app_attest",
                "token": "claim-token",
                "secure_enclave_backed": True,
                "is_trusted": True,
                "device_id": "student-device-1",
            },
        },
    )
    cleared_body = cleared.json()
    assert cleared.status_code == 200
    assert cleared_body["cleared"] is True
    assert cleared_body["device_id"] == "student-device-1"

    bootstrap_after_clear = client.get(
        "/v1/mobile/bootstrap",
        params={"tenant_id": "truepresence-demo", "device_id": "student-device-1"},
    )
    assert bootstrap_after_clear.status_code == 200
    assert bootstrap_after_clear.json()["linked_person"] is None


def test_mobile_demo_session_start_binds_existing_demo_person_and_current_site(tmp_path: Path) -> None:
    client, _ = make_client(tmp_path)
    person = client.post(
        "/v1/demo/control/people",
        json={"tenant_id": "truepresence-demo", "display_name": "Teacher Added Student"},
    ).json()
    response = client.post(
        "/v1/mobile/demo-session/start",
        json={
            "tenant_id": "truepresence-demo",
            "person_id": person["id"],
            "gps": {
                "latitude": 31.2305,
                "longitude": 121.4738,
                "accuracy_m": 12.0,
                "is_mocked": False,
            },
        },
    )
    body = response.json()

    assert response.status_code == 200
    assert body["session_mode"] == "server_live_demo"
    assert body["person"]["id"] == person["id"]
    assert body["person"]["display_name"] == "Teacher Added Student"
    assert body["person"]["employee_code"].startswith("D")
    assert body["site"]["label"] == "Teacher Added Student Classroom Site"
    assert body["site"]["tenant_id"] == "truepresence-demo"
    assert body["bootstrap"]["people"][-1]["id"] == body["person"]["id"]
    assert body["bootstrap"]["sites"][-1]["id"] == body["site"]["id"]
    assert body["bootstrap"]["live_person"]["id"] == body["person"]["id"]
    assert body["bootstrap"]["live_site"]["id"] == body["site"]["id"]


def test_mobile_demo_session_start_rejects_display_name_only_payload(tmp_path: Path) -> None:
    client, _ = make_client(tmp_path)
    response = client.post(
        "/v1/mobile/demo-session/start",
        json={
            "tenant_id": "truepresence-demo",
            "display_name": "Teacher Added Student",
            "gps": {
                "latitude": 31.2305,
                "longitude": 121.4738,
                "accuracy_m": 12.0,
                "is_mocked": False,
            },
        },
    )

    assert response.status_code == 422

    people = client.get("/v1/demo/control/people", params={"tenant_id": "truepresence-demo"}).json()
    assert [person["id"] for person in people] == ["student-one", "student-two"]


def test_mobile_bootstrap_accepts_malformed_encoded_query_path(tmp_path: Path) -> None:
    client, _ = make_client(tmp_path)
    response = client.get("/v1/mobile/bootstrap%3Ftenant_id=truepresence-demo")
    body = response.json()

    assert response.status_code == 200
    assert body["tenant"]["id"] == "truepresence-demo"


def test_demo_control_reset_restores_default_policy_thresholds(tmp_path: Path) -> None:
    client, service = make_client(tmp_path)
    tenant = service.get_tenant("truepresence-demo")
    tenant.policy.thresholds.min_quality_score = 0.72
    tenant.policy.thresholds.min_match_score = 0.84
    tenant.policy.thresholds.review_match_floor = 0.78
    service.repository.save()

    response = client.post("/v1/demo/control/reset")
    assert response.status_code == 200

    refreshed = service.get_tenant("truepresence-demo")
    assert refreshed.policy.thresholds.min_quality_score == 0.35
    assert refreshed.policy.thresholds.min_match_score == 0.80
    assert refreshed.policy.thresholds.review_match_floor == 0.74


def test_attendance_events_support_mobile_filters(tmp_path: Path) -> None:
    client, service = make_client(tmp_path)
    client.post("/v1/attendance/claims", json=signed_claim(service))
    client.post(
        "/v1/attendance/claims",
        json=signed_claim(
            service,
            person_id="student-two",
            site_id="classroom-b",
            gps={
                "latitude": 22.5432,
                "longitude": 114.0580,
                "accuracy_m": 12.0,
                "is_mocked": False,
            },
            capture_token="E1002",
        ),
    )

    filtered = client.get(
        "/v1/attendance/events",
        params={
            "tenant_id": "truepresence-demo",
            "person_id": "student-two",
            "limit": 1,
        },
    )
    body = filtered.json()

    assert filtered.status_code == 200
    assert len(body) == 1
    assert body[0]["person_id"] == "student-two"
    assert body[0]["site_id"] == "classroom-b"
    assert body[0]["decision_origin"] == "server"
    assert body[0]["claim_source"] == "server_live"


def test_attendance_claim_source_is_persisted(tmp_path: Path) -> None:
    client, service = make_client(tmp_path)
    response = client.post(
        "/v1/attendance/claims",
        json=signed_claim(service, claim_source="local_demo_replay"),
    )
    body = response.json()
    assert response.status_code == 200
    assert body["decision_origin"] == "server"

    events = client.get("/v1/attendance/events", params={"tenant_id": "truepresence-demo"}).json()
    assert events[0]["claim_source"] == "local_demo_replay"


def test_attendance_events_accept_malformed_encoded_query_path(tmp_path: Path) -> None:
    client, service = make_client(tmp_path)
    client.post("/v1/attendance/claims", json=signed_claim(service))

    response = client.get(
        "/v1/attendance/events%3Ftenant_id=truepresence-demo%26person_id=student-one%26limit=20"
    )
    body = response.json()

    assert response.status_code == 200
    assert len(body) == 1
    assert body[0]["tenant_id"] == "truepresence-demo"
    assert body[0]["person_id"] == "student-one"


def test_demo_face_registration_and_recognition(tmp_path: Path) -> None:
    client, service = make_client(tmp_path)
    service.face_runtime = FakeFaceRuntime()
    service.face_runtime_error = None
    service.face_runtime_id = "test-fake-face-runtime"

    registered = client.post(
        "/v1/demo/faces/register",
        json={
            "tenant_id": "truepresence-demo",
            "display_name": "Reference Student",
            "linked_person_id": "student-two",
            "image_base64": "data:image/jpeg;base64,studentone_1",
        },
    )
    registered_body = registered.json()
    assert registered.status_code == 200
    assert registered_body["display_name"] == "Reference Student"
    assert registered_body["linked_person_id"] == "student-two"
    assert registered_body["linked_person_name"] == "Student Two"
    assert registered_body["bbox"]["height"] == 260.0
    assert registered_body["detected_face_count"] == 2
    assert "protected_template" not in registered_body

    listing = client.get("/v1/demo/faces?tenant_id=truepresence-demo")
    listing_body = listing.json()
    assert listing.status_code == 200
    assert len(listing_body) == 1

    recognized = client.post(
        "/v1/demo/faces/recognize",
        json={
            "tenant_id": "truepresence-demo",
            "image_base64": "data:image/jpeg;base64,studentone_2",
            "threshold": 0.6,
        },
    )
    recognized_body = recognized.json()
    assert recognized.status_code == 200
    assert recognized_body["matched"] is True
    assert recognized_body["matched_name"] == "Reference Student"
    assert recognized_body["matched_person_id"] == "student-two"
    assert recognized_body["matched_person_name"] == "Student Two"
    assert recognized_body["bbox"]["width"] == 220.0
    assert recognized_body["image_width"] == 640
    assert recognized_body["image_height"] == 480
    assert recognized_body["detected_face_count"] == 2


def test_demo_control_session_mac_enrollment_and_snapshot(tmp_path: Path) -> None:
    client, service = make_client(tmp_path)
    service.face_runtime = FakeFaceRuntime()
    service.face_runtime_error = None
    service.face_runtime_id = "test-fake-face-runtime"
    person = client.post(
        "/v1/demo/control/people",
        json={"tenant_id": "truepresence-demo", "display_name": "Teacher Added Student"},
    ).json()

    started = client.post(
        "/v1/demo/control/session/start",
        json={
            "tenant_id": "truepresence-demo",
            "person_id": person["id"],
            "gps": {
                "latitude": 31.2305,
                "longitude": 121.4738,
                "accuracy_m": 8.0,
                "is_mocked": False,
            },
        },
    )
    started_body = started.json()
    assert started.status_code == 200
    person_id = started_body["person"]["id"]

    enrolled = client.post(
        "/v1/demo/control/enroll-from-mac",
        json={
            "tenant_id": "truepresence-demo",
            "person_id": person_id,
            "image_base64": "data:image/jpeg;base64,studentone_mac_enroll",
        },
    )
    enrolled_body = enrolled.json()
    assert enrolled.status_code == 200
    assert enrolled_body["template_scheme"] == "signed-random-projection-v1"
    assert enrolled_body["template_count"] == 1
    assert enrolled_body["capture_id"] is not None
    assert enrolled_body["quality_score"] == 0.96
    assert enrolled_body["detected_face_count"] == 2

    snapshot = client.get("/v1/demo/control/snapshot", params={"tenant_id": "truepresence-demo"})
    snapshot_body = snapshot.json()
    assert snapshot.status_code == 200
    assert snapshot_body["live_person"]["id"] == person_id
    assert snapshot_body["live_site"]["id"] == started_body["site"]["id"]
    assert snapshot_body["live_session"]["last_mac_enrollment_at"] is not None
    assert snapshot_body["live_session"]["last_mac_quality_score"] == 0.96
    assert snapshot_body["wifi_ipv4"] == "192.168.50.10"
    assert snapshot_body["canonical_lan_url"] == "http://192.168.50.10:8000"
    assert snapshot_body["backend_bind_host"] == "0.0.0.0"
    assert snapshot_body["lan_ready"] is True
    assert snapshot_body["face_demo_runtime"]["runtime_id"] == "test-fake-face-runtime"
    assert len(snapshot_body["people_summary"]) >= 3
    assert snapshot_body["template_summary"][0]["person_id"] == person_id
    assert snapshot_body["capture_summary"][0]["person_id"] == person_id

    capture_path = Path(snapshot_body["capture_summary"][0]["file_path"])
    assert capture_path.exists()

    capture_image = client.get(f"/v1/demo/control/captures/{enrolled_body['capture_id']}/image")
    assert capture_image.status_code == 200
    assert capture_image.headers["content-type"].startswith("image/jpeg")

    reset = client.post("/v1/demo/control/reset", params={"tenant_id": "truepresence-demo"})
    reset_body = reset.json()
    assert reset.status_code == 200
    assert reset_body["cleared_demo_person_count"] == 1
    assert reset_body["cleared_demo_site_count"] == 1
    assert reset_body["cleared_template_count"] == 1


def test_demo_control_session_start_requires_selected_demo_person(tmp_path: Path) -> None:
    client, _ = make_client(tmp_path)
    started = client.post(
        "/v1/demo/control/session/start",
        json={
            "tenant_id": "truepresence-demo",
            "gps": {
                "latitude": 31.2305,
                "longitude": 121.4738,
                "accuracy_m": 8.0,
                "is_mocked": False,
            },
        },
    )

    assert started.status_code == 422


def test_demo_control_people_crud_and_event_clear(tmp_path: Path) -> None:
    client, service = make_client(tmp_path)
    service.face_runtime = FakeFaceRuntime()
    service.face_runtime_error = None
    service.face_runtime_id = "test-fake-face-runtime"

    created = client.post(
        "/v1/demo/control/people",
        json={"tenant_id": "truepresence-demo", "display_name": "Realtime Student"},
    )
    created_body = created.json()
    assert created.status_code == 200
    assert created_body["id"].startswith("demo-person-")

    people = client.get("/v1/demo/control/people", params={"tenant_id": "truepresence-demo"}).json()
    demo_people = [person for person in people if person["person_kind"] == "demo"]
    assert any(person["id"] == created_body["id"] for person in demo_people)

    seeded_delete = client.delete(
        "/v1/demo/control/people/student-one",
        params={"tenant_id": "truepresence-demo"},
    )
    assert seeded_delete.status_code == 400

    session = client.post(
        "/v1/demo/control/session/start",
        json={
            "tenant_id": "truepresence-demo",
            "person_id": created_body["id"],
            "gps": {
                "latitude": 31.2305,
                "longitude": 121.4738,
                "accuracy_m": 6.0,
                "is_mocked": False,
            },
        },
    ).json()
    site_id = session["site"]["id"]

    client.post(
        "/v1/demo/control/enroll-from-mac",
        json={
            "tenant_id": "truepresence-demo",
            "person_id": created_body["id"],
            "image_base64": "data:image/jpeg;base64,studentone_mac_enroll",
            "source": "mac_upload",
            "shot_index": 1,
            "shot_role": "upload",
        },
    )
    client.post(
        "/v1/attendance/claims",
        json=signed_claim(
            service,
            person_id=created_body["id"],
            site_id=site_id,
            app_version="ios-student-1.0",
            claim_source="server_live",
            capture_token="ios-live-studentone",
            face_image_base64="data:image/jpeg;base64,studentone_live_verify",
            protected_template=None,
            optional_evidence_ref=None,
            gps={
                "latitude": 31.2305,
                "longitude": 121.4738,
                "accuracy_m": 6.0,
                "is_mocked": False,
            },
        ),
    )

    cleared = client.post("/v1/demo/control/events/clear", params={"tenant_id": "truepresence-demo"}).json()
    assert cleared["cleared_event_count"] == 1

    deleted = client.delete(
        f"/v1/demo/control/people/{created_body['id']}",
        params={"tenant_id": "truepresence-demo"},
    )
    deleted_body = deleted.json()
    assert deleted.status_code == 200
    assert deleted_body["removed_template_count"] == 1
    assert deleted_body["removed_capture_count"] >= 1


def test_lan_realtime_claim_accepts_server_live_face_image_without_review(tmp_path: Path) -> None:
    client, service = make_client(tmp_path)
    service.face_runtime = FakeFaceRuntime()
    service.face_runtime_error = None
    service.face_runtime_id = "test-fake-face-runtime"
    person = client.post(
        "/v1/demo/control/people",
        json={"tenant_id": "truepresence-demo", "display_name": "Teacher Added Student"},
    ).json()

    session = client.post(
        "/v1/demo/control/session/start",
        json={
            "tenant_id": "truepresence-demo",
            "person_id": person["id"],
            "gps": {
                "latitude": 31.2305,
                "longitude": 121.4738,
                "accuracy_m": 8.0,
                "is_mocked": False,
            },
        },
    ).json()
    person_id = session["person"]["id"]
    site_id = session["site"]["id"]

    enroll = client.post(
        "/v1/demo/control/enroll-from-mac",
        json={
            "tenant_id": "truepresence-demo",
            "person_id": person_id,
            "image_base64": "data:image/jpeg;base64,studentone_mac_enroll",
        },
    )
    assert enroll.status_code == 200

    claim_response = client.post(
        "/v1/attendance/claims",
        json=signed_claim(
            service,
            person_id=person_id,
            site_id=site_id,
            app_version="ios-student-1.0",
            claim_source="server_live",
            capture_token="ios-live-studentone",
            face_image_base64="data:image/jpeg;base64,studentone_live_verify",
            protected_template=None,
            optional_evidence_ref=None,
            gps={
                "latitude": 31.2305,
                "longitude": 121.4738,
                "accuracy_m": 6.0,
                "is_mocked": False,
            },
        ),
    )
    claim_body = claim_response.json()

    assert claim_response.status_code == 200
    assert claim_body["accepted"] is True
    assert claim_body["reason_code"] == "accepted"
    assert claim_body["review_ticket"] is None
    assert claim_body["decision_origin"] == "server"
    assert claim_body["matched_person_id"] == person_id

    events = client.get("/v1/attendance/events", params={"tenant_id": "truepresence-demo"}).json()
    assert events[0]["person_id"] == person_id
    assert events[0]["site_id"] == site_id
    assert events[0]["decision_origin"] == "server"
    assert events[0]["claim_source"] == "server_live"
    assert events[0]["capture_id"] is not None
    assert events[0]["capture_file_path"] is not None


def test_lan_realtime_active_demo_claim_ignores_formal_attendance_window(tmp_path: Path) -> None:
    client, service = make_client(tmp_path)
    service.face_runtime = FakeFaceRuntime()
    service.face_runtime_error = None
    service.face_runtime_id = "test-fake-face-runtime"

    person = client.post(
        "/v1/demo/control/people",
        json={"tenant_id": "truepresence-demo", "display_name": "Reference Student"},
    ).json()
    session = client.post(
        "/v1/demo/control/session/start",
        json={
            "tenant_id": "truepresence-demo",
            "person_id": person["id"],
            "gps": {
                "latitude": 31.2305,
                "longitude": 121.4738,
                "accuracy_m": 8.0,
                "is_mocked": False,
            },
        },
    ).json()
    person_id = session["person"]["id"]
    site_id = session["site"]["id"]

    enroll = client.post(
        "/v1/demo/control/enroll-from-mac",
        json={
            "tenant_id": "truepresence-demo",
            "person_id": person_id,
            "image_base64": "data:image/jpeg;base64,studentone_mac_enroll",
        },
    )
    assert enroll.status_code == 200

    response = client.post(
        "/v1/attendance/claims",
        json=signed_claim(
            service,
            person_id=person_id,
            site_id=site_id,
            app_version="ios-student-1.0",
            claim_source="server_live",
            face_image_base64="data:image/jpeg;base64,studentone_live_verify",
            protected_template=None,
            optional_evidence_ref=None,
            client_timestamp=datetime(2026, 4, 1, 15, 45, tzinfo=timezone.utc).isoformat(),
            gps={
                "latitude": 31.2305,
                "longitude": 121.4738,
                "accuracy_m": 6.0,
                "is_mocked": False,
            },
        ),
    )
    body = response.json()

    assert response.status_code == 200
    assert body["accepted"] is True
    assert body["reason_code"] == "accepted"
    assert body["decision_origin"] == "server"
