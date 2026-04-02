from __future__ import annotations

from datetime import datetime, timezone
from typing import Literal
from uuid import uuid4

from pydantic import BaseModel, Field

from mobile_attendance_biometrics import (
    BoundingBox,
    DeploymentProfile,
    ProtectedTemplate,
    ProviderManifest,
    RuntimeSelectionStatus,
)
from mobile_attendance_biometrics.method_stack import MethodStackProfile


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def new_id(prefix: str) -> str:
    return f"{prefix}_{uuid4().hex[:12]}"


class GeoPoint(BaseModel):
    latitude: float
    longitude: float
    accuracy_m: float = Field(default=30.0, ge=0.0)
    is_mocked: bool = False


class DeviceAttestation(BaseModel):
    provider: str
    token: str
    secure_enclave_backed: bool = False
    is_trusted: bool = True
    device_id: str | None = None


class ThresholdPolicy(BaseModel):
    min_quality_score: float = 0.35
    min_liveness_score: float = 0.76
    min_match_score: float = 0.80
    review_match_floor: float = 0.74
    duplicate_match_threshold: float = 0.9


class RetentionPolicy(BaseModel):
    store_evidence_snapshots: bool = False
    evidence_ttl_days: int = 7
    attendance_ttl_days: int = 365
    template_rotation_days: int = 180


class OfflinePolicy(BaseModel):
    queue_ttl_minutes: int = 30


class AttendanceWindow(BaseModel):
    start_hour_local: int = 6
    end_hour_local: int = 22


class TenantPolicy(BaseModel):
    thresholds: ThresholdPolicy = Field(default_factory=ThresholdPolicy)
    retention: RetentionPolicy = Field(default_factory=RetentionPolicy)
    offline: OfflinePolicy = Field(default_factory=OfflinePolicy)
    attendance_window: AttendanceWindow = Field(default_factory=AttendanceWindow)
    require_device_attestation: bool = True
    allow_1_n_fallback: bool = True
    step_up_triggers: list[str] = Field(
        default_factory=lambda: [
            "low_liveness",
            "low_quality",
            "marginal_match",
            "untrusted_device",
            "outside_window",
        ]
    )


class Tenant(BaseModel):
    id: str
    name: str
    timezone: str
    api_secret: str
    policy: TenantPolicy = Field(default_factory=TenantPolicy)


class WorkSite(BaseModel):
    id: str
    tenant_id: str
    label: str
    latitude: float
    longitude: float
    radius_m: float


class Person(BaseModel):
    id: str
    tenant_id: str
    employee_code: str
    display_name: str
    site_ids: list[str] = Field(default_factory=list)
    active: bool = True
    template_ids: list[str] = Field(default_factory=list)


class EnrollmentCaptureRequest(BaseModel):
    capture_token: str | None = None
    embedding_vector: list[float] | None = None
    protected_template: ProtectedTemplate | None = None
    quality_score: float | None = None
    liveness_score: float | None = None
    bbox_confidence: float | None = None
    device_model: str = "ios-student"
    provider_manifests: list[ProviderManifest] = Field(default_factory=list)


class EnrollmentCaptureRecord(BaseModel):
    capture_id: str
    created_at: datetime
    quality_score: float
    liveness_score: float
    bbox_confidence: float
    device_model: str
    provider_manifests: list[ProviderManifest]
    duplicate_candidate_ids: list[str] = Field(default_factory=list)
    protected_template: ProtectedTemplate


class EnrollmentSessionCreate(BaseModel):
    tenant_id: str
    person_id: str
    consent_reference: str
    retention_approved: bool = True


class EnrollmentSession(BaseModel):
    id: str
    tenant_id: str
    person_id: str
    consent_reference: str
    retention_approved: bool
    status: Literal["open", "completed", "cancelled"] = "open"
    created_at: datetime = Field(default_factory=utc_now)
    captures: list[EnrollmentCaptureRecord] = Field(default_factory=list)


class EnrollmentFinalizeResponse(BaseModel):
    session_id: str
    person_id: str
    templates_created: int
    duplicate_candidate_ids: list[str]


class PersonCreateRequest(BaseModel):
    tenant_id: str
    employee_code: str
    display_name: str
    site_ids: list[str] = Field(default_factory=list)


class DemoSessionStartRequest(BaseModel):
    tenant_id: str
    person_id: str
    gps: GeoPoint


class DemoFaceRegisterRequest(BaseModel):
    tenant_id: str = "truepresence-demo"
    display_name: str
    linked_person_id: str | None = None
    image_base64: str


class DemoFaceRecord(BaseModel):
    id: str
    tenant_id: str
    display_name: str
    linked_person_id: str | None = None
    linked_person_name: str | None = None
    created_at: datetime
    quality_score: float
    detection_score: float
    bbox: BoundingBox | None = None
    image_width: int | None = None
    image_height: int | None = None
    detected_face_count: int = 0
    template_digest: str
    manifests: list[ProviderManifest] = Field(default_factory=list)
    duplicate_of_face_id: str | None = None
    duplicate_score: float | None = None


class DemoFaceRecognitionRequest(BaseModel):
    tenant_id: str = "truepresence-demo"
    image_base64: str
    threshold: float = Field(default=0.80, ge=0.0, le=1.0)


class DemoFaceRecognitionResponse(BaseModel):
    matched: bool
    matched_face_id: str | None = None
    matched_name: str | None = None
    matched_person_id: str | None = None
    matched_person_name: str | None = None
    bbox: BoundingBox | None = None
    image_width: int | None = None
    image_height: int | None = None
    detected_face_count: int = 0
    match_score: float
    quality_score: float
    detection_score: float
    compared_faces: int
    manifests: list[ProviderManifest] = Field(default_factory=list)


class AttendanceClaimRequest(BaseModel):
    tenant_id: str
    person_id: str | None = None
    site_id: str
    claimed_identity_mode: Literal["1:1", "1:n"] = "1:1"
    client_timestamp: datetime
    gps: GeoPoint
    device_attestation: DeviceAttestation
    app_version: str
    capture_token: str | None = None
    face_image_base64: str | None = None
    embedding_vector: list[float] | None = None
    protected_template: ProtectedTemplate | None = None
    quality_score: float | None = None
    liveness_score: float | None = None
    bbox_confidence: float | None = None
    provider_manifests: list[ProviderManifest] = Field(default_factory=list)
    depth_present: bool | None = None
    depth_coverage: float | None = None
    depth_variance: float | None = None
    depth_evidence_passed: bool | None = None
    optional_evidence_ref: str | None = None
    claim_source: Literal["server_live", "local_demo_replay"] = "server_live"
    request_signature: str


class AttendanceDecision(BaseModel):
    accepted: bool
    reason_code: str
    confidence_band: Literal["high", "medium", "low"]
    step_up_required: bool
    review_ticket: str | None = None
    matched_person_id: str | None = None
    match_score: float
    quality_score: float
    liveness_score: float
    geofence_result: Literal["pass", "fail"]
    decision_origin: Literal["server", "local_demo"] = "server"


class AttendanceEvent(BaseModel):
    id: str
    created_at: datetime
    tenant_id: str
    person_id: str | None
    matched_person_id: str | None
    site_id: str
    claimed_identity_mode: Literal["1:1", "1:n"]
    client_timestamp: datetime
    gps: GeoPoint
    app_version: str
    reason_code: str
    accepted: bool
    step_up_required: bool
    quality_score: float
    liveness_score: float
    match_score: float
    geofence_result: Literal["pass", "fail"]
    claim_source: Literal["server_live", "local_demo_replay"] = "server_live"
    decision_origin: Literal["server", "local_demo"] = "server"
    optional_evidence_ref: str | None = None
    capture_id: str | None = None
    capture_file_path: str | None = None
    person_display_name: str | None = None
    matched_person_display_name: str | None = None
    site_label: str | None = None


class ReviewTicket(BaseModel):
    id: str
    event_id: str
    tenant_id: str
    reason_code: str
    status: Literal["open", "resolved"] = "open"
    created_at: datetime = Field(default_factory=utc_now)
    resolved_at: datetime | None = None
    resolution: str | None = None


class ReviewResolutionRequest(BaseModel):
    resolution: str


class AdminOverview(BaseModel):
    tenant_count: int
    person_count: int
    attendance_event_count: int
    open_review_count: int
    sites: list[WorkSite]
    recent_events: list[AttendanceEvent]


class RuntimeProfileResponse(BaseModel):
    method_stack: MethodStackProfile
    capture_profile: DeploymentProfile
    deployment_profiles: list[DeploymentProfile]
    face_demo_runtime: RuntimeSelectionStatus


class MobileBootstrapTenant(BaseModel):
    id: str
    name: str
    timezone: str


class ActiveClassSession(BaseModel):
    id: str
    tenant_id: str
    site_id: str
    site_label: str
    class_label: str
    canonical_lan_url: str | None = None
    started_at: datetime
    ends_at: datetime | None = None
    active: bool = True


class MobileBootstrapResponse(BaseModel):
    tenant: MobileBootstrapTenant
    policy: TenantPolicy
    people: list[Person]
    sites: list[WorkSite]
    linked_person: Person | None = None
    active_class_session: ActiveClassSession | None = None
    live_person: Person | None = None
    live_site: WorkSite | None = None
    wifi_ipv4: str | None = None
    canonical_lan_url: str | None = None
    backend_bind_host: str | None = None
    lan_ready: bool = False
    network_hint: str | None = None
    server_time: datetime
    method_stack: MethodStackProfile
    capture_profile: DeploymentProfile


class DemoSessionStartResponse(BaseModel):
    person: Person
    site: WorkSite
    bootstrap: MobileBootstrapResponse
    session_mode: Literal["server_live_demo"] = "server_live_demo"


class DemoControlSession(BaseModel):
    tenant_id: str
    person_id: str | None = None
    site_id: str | None = None
    display_name: str | None = None
    started_at: datetime | None = None
    last_mac_enrollment_at: datetime | None = None
    last_mac_quality_score: float | None = None
    last_mac_detection_score: float | None = None
    last_mac_bbox: BoundingBox | None = None
    phone_last_seen_at: datetime | None = None
    phone_last_status_source: str | None = None
    phone_last_app_version: str | None = None


class ClassSessionStartRequest(BaseModel):
    tenant_id: str = "truepresence-demo"
    site_id: str
    class_label: str | None = None


class ClassSessionStartResponse(BaseModel):
    active_class_session: ActiveClassSession
    bootstrap: MobileBootstrapResponse


class ClassSessionStopResponse(BaseModel):
    active_class_session: ActiveClassSession | None = None


class DemoControlResetResponse(BaseModel):
    reset_scope: Literal["full_demo_reset"] = "full_demo_reset"
    cleared_event_count: int
    cleared_review_count: int
    cleared_demo_person_count: int
    cleared_demo_site_count: int
    cleared_template_count: int
    cleared_demo_face_count: int


class DemoControlSessionStartResponse(BaseModel):
    session: DemoControlSession
    person: Person
    site: WorkSite
    bootstrap: MobileBootstrapResponse
    session_mode: Literal["lan_realtime_demo"] = "lan_realtime_demo"


class DemoControlEnrollFromMacRequest(BaseModel):
    tenant_id: str = "truepresence-demo"
    person_id: str
    image_base64: str
    source: Literal["mac_camera", "mac_upload"] = "mac_camera"
    sequence_id: str | None = None
    shot_index: int = 1
    shot_role: str | None = None


class DemoControlPersonCreateRequest(BaseModel):
    tenant_id: str = "truepresence-demo"
    display_name: str


class DemoControlPersonSummary(BaseModel):
    id: str
    tenant_id: str
    employee_code: str
    display_name: str
    person_kind: Literal["seeded", "demo"]
    site_ids: list[str] = Field(default_factory=list)
    template_count: int = 0
    capture_count: int = 0
    deletable: bool = False
    active_live_session: bool = False


class DeviceBindingToken(BaseModel):
    token: str
    tenant_id: str
    person_id: str
    created_at: datetime
    expires_at: datetime
    consumed_at: datetime | None = None
    consumed_device_id: str | None = None


class DeviceBindingTokenResponse(BaseModel):
    person: Person
    token: str
    qr_payload: str
    expires_at: datetime


class DeviceLink(BaseModel):
    id: str
    tenant_id: str
    person_id: str
    device_id: str
    provider: str
    bound_at: datetime
    last_claimed_at: datetime


class DeviceLinkClaimRequest(BaseModel):
    token: str
    device_attestation: DeviceAttestation


class DeviceLinkClaimResponse(BaseModel):
    linked_person: Person
    bootstrap: MobileBootstrapResponse
    linked_at: datetime


class DeviceLinkClearRequest(BaseModel):
    tenant_id: str
    device_attestation: DeviceAttestation


class DeviceLinkClearResponse(BaseModel):
    cleared: bool
    tenant_id: str
    device_id: str


class DemoCaptureRecord(BaseModel):
    id: str
    tenant_id: str
    person_id: str | None = None
    person_display_name: str | None = None
    source: Literal["mac_camera", "mac_upload", "iphone_verify"]
    stage: Literal["enrollment", "verification"]
    file_path: str
    created_at: datetime
    sequence_id: str | None = None
    shot_index: int | None = None
    shot_role: str | None = None
    image_width: int | None = None
    image_height: int | None = None
    quality_score: float | None = None
    detection_score: float | None = None
    liveness_score: float | None = None
    match_score: float | None = None
    bbox_confidence: float | None = None
    depth_present: bool | None = None
    depth_coverage: float | None = None
    depth_variance: float | None = None
    depth_evidence_passed: bool | None = None
    event_id: str | None = None


class DemoTemplateSummary(BaseModel):
    id: str
    tenant_id: str
    person_id: str
    person_display_name: str | None = None
    source: str
    created_at: datetime
    capture_digest: str


class DemoControlEnrollmentResponse(BaseModel):
    person: Person
    site: WorkSite | None = None
    template_id: str
    template_count: int
    template_scheme: str
    capture_id: str | None = None
    quality_score: float
    detection_score: float
    bbox: BoundingBox | None = None
    image_width: int | None = None
    image_height: int | None = None
    detected_face_count: int = 0
    manifests: list[ProviderManifest] = Field(default_factory=list)


class DemoControlSnapshot(BaseModel):
    overview: AdminOverview
    live_session: DemoControlSession | None = None
    live_person: Person | None = None
    live_site: WorkSite | None = None
    active_class_session: ActiveClassSession | None = None
    wifi_ipv4: str | None = None
    canonical_lan_url: str | None = None
    backend_bind_host: str | None = None
    lan_ready: bool = False
    network_hint: str | None = None
    people_summary: list[DemoControlPersonSummary] = Field(default_factory=list)
    template_summary: list[DemoTemplateSummary] = Field(default_factory=list)
    capture_summary: list[DemoCaptureRecord] = Field(default_factory=list)
    recent_events: list[AttendanceEvent] = Field(default_factory=list)
    latest_event: AttendanceEvent | None = None
    face_demo_runtime: RuntimeSelectionStatus
    capture_profile: DeploymentProfile
    method_stack: MethodStackProfile


class RepositoryState(BaseModel):
    tenants: dict[str, Tenant] = Field(default_factory=dict)
    sites: dict[str, WorkSite] = Field(default_factory=dict)
    people: dict[str, Person] = Field(default_factory=dict)
    enrollment_sessions: dict[str, EnrollmentSession] = Field(default_factory=dict)
    templates: dict[str, dict] = Field(default_factory=dict)
    captures: dict[str, dict] = Field(default_factory=dict)
    demo_faces: dict[str, dict] = Field(default_factory=dict)
    attendance_events: dict[str, AttendanceEvent] = Field(default_factory=dict)
    review_tickets: dict[str, ReviewTicket] = Field(default_factory=dict)
    binding_tokens: dict[str, DeviceBindingToken] = Field(default_factory=dict)
    device_links: dict[str, DeviceLink] = Field(default_factory=dict)
    active_class_session: ActiveClassSession | None = None
    demo_control: DemoControlSession = Field(
        default_factory=lambda: DemoControlSession(tenant_id="truepresence-demo")
    )
