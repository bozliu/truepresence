from __future__ import annotations

import asyncio

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import FileResponse, StreamingResponse

from ...dependencies import get_service
from ...models import (
    AdminOverview,
    ClassSessionStartRequest,
    ClassSessionStartResponse,
    ClassSessionStopResponse,
    DemoCaptureRecord,
    DemoControlEnrollmentResponse,
    DemoControlEnrollFromMacRequest,
    DemoControlPersonCreateRequest,
    DemoControlPersonSummary,
    DemoControlResetResponse,
    DemoControlSessionStartResponse,
    DemoControlSnapshot,
    DemoFaceRecognitionRequest,
    DemoFaceRecognitionResponse,
    DemoFaceRecord,
    DemoFaceRegisterRequest,
    DemoSessionStartRequest,
    DemoSessionStartResponse,
    DeviceBindingTokenResponse,
    DeviceLinkClearRequest,
    DeviceLinkClearResponse,
    DeviceLinkClaimRequest,
    DeviceLinkClaimResponse,
    MobileBootstrapResponse,
    Person,
    ReviewResolutionRequest,
    ReviewTicket,
    RuntimeProfileResponse,
    Tenant,
    TenantPolicy,
    WorkSite,
)
from ...service import AttendanceService

router = APIRouter(prefix="/v1", tags=["operations"])


@router.get("/tenants", response_model=list[Tenant])
def list_tenants(service: AttendanceService = Depends(get_service)) -> list[Tenant]:
    return service.list_tenants()


@router.get("/tenants/{tenant_id}/policy", response_model=TenantPolicy)
def get_policy(tenant_id: str, service: AttendanceService = Depends(get_service)) -> TenantPolicy:
    return service.get_policy(tenant_id)


@router.get("/sites", response_model=list[WorkSite])
def list_sites(service: AttendanceService = Depends(get_service)) -> list[WorkSite]:
    return service.list_sites()


@router.get("/review-tickets", response_model=list[ReviewTicket])
def list_review_tickets(
    service: AttendanceService = Depends(get_service),
) -> list[ReviewTicket]:
    return service.list_review_tickets()


@router.post("/review-tickets/{ticket_id}/resolve", response_model=ReviewTicket)
def resolve_review_ticket(
    ticket_id: str,
    request: ReviewResolutionRequest,
    service: AttendanceService = Depends(get_service),
) -> ReviewTicket:
    return service.resolve_review_ticket(ticket_id, request)


@router.get("/admin/overview", response_model=AdminOverview)
def admin_overview(service: AttendanceService = Depends(get_service)) -> AdminOverview:
    return service.admin_overview()


@router.get("/method-stack", response_model=RuntimeProfileResponse)
def method_stack(service: AttendanceService = Depends(get_service)) -> RuntimeProfileResponse:
    return service.runtime_profile()


@router.get("/mobile/bootstrap", response_model=MobileBootstrapResponse)
def mobile_bootstrap(
    tenant_id: str,
    device_id: str | None = None,
    service: AttendanceService = Depends(get_service),
) -> MobileBootstrapResponse:
    return service.mobile_bootstrap(tenant_id, device_id=device_id)


@router.post("/mobile/device-link/claim", response_model=DeviceLinkClaimResponse)
def mobile_device_link_claim(
    request: DeviceLinkClaimRequest,
    service: AttendanceService = Depends(get_service),
) -> DeviceLinkClaimResponse:
    try:
        return service.claim_device_link(request)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error


@router.post("/mobile/device-link/clear", response_model=DeviceLinkClearResponse)
def mobile_device_link_clear(
    request: DeviceLinkClearRequest,
    service: AttendanceService = Depends(get_service),
) -> DeviceLinkClearResponse:
    try:
        return service.clear_device_link(request)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error


@router.post("/mobile/demo-session/start", response_model=DemoSessionStartResponse)
def mobile_demo_session_start(
    request: DemoSessionStartRequest,
    service: AttendanceService = Depends(get_service),
) -> DemoSessionStartResponse:
    try:
        return service.mobile_demo_session_start(request)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error


@router.post("/demo/control/class-session/start", response_model=ClassSessionStartResponse)
def demo_control_class_session_start(
    request: ClassSessionStartRequest,
    service: AttendanceService = Depends(get_service),
) -> ClassSessionStartResponse:
    try:
        return service.start_class_session(request)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error


@router.post("/demo/control/class-session/stop", response_model=ClassSessionStopResponse)
def demo_control_class_session_stop(
    tenant_id: str = "truepresence-demo",
    service: AttendanceService = Depends(get_service),
) -> ClassSessionStopResponse:
    return service.stop_class_session(tenant_id=tenant_id)


@router.post("/demo/control/reset", response_model=DemoControlResetResponse)
def demo_control_reset(
    tenant_id: str = "truepresence-demo",
    service: AttendanceService = Depends(get_service),
) -> DemoControlResetResponse:
    return service.demo_control_reset(tenant_id=tenant_id)


@router.post("/demo/control/session/start", response_model=DemoControlSessionStartResponse)
def demo_control_session_start(
    request: DemoSessionStartRequest,
    service: AttendanceService = Depends(get_service),
) -> DemoControlSessionStartResponse:
    try:
        return service.demo_control_session_start(request)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error


@router.post("/demo/control/enroll-from-mac", response_model=DemoControlEnrollmentResponse)
def demo_control_enroll_from_mac(
    request: DemoControlEnrollFromMacRequest,
    service: AttendanceService = Depends(get_service),
) -> DemoControlEnrollmentResponse:
    try:
        return service.demo_control_enroll_from_mac(request)
    except RuntimeError as error:
        raise HTTPException(status_code=503, detail=str(error)) from error
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error


@router.get("/demo/control/snapshot", response_model=DemoControlSnapshot)
def demo_control_snapshot(
    tenant_id: str = "truepresence-demo",
    service: AttendanceService = Depends(get_service),
) -> DemoControlSnapshot:
    return service.demo_control_snapshot(tenant_id=tenant_id)


@router.get("/demo/control/people", response_model=list[DemoControlPersonSummary])
def demo_control_people(
    tenant_id: str = "truepresence-demo",
    service: AttendanceService = Depends(get_service),
) -> list[DemoControlPersonSummary]:
    return service.list_demo_control_people(tenant_id=tenant_id)


@router.post("/demo/control/people", response_model=Person)
def demo_control_create_person(
    request: DemoControlPersonCreateRequest,
    service: AttendanceService = Depends(get_service),
) -> Person:
    return service.create_demo_person(request)


@router.post("/demo/control/people/{person_id}/binding-token", response_model=DeviceBindingTokenResponse)
def demo_control_create_binding_token(
    person_id: str,
    tenant_id: str = "truepresence-demo",
    service: AttendanceService = Depends(get_service),
) -> DeviceBindingTokenResponse:
    try:
        return service.create_binding_token(tenant_id=tenant_id, person_id=person_id)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error


@router.delete("/demo/control/people/{person_id}")
def demo_control_delete_person(
    person_id: str,
    tenant_id: str = "truepresence-demo",
    service: AttendanceService = Depends(get_service),
) -> dict[str, int | str]:
    try:
        return service.delete_demo_person(person_id=person_id, tenant_id=tenant_id)
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error


@router.get("/demo/control/captures", response_model=list[DemoCaptureRecord])
def demo_control_captures(
    tenant_id: str = "truepresence-demo",
    person_id: str | None = None,
    limit: int | None = 50,
    service: AttendanceService = Depends(get_service),
) -> list[DemoCaptureRecord]:
    return service.list_demo_control_captures(tenant_id=tenant_id, person_id=person_id, limit=limit)


@router.get("/demo/control/captures/{capture_id}/image")
def demo_control_capture_image(
    capture_id: str,
    service: AttendanceService = Depends(get_service),
) -> FileResponse:
    try:
        return FileResponse(service.demo_capture_file(capture_id), media_type="image/jpeg")
    except ValueError as error:
        raise HTTPException(status_code=404, detail=str(error)) from error


@router.post("/demo/control/events/clear")
def demo_control_clear_events(
    tenant_id: str = "truepresence-demo",
    service: AttendanceService = Depends(get_service),
) -> dict[str, int | str]:
    return service.clear_demo_control_events(tenant_id=tenant_id)


@router.get("/demo/control/stream")
async def demo_control_stream(
    tenant_id: str = "truepresence-demo",
    service: AttendanceService = Depends(get_service),
) -> StreamingResponse:
    async def event_generator():
        last_revision = -1
        while True:
            current_revision = service.stream_revision()
            if current_revision != last_revision:
                snapshot = service.demo_control_snapshot(tenant_id=tenant_id)
                yield f"event: snapshot\ndata: {snapshot.model_dump_json()}\n\n"
                last_revision = current_revision
            else:
                yield ": keep-alive\n\n"
            await asyncio.sleep(1)

    return StreamingResponse(event_generator(), media_type="text/event-stream")


@router.get("/demo/faces", response_model=list[DemoFaceRecord])
def list_demo_faces(
    tenant_id: str | None = None,
    service: AttendanceService = Depends(get_service),
) -> list[DemoFaceRecord]:
    return service.list_demo_faces(tenant_id=tenant_id)


@router.post("/demo/faces/register", response_model=DemoFaceRecord)
def register_demo_face(
    request: DemoFaceRegisterRequest,
    service: AttendanceService = Depends(get_service),
) -> DemoFaceRecord:
    try:
        return service.register_demo_face(request)
    except RuntimeError as error:
        raise HTTPException(status_code=503, detail=str(error)) from error
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error


@router.post("/demo/faces/recognize", response_model=DemoFaceRecognitionResponse)
def recognize_demo_face(
    request: DemoFaceRecognitionRequest,
    service: AttendanceService = Depends(get_service),
) -> DemoFaceRecognitionResponse:
    try:
        return service.recognize_demo_face(request)
    except RuntimeError as error:
        raise HTTPException(status_code=503, detail=str(error)) from error
    except ValueError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error
