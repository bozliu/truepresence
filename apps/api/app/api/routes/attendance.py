from __future__ import annotations

from fastapi import APIRouter, Depends
from fastapi.responses import PlainTextResponse

from ...dependencies import get_service
from ...models import AttendanceClaimRequest, AttendanceDecision, AttendanceEvent
from ...service import AttendanceService

router = APIRouter(prefix="/v1", tags=["attendance"])


@router.post("/attendance/claims", response_model=AttendanceDecision)
def submit_attendance_claim(
    request: AttendanceClaimRequest, service: AttendanceService = Depends(get_service)
) -> AttendanceDecision:
    return service.submit_attendance_claim(request)


@router.get("/attendance/events", response_model=list[AttendanceEvent])
def list_events(
    tenant_id: str | None = None,
    person_id: str | None = None,
    limit: int | None = None,
    service: AttendanceService = Depends(get_service),
) -> list[AttendanceEvent]:
    return service.list_events(tenant_id=tenant_id, person_id=person_id, limit=limit)


@router.get("/attendance/export.csv", response_class=PlainTextResponse)
def export_attendance(service: AttendanceService = Depends(get_service)) -> str:
    return service.export_attendance_csv()
