from __future__ import annotations

import base64
import binascii
import csv
import io
import json
import math
import os
import re
import socket
import subprocess
from datetime import timedelta
from pathlib import Path
from typing import TYPE_CHECKING, Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from mobile_attendance_biometrics import (
    DEFAULT_DEMO_FACE_RUNTIME_ID,
    DemoCapturePipeline,
    ProjectionTemplateProtector,
    default_capture_profile_id,
    demo_face_runtime_status,
    deployment_profiles,
    get_deployment_profile,
)
from mobile_attendance_biometrics.contracts import ProtectedTemplate
from mobile_attendance_biometrics.method_stack import latest_method_stack_profile

from .models import (
    ActiveClassSession,
    AdminOverview,
    AttendanceClaimRequest,
    AttendanceDecision,
    AttendanceEvent,
    ClassSessionStartRequest,
    ClassSessionStartResponse,
    ClassSessionStopResponse,
    DemoCaptureRecord,
    DemoControlEnrollmentResponse,
    DemoControlEnrollFromMacRequest,
    DemoControlPersonCreateRequest,
    DemoControlPersonSummary,
    DemoControlResetResponse,
    DemoControlSession,
    DemoControlSessionStartResponse,
    DemoControlSnapshot,
    DemoTemplateSummary,
    DemoFaceRecognitionRequest,
    DemoFaceRecognitionResponse,
    DemoFaceRecord,
    DemoFaceRegisterRequest,
    DemoSessionStartRequest,
    DemoSessionStartResponse,
    DeviceBindingToken,
    DeviceBindingTokenResponse,
    DeviceLink,
    DeviceLinkClearRequest,
    DeviceLinkClearResponse,
    DeviceLinkClaimRequest,
    DeviceLinkClaimResponse,
    EnrollmentCaptureRecord,
    EnrollmentCaptureRequest,
    EnrollmentFinalizeResponse,
    EnrollmentSession,
    EnrollmentSessionCreate,
    MobileBootstrapTenant,
    MobileBootstrapResponse,
    Person,
    PersonCreateRequest,
    RepositoryState,
    ReviewResolutionRequest,
    ReviewTicket,
    RuntimeProfileResponse,
    Tenant,
    TenantPolicy,
    WorkSite,
    new_id,
    utc_now,
)
from .repository import JsonRepository
from .security import verify_claim_signature

if TYPE_CHECKING:
    from mobile_attendance_biometrics.image_runtime import InsightFaceImageRuntime


def haversine_meters(lat_a: float, lon_a: float, lat_b: float, lon_b: float) -> float:
    radius = 6371000
    phi_a = math.radians(lat_a)
    phi_b = math.radians(lat_b)
    delta_phi = math.radians(lat_b - lat_a)
    delta_lambda = math.radians(lon_b - lon_a)
    root = (
        math.sin(delta_phi / 2) ** 2
        + math.cos(phi_a) * math.cos(phi_b) * math.sin(delta_lambda / 2) ** 2
    )
    return 2 * radius * math.atan2(math.sqrt(root), math.sqrt(1 - root))


def slugify(value: str) -> str:
    lowered = value.strip().lower()
    cleaned = re.sub(r"[^a-z0-9]+", "-", lowered)
    return cleaned.strip("-") or "student"


def decode_base64_image(value: str) -> bytes:
    if "," in value and value.startswith("data:"):
        _, encoded = value.split(",", 1)
    else:
        encoded = value
    try:
        return base64.b64decode(encoded, validate=False)
    except (binascii.Error, ValueError) as error:
        if encoded:
            return encoded.encode("utf-8")
        raise ValueError("Invalid base64 image payload.") from error


class AttendanceService:
    def __init__(
        self,
        repository: JsonRepository,
        protector: ProjectionTemplateProtector,
        capture_pipeline: DemoCapturePipeline,
        bootstrap_path: Path,
        *,
        capture_profile_id: str | None = None,
        face_runtime_id: str | None = None,
    ) -> None:
        self.repository = repository
        self.protector = protector
        self.capture_pipeline = capture_pipeline
        self.bootstrap_path = bootstrap_path
        self.runtime_data_dir = repository.path.parent
        self.capture_root = self.runtime_data_dir / "captures"
        self.capture_root.mkdir(parents=True, exist_ok=True)
        self.capture_profile = get_deployment_profile(capture_profile_id or default_capture_profile_id())
        self.face_runtime_id = (face_runtime_id or DEFAULT_DEMO_FACE_RUNTIME_ID).strip()
        self.face_runtime_error: str | None = None
        self._stream_revision = 0
        self.face_runtime = self._build_face_runtime(self.face_runtime_id)
        self._bootstrap_if_empty()

    def _backend_bind_host(self) -> str:
        return os.environ.get("MOBILE_ATTENDANCE_BIND_HOST", "0.0.0.0")

    def _backend_port(self) -> int:
        raw = os.environ.get("MOBILE_ATTENDANCE_PORT", "8000")
        try:
            return int(raw)
        except ValueError:
            return 8000

    def _is_viable_lan_ipv4(self, ip_address: str | None) -> bool:
        if not ip_address:
            return False
        if ip_address.startswith("127.") or ip_address.startswith("169.254."):
            return False
        if ip_address.startswith("198.18.") or ip_address.startswith("198.19."):
            return False
        return True

    def _interface_ipv4(self, interface: str) -> str | None:
        try:
            output = subprocess.check_output(
                ["ipconfig", "getifaddr", interface],
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
        except (FileNotFoundError, subprocess.CalledProcessError):
            return None
        return output or None

    def _wifi_ipv4(self) -> str | None:
        configured_ip = os.environ.get("MOBILE_ATTENDANCE_LAN_IP", "").strip()
        if self._is_viable_lan_ipv4(configured_ip):
            return configured_ip

        for interface in ("en0", "en1", "bridge0"):
            interface_ip = self._interface_ipv4(interface)
            if self._is_viable_lan_ipv4(interface_ip):
                return interface_ip

        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
                probe.connect(("8.8.8.8", 80))
                ip_address = probe.getsockname()[0]
                if self._is_viable_lan_ipv4(ip_address):
                    return ip_address
        except OSError:
            pass

        try:
            for family, _, _, _, sockaddr in socket.getaddrinfo(
                socket.gethostname(),
                None,
                socket.AF_INET,
            ):
                if family != socket.AF_INET:
                    continue
                ip_address = sockaddr[0]
                if self._is_viable_lan_ipv4(ip_address):
                    return ip_address
        except OSError:
            pass

        return None

    def _canonical_lan_url(self) -> str | None:
        ip_address = self._wifi_ipv4()
        if ip_address is None:
            return None
        return f"http://{ip_address}:{self._backend_port()}"

    def _lan_ready(self) -> bool:
        return self._canonical_lan_url() is not None

    def _network_hint(self) -> str:
        return (
            "Keep the iPhone and Mac on the same Wi-Fi, use the fixed Wi-Fi IP shown here as the "
            "LAN backend URL, and allow Python/Uvicorn through the Mac firewall."
        )

    def _save(self) -> None:
        self.repository.save()
        self._stream_revision += 1

    def stream_revision(self) -> int:
        return self._stream_revision

    def _active_class_session(self, tenant_id: str) -> ActiveClassSession | None:
        session = self._state().active_class_session
        if session is None or session.tenant_id != tenant_id or session.active is False:
            return None
        return session

    def _linked_person_for_device(self, *, tenant_id: str, device_id: str | None) -> Person | None:
        if not device_id:
            return None
        link = self._state().device_links.get(device_id)
        if link is None or link.tenant_id != tenant_id:
            return None
        return self._state().people.get(link.person_id)

    def _cleanup_binding_tokens(self) -> None:
        state = self._state()
        now = utc_now()
        for token in [
            token
            for token, payload in state.binding_tokens.items()
            if payload.expires_at <= now
        ]:
            state.binding_tokens.pop(token, None)

    def _binding_qr_payload(self, token: str) -> str:
        return json.dumps(
            {
                "type": "truepresence-binding",
                "token": token,
            },
            separators=(",", ":"),
        )

    def _demo_control(self) -> DemoControlSession:
        return self._state().demo_control

    def _mark_mobile_seen(
        self,
        *,
        source: str,
        app_version: str | None = None,
    ) -> None:
        control = self._demo_control()
        control.phone_last_seen_at = utc_now()
        control.phone_last_status_source = source
        if app_version:
            control.phone_last_app_version = app_version
        self._stream_revision += 1

    def _set_demo_control_session(self, person: Person, site: WorkSite) -> None:
        control = self._demo_control()
        control.tenant_id = person.tenant_id
        control.person_id = person.id
        control.site_id = site.id
        control.display_name = person.display_name
        control.started_at = utc_now()
        self._save()

    def _is_direct_lan_demo(self, request: AttendanceClaimRequest) -> bool:
        return request.claim_source == "server_live" and request.app_version.startswith("ios-student")

    def _is_active_live_demo_claim(
        self,
        *,
        request: AttendanceClaimRequest,
        state: RepositoryState,
    ) -> bool:
        control = state.demo_control
        if self._is_direct_lan_demo(request) is False:
            return False
        if not request.person_id:
            return False
        if request.person_id != control.person_id or request.site_id != control.site_id:
            return False
        return request.person_id.startswith("demo-person-") and request.site_id.startswith("demo-site-")

    def _build_face_runtime(self, runtime_id: str) -> "InsightFaceImageRuntime | None":
        if runtime_id in {"disabled", "none"}:
            self.face_runtime_error = (
                "Optional demo face runtime is disabled. Set MOBILE_ATTENDANCE_DEMO_FACE_RUNTIME="
                "insightface-buffalo_l if you want the local laptop face-registry demo."
            )
            return None
        if runtime_id == "test-fake-face-runtime":
            self.face_runtime_error = None
            return None
        if runtime_id != DEFAULT_DEMO_FACE_RUNTIME_ID:
            self.face_runtime_error = f"Unknown demo face runtime `{runtime_id}`."
            return None
        try:
            from mobile_attendance_biometrics.image_runtime import (
                FaceRuntimeUnavailableError,
                InsightFaceImageRuntime,
            )

            return InsightFaceImageRuntime()
        except FaceRuntimeUnavailableError as error:
            self.face_runtime_error = str(error)
            return None

    def _bootstrap_if_empty(self) -> None:
        state = self.repository.snapshot()
        if state.tenants:
            return

        payload = json.loads(self.bootstrap_path.read_text(encoding="utf-8"))
        for tenant_payload in payload["tenants"]:
            state.tenants[tenant_payload["id"]] = Tenant(
                id=tenant_payload["id"],
                name=tenant_payload["name"],
                timezone=tenant_payload["timezone"],
                api_secret=tenant_payload["api_secret"],
                policy=TenantPolicy(),
            )

        for site_payload in payload["sites"]:
            state.sites[site_payload["id"]] = WorkSite(**site_payload)

        for person_payload in payload["people"]:
            person = Person(**person_payload)
            state.people[person.id] = person
            capture = self.capture_pipeline.analyze(capture_token=person.employee_code)
            template = self.protector.protect(capture.embedding_vector)
            template_id = new_id("tmpl")
            state.templates[template_id] = {
                "id": template_id,
                "person_id": person.id,
                "tenant_id": person.tenant_id,
                "capture_digest": template.digest,
                "protected_template": template.model_dump(mode="json"),
                "created_at": utc_now().isoformat(),
                "source": "bootstrap",
            }
            person.template_ids.append(template_id)

            self._save()

    def _state(self) -> RepositoryState:
        return self.repository.snapshot()

    def _person_kind(self, person: Person) -> str:
        return "demo" if person.id.startswith("demo-person-") else "seeded"

    def _capture_directory_for_person(self, person_id: str) -> Path:
        directory = self.capture_root / person_id
        directory.mkdir(parents=True, exist_ok=True)
        return directory

    def _delete_capture_file(self, file_path: str | None) -> None:
        if not file_path:
            return
        path = Path(file_path)
        if path.exists():
            path.unlink()
        parent = path.parent
        if parent != self.capture_root and parent.exists():
            try:
                next(parent.iterdir())
            except StopIteration:
                parent.rmdir()

    def _register_capture_record(
        self,
        *,
        tenant_id: str,
        person: Person | None,
        image_base64: str,
        source: str,
        stage: str,
        sequence_id: str | None = None,
        shot_index: int | None = None,
        shot_role: str | None = None,
        image_width: int | None = None,
        image_height: int | None = None,
        quality_score: float | None = None,
        detection_score: float | None = None,
        liveness_score: float | None = None,
        match_score: float | None = None,
        bbox_confidence: float | None = None,
        depth_present: bool | None = None,
        depth_coverage: float | None = None,
        depth_variance: float | None = None,
        depth_evidence_passed: bool | None = None,
        event_id: str | None = None,
    ) -> DemoCaptureRecord:
        state = self._state()
        capture_id = new_id("cap")
        person_id = person.id if person else "unassigned"
        person_directory = self._capture_directory_for_person(person_id)
        file_path = person_directory / f"{utc_now().strftime('%Y%m%d-%H%M%S')}-{capture_id}.jpg"
        file_path.write_bytes(decode_base64_image(image_base64))
        payload = {
            "id": capture_id,
            "tenant_id": tenant_id,
            "person_id": person.id if person else None,
            "person_display_name": person.display_name if person else None,
            "source": source,
            "stage": stage,
            "file_path": str(file_path),
            "created_at": utc_now(),
            "sequence_id": sequence_id,
            "shot_index": shot_index,
            "shot_role": shot_role,
            "image_width": image_width,
            "image_height": image_height,
            "quality_score": quality_score,
            "detection_score": detection_score,
            "liveness_score": liveness_score,
            "match_score": match_score,
            "bbox_confidence": bbox_confidence,
            "depth_present": depth_present,
            "depth_coverage": depth_coverage,
            "depth_variance": depth_variance,
            "depth_evidence_passed": depth_evidence_passed,
            "event_id": event_id,
        }
        state.captures[capture_id] = payload
        return DemoCaptureRecord.model_validate(payload)

    def _capture_records(
        self,
        *,
        tenant_id: str | None = None,
        person_id: str | None = None,
        limit: int | None = None,
    ) -> list[DemoCaptureRecord]:
        captures = [
            DemoCaptureRecord.model_validate(payload)
            for payload in self._state().captures.values()
            if (tenant_id is None or payload["tenant_id"] == tenant_id)
            and (person_id is None or payload.get("person_id") == person_id)
        ]
        captures.sort(key=lambda capture: capture.created_at, reverse=True)
        return captures[:limit] if limit is not None else captures

    def _template_summaries(self, tenant_id: str | None = None) -> list[DemoTemplateSummary]:
        state = self._state()
        summaries: list[DemoTemplateSummary] = []
        for payload in state.templates.values():
            if tenant_id is not None and payload["tenant_id"] != tenant_id:
                continue
            person = state.people.get(payload["person_id"])
            summaries.append(
                DemoTemplateSummary(
                    id=payload["id"],
                    tenant_id=payload["tenant_id"],
                    person_id=payload["person_id"],
                    person_display_name=person.display_name if person else None,
                    source=payload.get("source", "unknown"),
                    created_at=payload.get("created_at", utc_now()),
                    capture_digest=payload["capture_digest"],
                )
            )
        summaries.sort(key=lambda summary: summary.created_at, reverse=True)
        return summaries

    def _people_summaries(self, tenant_id: str | None = None) -> list[DemoControlPersonSummary]:
        state = self._state()
        live_person_id = state.demo_control.person_id
        captures_by_person: dict[str, int] = {}
        for payload in state.captures.values():
            person_id = payload.get("person_id")
            if person_id:
                captures_by_person[person_id] = captures_by_person.get(person_id, 0) + 1
        people = self.list_people(tenant_id=tenant_id)
        summaries = [
            DemoControlPersonSummary(
                id=person.id,
                tenant_id=person.tenant_id,
                employee_code=person.employee_code,
                display_name=person.display_name,
                person_kind=self._person_kind(person),
                site_ids=person.site_ids,
                template_count=len(person.template_ids),
                capture_count=captures_by_person.get(person.id, 0),
                deletable=person.id.startswith("demo-person-"),
                active_live_session=person.id == live_person_id,
            )
            for person in people
        ]
        summaries.sort(key=lambda summary: (summary.person_kind != "demo", summary.display_name.lower()))
        return summaries

    def list_tenants(self) -> list[Tenant]:
        return list(self._state().tenants.values())

    def get_tenant(self, tenant_id: str) -> Tenant:
        return self._state().tenants[tenant_id]

    def get_policy(self, tenant_id: str) -> TenantPolicy:
        return self.get_tenant(tenant_id).policy

    def list_sites(self) -> list[WorkSite]:
        return list(self._state().sites.values())

    def list_sites_for_tenant(self, tenant_id: str) -> list[WorkSite]:
        return [
            site
            for site in self._state().sites.values()
            if site.tenant_id == tenant_id
        ]

    def list_people(self, tenant_id: str | None = None) -> list[Person]:
        people = list(self._state().people.values())
        if tenant_id is None:
            return people
        return [person for person in people if person.tenant_id == tenant_id]

    def _ensure_face_runtime(self) -> "InsightFaceImageRuntime":
        if self.face_runtime is None:
            raise RuntimeError(
                self.face_runtime_error
                or "Optional demo face runtime is unavailable in the current dl environment."
            )
        return self.face_runtime

    def _public_demo_face_record(self, payload: dict, state: RepositoryState | None = None) -> DemoFaceRecord:
        state = state or self._state()
        linked_person_id = payload.get("linked_person_id")
        linked_person_name = payload.get("linked_person_name")
        if linked_person_id and not linked_person_name:
            linked_person = state.people.get(linked_person_id)
            linked_person_name = linked_person.display_name if linked_person else None
        return DemoFaceRecord(
            id=payload["id"],
            tenant_id=payload["tenant_id"],
            display_name=payload["display_name"],
            linked_person_id=linked_person_id,
            linked_person_name=linked_person_name,
            created_at=payload["created_at"],
            quality_score=payload["quality_score"],
            detection_score=payload["detection_score"],
            bbox=payload.get("bbox"),
            image_width=payload.get("image_width"),
            image_height=payload.get("image_height"),
            detected_face_count=payload.get("detected_face_count", 0),
            template_digest=payload["template_digest"],
            manifests=payload.get("manifests", []),
            duplicate_of_face_id=payload.get("duplicate_of_face_id"),
            duplicate_score=payload.get("duplicate_score"),
        )

    def list_demo_faces(self, tenant_id: str | None = None) -> list[DemoFaceRecord]:
        state = self._state()
        demo_faces = list(state.demo_faces.values())
        if tenant_id is not None:
            demo_faces = [face for face in demo_faces if face["tenant_id"] == tenant_id]
        return [
            self._public_demo_face_record(payload, state=state)
            for payload in sorted(demo_faces, key=lambda face: str(face["created_at"]), reverse=True)
        ]

    def register_demo_face(self, request: DemoFaceRegisterRequest) -> DemoFaceRecord:
        runtime = self._ensure_face_runtime()
        state = self._state()
        linked_person: Person | None = None
        if request.linked_person_id:
            linked_person = state.people.get(request.linked_person_id)
            if linked_person is None:
                raise ValueError("Linked attendance user not found.")
            if linked_person.tenant_id != request.tenant_id:
                raise ValueError("Linked attendance user belongs to another tenant.")
        analysis = runtime.analyze(request.image_base64)
        protected = self.protector.protect(analysis.embedding_vector)

        duplicate_of_face_id: str | None = None
        duplicate_score = 0.0
        for payload in state.demo_faces.values():
            if payload["tenant_id"] != request.tenant_id:
                continue
            candidate = ProtectedTemplate.model_validate(payload["protected_template"])
            score = self.protector.similarity(candidate, protected)
            if score > duplicate_score:
                duplicate_score = score
                duplicate_of_face_id = payload["id"]

        record = {
            "id": new_id("demo_face"),
            "tenant_id": request.tenant_id,
            "display_name": request.display_name,
            "linked_person_id": linked_person.id if linked_person else None,
            "linked_person_name": linked_person.display_name if linked_person else None,
            "created_at": utc_now(),
            "quality_score": analysis.quality_score,
            "detection_score": analysis.detection_score,
            "bbox": analysis.bbox.model_dump(mode="json") if analysis.bbox else None,
            "image_width": analysis.image_width,
            "image_height": analysis.image_height,
            "detected_face_count": analysis.detected_face_count,
            "template_digest": protected.digest,
            "protected_template": protected.model_dump(mode="json"),
            "manifests": [manifest.model_dump(mode="json") for manifest in analysis.manifests],
            "duplicate_of_face_id": duplicate_of_face_id if duplicate_score >= 0.92 else None,
            "duplicate_score": round(duplicate_score, 4) if duplicate_score >= 0.92 else None,
        }
        state.demo_faces[record["id"]] = record
        self._save()
        return self._public_demo_face_record(record, state=state)

    def recognize_demo_face(
        self, request: DemoFaceRecognitionRequest
    ) -> DemoFaceRecognitionResponse:
        runtime = self._ensure_face_runtime()
        state = self._state()
        analysis = runtime.analyze(request.image_base64)
        protected = self.protector.protect(analysis.embedding_vector)

        best_payload: dict | None = None
        best_score = 0.0
        compared_faces = 0
        for payload in state.demo_faces.values():
            if payload["tenant_id"] != request.tenant_id:
                continue
            compared_faces += 1
            candidate = ProtectedTemplate.model_validate(payload["protected_template"])
            score = self.protector.similarity(candidate, protected)
            if score > best_score:
                best_score = score
                best_payload = payload

        matched = best_payload is not None and best_score >= request.threshold
        return DemoFaceRecognitionResponse(
            matched=matched,
            matched_face_id=best_payload["id"] if matched else None,
            matched_name=best_payload["display_name"] if matched else None,
            matched_person_id=best_payload.get("linked_person_id") if matched else None,
            matched_person_name=best_payload.get("linked_person_name") if matched else None,
            bbox=analysis.bbox,
            image_width=analysis.image_width,
            image_height=analysis.image_height,
            detected_face_count=analysis.detected_face_count,
            match_score=best_score,
            quality_score=analysis.quality_score,
            detection_score=analysis.detection_score,
            compared_faces=compared_faces,
            manifests=analysis.manifests,
        )

    def create_person(self, request: PersonCreateRequest) -> Person:
        state = self._state()
        person = Person(
            id=new_id("person"),
            tenant_id=request.tenant_id,
            employee_code=request.employee_code,
            display_name=request.display_name,
            site_ids=request.site_ids,
        )
        state.people[person.id] = person
        self._save()
        return person

    def create_demo_person(self, request: DemoControlPersonCreateRequest) -> Person:
        person = self._upsert_demo_person(request.tenant_id, request.display_name)
        self._save()
        return person

    def list_demo_control_people(self, tenant_id: str = "truepresence-demo") -> list[DemoControlPersonSummary]:
        return self._people_summaries(tenant_id=tenant_id)

    def list_demo_control_captures(
        self,
        *,
        tenant_id: str = "truepresence-demo",
        person_id: str | None = None,
        limit: int | None = 50,
    ) -> list[DemoCaptureRecord]:
        return self._capture_records(tenant_id=tenant_id, person_id=person_id, limit=limit)

    def create_binding_token(
        self,
        *,
        tenant_id: str,
        person_id: str,
    ) -> DeviceBindingTokenResponse:
        state = self._state()
        person = state.people.get(person_id)
        if person is None or person.tenant_id != tenant_id:
            raise ValueError("Student record not found.")
        self._cleanup_binding_tokens()
        token = new_id("bind")
        record = DeviceBindingToken(
            token=token,
            tenant_id=tenant_id,
            person_id=person.id,
            created_at=utc_now(),
            expires_at=utc_now() + timedelta(minutes=10),
        )
        state.binding_tokens[token] = record
        self._save()
        return DeviceBindingTokenResponse(
            person=person,
            token=token,
            qr_payload=self._binding_qr_payload(token),
            expires_at=record.expires_at,
        )

    def claim_device_link(self, request: DeviceLinkClaimRequest) -> DeviceLinkClaimResponse:
        state = self._state()
        self._cleanup_binding_tokens()
        token = request.token.strip()
        if token.startswith("{"):
            try:
                token = json.loads(token)["token"]
            except (KeyError, TypeError, json.JSONDecodeError) as error:
                raise ValueError("Invalid binding QR payload.") from error
        payload = state.binding_tokens.get(token)
        if payload is None:
            raise ValueError("Binding token was not found or has expired.")
        if payload.expires_at <= utc_now():
            state.binding_tokens.pop(token, None)
            self._save()
            raise ValueError("Binding token has expired.")
        device_id = request.device_attestation.device_id
        if not device_id:
            raise ValueError("Device attestation must include a device ID.")
        link = DeviceLink(
            id=f"device-link-{device_id}",
            tenant_id=payload.tenant_id,
            person_id=payload.person_id,
            device_id=device_id,
            provider=request.device_attestation.provider,
            bound_at=utc_now(),
            last_claimed_at=utc_now(),
        )
        state.device_links[device_id] = link
        payload.consumed_at = utc_now()
        payload.consumed_device_id = device_id
        state.binding_tokens[token] = payload
        linked_person = state.people[payload.person_id]
        self._save()
        bootstrap = self.mobile_bootstrap(payload.tenant_id, device_id=device_id)
        return DeviceLinkClaimResponse(
            linked_person=linked_person,
            bootstrap=bootstrap,
            linked_at=link.bound_at,
        )

    def clear_device_link(self, request: DeviceLinkClearRequest) -> DeviceLinkClearResponse:
        state = self._state()
        device_id = request.device_attestation.device_id
        if not device_id:
            raise ValueError("Device attestation must include a device ID.")
        existing = state.device_links.get(device_id)
        if existing and existing.tenant_id != request.tenant_id:
            raise ValueError("Device link belongs to another tenant.")
        cleared = state.device_links.pop(device_id, None) is not None
        self._save()
        return DeviceLinkClearResponse(
            cleared=cleared,
            tenant_id=request.tenant_id,
            device_id=device_id,
        )

    def start_class_session(self, request: ClassSessionStartRequest) -> ClassSessionStartResponse:
        state = self._state()
        site = state.sites.get(request.site_id)
        if site is None or site.tenant_id != request.tenant_id:
            raise ValueError("Classroom site was not found.")
        session = ActiveClassSession(
            id=new_id("class_session"),
            tenant_id=request.tenant_id,
            site_id=site.id,
            site_label=site.label,
            class_label=(request.class_label or f"{site.label} Attendance").strip(),
            canonical_lan_url=self._canonical_lan_url(),
            started_at=utc_now(),
            active=True,
        )
        state.active_class_session = session
        self._save()
        return ClassSessionStartResponse(
            active_class_session=session,
            bootstrap=self.mobile_bootstrap(request.tenant_id),
        )

    def stop_class_session(self, tenant_id: str = "truepresence-demo") -> ClassSessionStopResponse:
        state = self._state()
        session = self._active_class_session(tenant_id)
        if session is None:
            return ClassSessionStopResponse(active_class_session=None)
        session.active = False
        session.ends_at = utc_now()
        state.active_class_session = session
        self._save()
        return ClassSessionStopResponse(active_class_session=session)

    def demo_capture_file(self, capture_id: str) -> Path:
        payload = self._state().captures.get(capture_id)
        if payload is None:
            raise ValueError("Capture not found.")
        path = Path(payload["file_path"])
        if path.exists() is False:
            raise ValueError("Capture file not found.")
        return path

    def clear_demo_control_events(self, tenant_id: str = "truepresence-demo") -> dict[str, int | str]:
        state = self._state()
        cleared = len([event for event in state.attendance_events.values() if event.tenant_id == tenant_id])
        state.attendance_events = {
            event_id: event
            for event_id, event in state.attendance_events.items()
            if event.tenant_id != tenant_id
        }
        for capture_id, payload in list(state.captures.items()):
            if payload.get("tenant_id") == tenant_id and payload.get("stage") == "verification":
                self._delete_capture_file(payload.get("file_path"))
                state.captures.pop(capture_id, None)
        self._save()
        return {"scope": "demo_events", "cleared_event_count": cleared}

    def delete_demo_person(self, person_id: str, tenant_id: str = "truepresence-demo") -> dict[str, int | str]:
        state = self._state()
        person = state.people.get(person_id)
        if person is None:
            raise ValueError("Demo person not found.")
        if person.tenant_id != tenant_id:
            raise ValueError("Demo person belongs to another tenant.")
        if not person.id.startswith("demo-person-"):
            raise ValueError("Built-in students are read-only.")

        removed_templates = self._remove_person_templates(state, person)
        removed_captures = 0
        removed_events = 0
        removed_sites = 0

        for capture_id, payload in list(state.captures.items()):
            if payload.get("person_id") == person.id:
                self._delete_capture_file(payload.get("file_path"))
                state.captures.pop(capture_id, None)
                removed_captures += 1

        for event_id, event in list(state.attendance_events.items()):
            if event.tenant_id == tenant_id and (
                event.person_id == person.id or event.matched_person_id == person.id
            ):
                state.attendance_events.pop(event_id, None)
                removed_events += 1

        for ticket_id, ticket in list(state.review_tickets.items()):
            if ticket.tenant_id == tenant_id and ticket.event_id not in state.attendance_events:
                state.review_tickets.pop(ticket_id, None)

        for site_id in list(person.site_ids):
            site = state.sites.get(site_id)
            if site and site.id.startswith("demo-site-"):
                state.sites.pop(site_id, None)
                removed_sites += 1

        for token, payload in list(state.binding_tokens.items()):
            if payload.tenant_id == tenant_id and payload.person_id == person.id:
                state.binding_tokens.pop(token, None)

        for device_id, payload in list(state.device_links.items()):
            if payload.tenant_id == tenant_id and payload.person_id == person.id:
                state.device_links.pop(device_id, None)

        state.people.pop(person.id, None)

        if state.demo_control.person_id == person.id:
            state.demo_control = DemoControlSession(tenant_id=tenant_id)
        if state.active_class_session and state.active_class_session.tenant_id == tenant_id:
            if state.active_class_session.site_id not in state.sites:
                state.active_class_session = None

        self._save()
        return {
            "scope": "demo_person",
            "person_id": person.id,
            "removed_template_count": removed_templates,
            "removed_capture_count": removed_captures,
            "removed_event_count": removed_events,
            "removed_site_count": removed_sites,
        }

    def _demo_employee_code(self, state: RepositoryState, tenant_id: str) -> str:
        existing = [
            person.employee_code
            for person in state.people.values()
            if person.tenant_id == tenant_id and person.employee_code.startswith("D")
        ]
        next_index = len(existing) + 1
        return f"D{next_index:04d}"

    def _upsert_demo_person(self, tenant_id: str, display_name: str) -> Person:
        state = self._state()
        normalized = display_name.strip().casefold()
        for person in state.people.values():
            if person.tenant_id == tenant_id and person.display_name.strip().casefold() == normalized:
                return person

        person = Person(
            id=f"demo-person-{slugify(display_name)}",
            tenant_id=tenant_id,
            employee_code=self._demo_employee_code(state, tenant_id),
            display_name=display_name.strip(),
            site_ids=[],
        )
        state.people[person.id] = person
        self._save()
        return person

    def _upsert_demo_site(self, tenant_id: str, person: Person, request: DemoSessionStartRequest) -> WorkSite:
        state = self._state()
        site_id = f"demo-site-{person.id.removeprefix('demo-person-')}"
        site = WorkSite(
            id=site_id,
            tenant_id=tenant_id,
            label=f"{person.display_name} Classroom Site",
            latitude=request.gps.latitude,
            longitude=request.gps.longitude,
            radius_m=max(request.gps.accuracy_m * 3.0, 120.0),
        )
        state.sites[site.id] = site
        person.site_ids = [site.id]
        state.people[person.id] = person
        self._save()
        return site

    def _resolve_demo_session_person(self, request: DemoSessionStartRequest) -> Person:
        state = self._state()
        person = state.people.get(request.person_id)
        if person is None:
            raise ValueError("Selected demo person was not found.")
        if person.tenant_id != request.tenant_id:
            raise ValueError("Selected demo person belongs to another tenant.")
        if person.id.startswith("demo-person-") is False:
            raise ValueError("Live demo sessions can only be started for demo people created on the Mac.")
        return person

    def mobile_demo_session_start(
        self, request: DemoSessionStartRequest
    ) -> DemoSessionStartResponse:
        person = self._resolve_demo_session_person(request)
        site = self._upsert_demo_site(request.tenant_id, person, request)
        self._set_demo_control_session(person, site)
        self._mark_mobile_seen(source="demo_session_start")
        bootstrap = self.mobile_bootstrap(request.tenant_id)
        return DemoSessionStartResponse(
            person=person,
            site=site,
            bootstrap=bootstrap,
        )

    def _remove_person_templates(self, state: RepositoryState, person: Person) -> int:
        removed = 0
        for template_id in list(person.template_ids):
            if template_id in state.templates:
                state.templates.pop(template_id, None)
                removed += 1
        person.template_ids = []
        state.people[person.id] = person
        return removed

    def _store_protected_template(
        self,
        *,
        person: Person,
        protected: ProtectedTemplate,
        source: str,
    ) -> str:
        state = self._state()
        template_id = new_id("tmpl")
        state.templates[template_id] = {
            "id": template_id,
            "person_id": person.id,
            "tenant_id": person.tenant_id,
            "capture_digest": protected.digest,
            "protected_template": protected.model_dump(mode="json"),
            "created_at": utc_now().isoformat(),
            "source": source,
        }
        person.template_ids.append(template_id)
        state.people[person.id] = person
        return template_id

    def demo_control_reset(self, tenant_id: str = "truepresence-demo") -> DemoControlResetResponse:
        state = self._state()
        cleared_event_count = len(
            [event for event in state.attendance_events.values() if event.tenant_id == tenant_id]
        )
        cleared_review_count = len(
            [ticket for ticket in state.review_tickets.values() if ticket.tenant_id == tenant_id]
        )
        cleared_demo_face_count = len(
            [face for face in state.demo_faces.values() if face["tenant_id"] == tenant_id]
        )
        tenant_capture_ids = [
            capture_id
            for capture_id, payload in state.captures.items()
            if payload.get("tenant_id") == tenant_id
        ]
        demo_person_ids = [
            person.id
            for person in state.people.values()
            if person.tenant_id == tenant_id and person.id.startswith("demo-person-")
        ]
        demo_site_ids = [
            site.id
            for site in state.sites.values()
            if site.tenant_id == tenant_id and site.id.startswith("demo-site-")
        ]
        cleared_template_count = 0
        for person_id in demo_person_ids:
            person = state.people[person_id]
            cleared_template_count += self._remove_person_templates(state, person)
            state.people.pop(person_id, None)
        for site_id in demo_site_ids:
            state.sites.pop(site_id, None)
        state.attendance_events = {
            event_id: event
            for event_id, event in state.attendance_events.items()
            if event.tenant_id != tenant_id
        }
        state.review_tickets = {
            ticket_id: ticket
            for ticket_id, ticket in state.review_tickets.items()
            if ticket.tenant_id != tenant_id
        }
        state.demo_faces = {
            face_id: face
            for face_id, face in state.demo_faces.items()
            if face["tenant_id"] != tenant_id
        }
        for capture_id in tenant_capture_ids:
            payload = state.captures.pop(capture_id, None)
            if payload:
                self._delete_capture_file(payload.get("file_path"))
        for session_id, session in list(state.enrollment_sessions.items()):
            if session.tenant_id == tenant_id and session.person_id.startswith("demo-person-"):
                state.enrollment_sessions.pop(session_id, None)
        state.binding_tokens = {
            token: payload
            for token, payload in state.binding_tokens.items()
            if payload.tenant_id != tenant_id
        }
        state.device_links = {
            device_id: payload
            for device_id, payload in state.device_links.items()
            if payload.tenant_id != tenant_id
        }
        if state.active_class_session and state.active_class_session.tenant_id == tenant_id:
            state.active_class_session = None
        if tenant_id in state.tenants:
            state.tenants[tenant_id].policy = TenantPolicy()
        state.demo_control = DemoControlSession(tenant_id=tenant_id)
        self._save()
        return DemoControlResetResponse(
            cleared_event_count=cleared_event_count,
            cleared_review_count=cleared_review_count,
            cleared_demo_person_count=len(demo_person_ids),
            cleared_demo_site_count=len(demo_site_ids),
            cleared_template_count=cleared_template_count,
            cleared_demo_face_count=cleared_demo_face_count,
        )

    def demo_control_session_start(
        self, request: DemoSessionStartRequest
    ) -> DemoControlSessionStartResponse:
        response = self.mobile_demo_session_start(request)
        session = self._demo_control().model_copy()
        return DemoControlSessionStartResponse(
            session=session,
            person=response.person,
            site=response.site,
            bootstrap=response.bootstrap,
        )

    def demo_control_enroll_from_mac(
        self, request: DemoControlEnrollFromMacRequest
    ) -> DemoControlEnrollmentResponse:
        runtime = self._ensure_face_runtime()
        state = self._state()
        person = state.people.get(request.person_id)
        if person is None:
            raise ValueError("Demo person not found. Start a live demo session first.")
        if person.tenant_id != request.tenant_id:
            raise ValueError("Demo person belongs to another tenant.")
        analysis = runtime.analyze(request.image_base64)
        protected = self.protector.protect(analysis.embedding_vector)
        if request.shot_index <= 1:
            self._remove_person_templates(state, person)
        template_id = self._store_protected_template(
            person=person,
            protected=protected,
            source=request.source,
        )
        capture = self._register_capture_record(
            tenant_id=request.tenant_id,
            person=person,
            image_base64=request.image_base64,
            source=request.source,
            stage="enrollment",
            sequence_id=request.sequence_id,
            shot_index=request.shot_index,
            shot_role=request.shot_role,
            image_width=analysis.image_width,
            image_height=analysis.image_height,
            quality_score=analysis.quality_score,
            detection_score=analysis.detection_score,
            bbox_confidence=analysis.bbox.confidence if analysis.bbox else None,
        )
        control = self._demo_control()
        control.person_id = person.id
        control.display_name = person.display_name
        control.last_mac_enrollment_at = utc_now()
        control.last_mac_quality_score = analysis.quality_score
        control.last_mac_detection_score = analysis.detection_score
        control.last_mac_bbox = analysis.bbox
        site = state.sites.get(control.site_id) if control.site_id else None
        self._save()
        return DemoControlEnrollmentResponse(
            person=person,
            site=site,
            template_id=template_id,
            template_count=len(person.template_ids),
            template_scheme=protected.scheme,
            capture_id=capture.id,
            quality_score=analysis.quality_score,
            detection_score=analysis.detection_score,
            bbox=analysis.bbox,
            image_width=analysis.image_width,
            image_height=analysis.image_height,
            detected_face_count=analysis.detected_face_count,
            manifests=analysis.manifests,
        )

    def demo_control_snapshot(self, tenant_id: str = "truepresence-demo") -> DemoControlSnapshot:
        state = self._state()
        live_session = state.demo_control if state.demo_control.tenant_id == tenant_id else None
        live_person = (
            state.people.get(live_session.person_id) if live_session and live_session.person_id else None
        )
        live_site = state.sites.get(live_session.site_id) if live_session and live_session.site_id else None
        active_class_session = self._active_class_session(tenant_id)
        recent_events = self.list_events(tenant_id=tenant_id, limit=20)
        wifi_ipv4 = self._wifi_ipv4()
        canonical_lan_url = self._canonical_lan_url()
        return DemoControlSnapshot(
            overview=self.admin_overview(),
            live_session=live_session,
            live_person=live_person,
            live_site=live_site,
            active_class_session=active_class_session,
            wifi_ipv4=wifi_ipv4,
            canonical_lan_url=canonical_lan_url,
            backend_bind_host=self._backend_bind_host(),
            lan_ready=canonical_lan_url is not None,
            network_hint=self._network_hint(),
            people_summary=self._people_summaries(tenant_id=tenant_id),
            template_summary=self._template_summaries(tenant_id=tenant_id),
            capture_summary=self._capture_records(tenant_id=tenant_id, limit=24),
            recent_events=recent_events,
            latest_event=recent_events[0] if recent_events else None,
            face_demo_runtime=demo_face_runtime_status(
                self.face_runtime_id,
                runtime_ready=self.face_runtime is not None,
                error_detail=self.face_runtime_error,
            ),
            capture_profile=self.capture_profile,
            method_stack=latest_method_stack_profile(),
        )

    def create_enrollment_session(self, request: EnrollmentSessionCreate) -> EnrollmentSession:
        state = self._state()
        session = EnrollmentSession(
            id=new_id("enroll"),
            tenant_id=request.tenant_id,
            person_id=request.person_id,
            consent_reference=request.consent_reference,
            retention_approved=request.retention_approved,
        )
        state.enrollment_sessions[session.id] = session
        self._save()
        return session

    def add_enrollment_capture(
        self, session_id: str, request: EnrollmentCaptureRequest
    ) -> EnrollmentCaptureRecord:
        state = self._state()
        session = state.enrollment_sessions[session_id]
        analysis = self.capture_pipeline.analyze(
            capture_token=request.capture_token,
            embedding_vector=request.embedding_vector,
            quality_score=request.quality_score,
            liveness_score=request.liveness_score,
            bbox_confidence=request.bbox_confidence,
        )
        manifests = request.provider_manifests or analysis.manifests
        protected = request.protected_template or self.protector.protect(analysis.embedding_vector)
        duplicate_candidate_ids: list[str] = []

        for template_payload in state.templates.values():
            if template_payload["person_id"] == session.person_id:
                continue
            score = self.protector.similarity(
                ProtectedTemplate.model_validate(template_payload["protected_template"]),
                protected,
            )
            if score >= self.get_policy(session.tenant_id).thresholds.duplicate_match_threshold:
                duplicate_candidate_ids.append(template_payload["person_id"])

        record = EnrollmentCaptureRecord(
            capture_id=new_id("capture"),
            created_at=utc_now(),
            quality_score=analysis.quality_score,
            liveness_score=analysis.liveness_score,
            bbox_confidence=analysis.bbox_confidence,
            device_model=request.device_model,
            provider_manifests=manifests,
            duplicate_candidate_ids=sorted(set(duplicate_candidate_ids)),
            protected_template=protected,
        )
        session.captures.append(record)
        self._save()
        return record

    def finalize_enrollment(self, session_id: str) -> EnrollmentFinalizeResponse:
        state = self._state()
        session = state.enrollment_sessions[session_id]
        person = state.people[session.person_id]
        duplicate_candidate_ids: list[str] = []

        for capture in session.captures:
            template_id = new_id("tmpl")
            state.templates[template_id] = {
                "id": template_id,
                "person_id": person.id,
                "tenant_id": person.tenant_id,
                "capture_digest": capture.protected_template.digest,
                "protected_template": capture.protected_template.model_dump(mode="json"),
                "created_at": utc_now().isoformat(),
                "source": "enrollment_session",
            }
            person.template_ids.append(template_id)
            duplicate_candidate_ids.extend(capture.duplicate_candidate_ids)

        session.status = "completed"
        self._save()
        return EnrollmentFinalizeResponse(
            session_id=session.id,
            person_id=person.id,
            templates_created=len(session.captures),
            duplicate_candidate_ids=sorted(set(duplicate_candidate_ids)),
        )

    def _confidence_band(self, score: float, policy: TenantPolicy) -> str:
        if score >= policy.thresholds.min_match_score + 0.08:
            return "high"
        if score >= policy.thresholds.review_match_floor:
            return "medium"
        return "low"

    def _local_hour(self, tenant: Tenant, client_timestamp) -> int:
        try:
            return client_timestamp.astimezone(ZoneInfo(tenant.timezone)).hour
        except ZoneInfoNotFoundError:
            return client_timestamp.hour

    def _is_within_window(self, hour: int, policy: TenantPolicy) -> bool:
        return policy.attendance_window.start_hour_local <= hour < policy.attendance_window.end_hour_local

    def _select_candidate_templates(
        self, tenant_id: str, person_id: str | None, mode: str
    ) -> list[tuple[str, ProtectedTemplate]]:
        state = self._state()
        templates: list[tuple[str, ProtectedTemplate]] = []

        if mode == "1:1":
            if not person_id:
                return []
            person = state.people.get(person_id)
            if not person:
                return []
            for template_id in person.template_ids:
                payload = state.templates.get(template_id)
                if payload:
                    templates.append(
                        (person.id, ProtectedTemplate.model_validate(payload["protected_template"]))
                    )
            return templates

        for payload in state.templates.values():
            if payload["tenant_id"] != tenant_id:
                continue
            templates.append(
                (
                    payload["person_id"],
                    ProtectedTemplate.model_validate(payload["protected_template"]),
                )
            )
        return templates

    def submit_attendance_claim(self, request: AttendanceClaimRequest) -> AttendanceDecision:
        state = self._state()
        tenant = state.tenants[request.tenant_id]
        policy = tenant.policy
        site = state.sites.get(request.site_id)
        direct_lan_demo = self._is_direct_lan_demo(request)
        active_live_demo_claim = self._is_active_live_demo_claim(request=request, state=state)
        self._mark_mobile_seen(source="attendance_claim", app_version=request.app_version)

        if not verify_claim_signature(request, tenant):
            return AttendanceDecision(
                accepted=False,
                reason_code="bad_signature",
                confidence_band="low",
                step_up_required=False,
                match_score=0.0,
                quality_score=request.quality_score or 0.0,
                liveness_score=request.liveness_score or 0.0,
                geofence_result="fail",
            )

        if site is None:
            return AttendanceDecision(
                accepted=False,
                reason_code="site_not_found",
                confidence_band="low",
                step_up_required=False,
                match_score=0.0,
                quality_score=request.quality_score or 0.0,
                liveness_score=request.liveness_score or 0.0,
                geofence_result="fail",
            )

        if request.person_id:
            person = state.people.get(request.person_id)
            if person is None:
                return AttendanceDecision(
                    accepted=False,
                    reason_code="person_not_found",
                    confidence_band="low",
                    step_up_required=False,
                    match_score=0.0,
                    quality_score=request.quality_score or 0.0,
                    liveness_score=request.liveness_score or 0.0,
                    geofence_result="fail",
                )
            if person.site_ids and request.site_id not in person.site_ids:
                return AttendanceDecision(
                    accepted=False,
                    reason_code="site_not_allowed",
                    confidence_band="low",
                    step_up_required=False,
                    match_score=0.0,
                    quality_score=request.quality_score or 0.0,
                    liveness_score=request.liveness_score or 0.0,
                    geofence_result="fail",
                )

        analysis = self.capture_pipeline.analyze(
            capture_token=request.capture_token,
            embedding_vector=request.embedding_vector,
            quality_score=request.quality_score,
            liveness_score=request.liveness_score,
            bbox_confidence=request.bbox_confidence,
        )
        face_analysis = None
        protected_claim = request.protected_template or self.protector.protect(analysis.embedding_vector)
        if request.face_image_base64 and request.protected_template is None:
            runtime = self._ensure_face_runtime()
            face_analysis = runtime.analyze(request.face_image_base64)
            protected_claim = self.protector.protect(face_analysis.embedding_vector)

        distance_m = haversine_meters(
            request.gps.latitude,
            request.gps.longitude,
            site.latitude,
            site.longitude,
        )
        geofence_result = "pass" if distance_m <= site.radius_m else "fail"

        best_person_id: str | None = None
        best_score = 0.0
        for candidate_person_id, candidate_template in self._select_candidate_templates(
            request.tenant_id, request.person_id, request.claimed_identity_mode
        ):
            score = self.protector.similarity(candidate_template, protected_claim)
            if score > best_score:
                best_score = score
                best_person_id = candidate_person_id

        accepted = True
        reason_code = "accepted"
        step_up_required = False

        if request.gps.is_mocked:
            accepted = False
            reason_code = "mock_location_detected"
        elif geofence_result == "fail":
            accepted = False
            reason_code = "outside_geofence"
        elif policy.require_device_attestation and not request.device_attestation.is_trusted:
            accepted = False
            step_up_required = True
            reason_code = "untrusted_device"
        elif (
            active_live_demo_claim is False
            and not self._is_within_window(self._local_hour(tenant, request.client_timestamp), policy)
        ):
            accepted = False
            step_up_required = True
            reason_code = "outside_attendance_window"
        elif analysis.liveness_score < policy.thresholds.min_liveness_score:
            accepted = False
            step_up_required = True
            reason_code = "low_liveness"
        elif analysis.quality_score < policy.thresholds.min_quality_score:
            accepted = False
            step_up_required = True
            reason_code = "low_quality"
        elif best_score < policy.thresholds.review_match_floor:
            accepted = False
            reason_code = "low_match"
        elif best_score < policy.thresholds.min_match_score:
            accepted = False
            step_up_required = True
            reason_code = "marginal_match"

        if direct_lan_demo and step_up_required:
            accepted = False
            step_up_required = False

        review_ticket_id: str | None = None
        person = state.people.get(request.person_id) if request.person_id else None
        matched_person = state.people.get(best_person_id) if best_person_id else None
        capture_record: DemoCaptureRecord | None = None
        if request.face_image_base64:
            capture_record = self._register_capture_record(
                tenant_id=request.tenant_id,
                person=person,
                image_base64=request.face_image_base64,
                source="iphone_verify",
                stage="verification",
                image_width=getattr(face_analysis, "image_width", None) if request.face_image_base64 else None,
                image_height=getattr(face_analysis, "image_height", None) if request.face_image_base64 else None,
                quality_score=analysis.quality_score,
                detection_score=getattr(face_analysis, "detection_score", None) if request.face_image_base64 else None,
                liveness_score=analysis.liveness_score,
                match_score=best_score,
                bbox_confidence=request.bbox_confidence,
                depth_present=request.depth_present,
                depth_coverage=request.depth_coverage,
                depth_variance=request.depth_variance,
                depth_evidence_passed=request.depth_evidence_passed,
            )
        event = AttendanceEvent(
            id=new_id("evt"),
            created_at=utc_now(),
            tenant_id=request.tenant_id,
            person_id=request.person_id,
            matched_person_id=best_person_id,
            site_id=request.site_id,
            claimed_identity_mode=request.claimed_identity_mode,
            client_timestamp=request.client_timestamp,
            gps=request.gps,
            app_version=request.app_version,
            reason_code=reason_code,
            accepted=accepted,
            step_up_required=step_up_required,
            quality_score=analysis.quality_score,
            liveness_score=analysis.liveness_score,
            match_score=best_score,
            geofence_result=geofence_result,
            claim_source=request.claim_source,
            decision_origin="server",
            optional_evidence_ref=(
                request.optional_evidence_ref if policy.retention.store_evidence_snapshots else None
            ),
            capture_id=capture_record.id if capture_record else None,
            capture_file_path=capture_record.file_path if capture_record else None,
            person_display_name=person.display_name if person else None,
            matched_person_display_name=matched_person.display_name if matched_person else None,
            site_label=site.label,
        )
        state.attendance_events[event.id] = event
        if capture_record:
            capture_payload = state.captures.get(capture_record.id)
            if capture_payload is not None:
                capture_payload["event_id"] = event.id

        if step_up_required and not direct_lan_demo:
            ticket = ReviewTicket(
                id=new_id("review"),
                event_id=event.id,
                tenant_id=request.tenant_id,
                reason_code=reason_code,
            )
            state.review_tickets[ticket.id] = ticket
            review_ticket_id = ticket.id

        self._save()

        return AttendanceDecision(
            accepted=accepted,
            reason_code=reason_code,
            confidence_band=self._confidence_band(best_score, policy),
            step_up_required=step_up_required,
            review_ticket=review_ticket_id,
            matched_person_id=best_person_id,
            match_score=best_score,
            quality_score=analysis.quality_score,
            liveness_score=analysis.liveness_score,
            geofence_result=geofence_result,
            decision_origin="server",
        )

    def list_events(
        self,
        *,
        tenant_id: str | None = None,
        person_id: str | None = None,
        limit: int | None = None,
    ) -> list[AttendanceEvent]:
        events = list(self._state().attendance_events.values())
        if tenant_id is not None:
            events = [event for event in events if event.tenant_id == tenant_id]
        if person_id is not None:
            events = [event for event in events if event.person_id == person_id]
        events = sorted(events, key=lambda event: event.created_at, reverse=True)
        if limit is not None:
            return events[:limit]
        return events

    def list_review_tickets(self) -> list[ReviewTicket]:
        return sorted(
            self._state().review_tickets.values(),
            key=lambda ticket: ticket.created_at,
            reverse=True,
        )

    def resolve_review_ticket(self, ticket_id: str, request: ReviewResolutionRequest) -> ReviewTicket:
        state = self._state()
        ticket = state.review_tickets[ticket_id]
        ticket.status = "resolved"
        ticket.resolved_at = utc_now()
        ticket.resolution = request.resolution
        self._save()
        return ticket

    def admin_overview(self) -> AdminOverview:
        return AdminOverview(
            tenant_count=len(self._state().tenants),
            person_count=len(self._state().people),
            attendance_event_count=len(self._state().attendance_events),
            open_review_count=sum(
                1 for ticket in self._state().review_tickets.values() if ticket.status == "open"
            ),
            sites=self.list_sites(),
            recent_events=self.list_events()[:8],
        )

    def export_attendance_csv(self) -> str:
        handle = io.StringIO()
        writer = csv.writer(handle)
        writer.writerow(
            [
                "event_id",
                "tenant_id",
                "person_id",
                "matched_person_id",
                "site_id",
                "accepted",
                "reason_code",
                "step_up_required",
                "quality_score",
                "liveness_score",
                "match_score",
                "created_at",
            ]
        )
        for event in self.list_events():
            writer.writerow(
                [
                    event.id,
                    event.tenant_id,
                    event.person_id,
                    event.matched_person_id,
                    event.site_id,
                    event.accepted,
                    event.reason_code,
                    event.step_up_required,
                    f"{event.quality_score:.4f}",
                    f"{event.liveness_score:.4f}",
                    f"{event.match_score:.4f}",
                    event.created_at.isoformat(),
                ]
            )
        return handle.getvalue()

    def runtime_profile(self) -> RuntimeProfileResponse:
        return RuntimeProfileResponse(
            method_stack=latest_method_stack_profile(),
            capture_profile=self.capture_profile,
            deployment_profiles=deployment_profiles(),
            face_demo_runtime=demo_face_runtime_status(
                self.face_runtime_id,
                runtime_ready=self.face_runtime is not None,
                error_detail=self.face_runtime_error,
            ),
        )

    def mobile_bootstrap(self, tenant_id: str, device_id: str | None = None) -> MobileBootstrapResponse:
        tenant = self.get_tenant(tenant_id)
        self._mark_mobile_seen(source="bootstrap")
        state = self._state()
        control = state.demo_control if state.demo_control.tenant_id == tenant_id else None
        live_person = state.people.get(control.person_id) if control and control.person_id else None
        live_site = state.sites.get(control.site_id) if control and control.site_id else None
        linked_person = self._linked_person_for_device(tenant_id=tenant_id, device_id=device_id)
        active_class_session = self._active_class_session(tenant_id)
        wifi_ipv4 = self._wifi_ipv4()
        canonical_lan_url = self._canonical_lan_url()
        return MobileBootstrapResponse(
            tenant=MobileBootstrapTenant(
                id=tenant.id,
                name=tenant.name,
                timezone=tenant.timezone,
            ),
            policy=tenant.policy,
            people=self.list_people(tenant_id=tenant_id),
            sites=self.list_sites_for_tenant(tenant_id),
            linked_person=linked_person,
            active_class_session=active_class_session,
            live_person=live_person,
            live_site=live_site,
            wifi_ipv4=wifi_ipv4,
            canonical_lan_url=canonical_lan_url,
            backend_bind_host=self._backend_bind_host(),
            lan_ready=canonical_lan_url is not None,
            network_hint=self._network_hint(),
            server_time=utc_now(),
            method_stack=latest_method_stack_profile(),
            capture_profile=self.capture_profile,
        )
