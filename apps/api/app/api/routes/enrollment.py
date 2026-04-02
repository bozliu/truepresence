from __future__ import annotations

from fastapi import APIRouter, Depends

from ...dependencies import get_service
from ...models import (
    EnrollmentCaptureRecord,
    EnrollmentCaptureRequest,
    EnrollmentFinalizeResponse,
    EnrollmentSession,
    EnrollmentSessionCreate,
    Person,
    PersonCreateRequest,
)
from ...service import AttendanceService

router = APIRouter(prefix="/v1", tags=["enrollment"])


@router.post("/people", response_model=Person)
def create_person(
    request: PersonCreateRequest, service: AttendanceService = Depends(get_service)
) -> Person:
    return service.create_person(request)


@router.get("/people", response_model=list[Person])
def list_people(
    tenant_id: str | None = None, service: AttendanceService = Depends(get_service)
) -> list[Person]:
    return service.list_people(tenant_id)


@router.post("/enrollment/sessions", response_model=EnrollmentSession)
def create_enrollment_session(
    request: EnrollmentSessionCreate, service: AttendanceService = Depends(get_service)
) -> EnrollmentSession:
    return service.create_enrollment_session(request)


@router.post(
    "/enrollment/sessions/{session_id}/captures",
    response_model=EnrollmentCaptureRecord,
)
def add_capture(
    session_id: str,
    request: EnrollmentCaptureRequest,
    service: AttendanceService = Depends(get_service),
) -> EnrollmentCaptureRecord:
    return service.add_enrollment_capture(session_id, request)


@router.post(
    "/enrollment/sessions/{session_id}/finalize",
    response_model=EnrollmentFinalizeResponse,
)
def finalize_session(
    session_id: str, service: AttendanceService = Depends(get_service)
) -> EnrollmentFinalizeResponse:
    return service.finalize_enrollment(session_id)
