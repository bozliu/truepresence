from __future__ import annotations

from pathlib import Path
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import RedirectResponse
from fastapi.staticfiles import StaticFiles
from urllib.parse import unquote, unquote_to_bytes

from .api.routes.attendance import router as attendance_router
from .api.routes.enrollment import router as enrollment_router
from .api.routes.operations import router as operations_router


class EncodedQueryPathMiddleware:
    """Recover malformed URLs where query parameters were percent-encoded into the path."""

    def __init__(self, app) -> None:
        self.app = app

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        raw_path = scope.get("raw_path", b"")
        raw_path_lower = raw_path.lower()
        malformed_marker = b"%3f"
        if malformed_marker not in raw_path_lower:
            await self.app(scope, receive, send)
            return

        marker_index = raw_path_lower.index(malformed_marker)
        corrected_path_bytes = raw_path[:marker_index]
        encoded_query_bytes = raw_path[marker_index + len(malformed_marker) :]

        corrected_scope = dict(scope)
        corrected_scope["raw_path"] = corrected_path_bytes
        corrected_scope["path"] = unquote(corrected_path_bytes.decode("utf-8", errors="ignore"))

        corrected_query = unquote_to_bytes(encoded_query_bytes.decode("utf-8", errors="ignore"))
        existing_query = scope.get("query_string", b"")
        corrected_scope["query_string"] = (
            corrected_query if not existing_query else corrected_query + b"&" + existing_query
        )

        await self.app(corrected_scope, receive, send)


def create_app() -> FastAPI:
    app = FastAPI(
        title="TruePresence API",
        version="0.1.0",
        description="Teacher Mac + student iPhone classroom attendance API for TruePresence.",
    )
    admin_root = Path(__file__).resolve().parents[2] / "admin"
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=True,
        allow_methods=["*"],
        allow_headers=["*"],
    )
    app.add_middleware(EncodedQueryPathMiddleware)

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/teacher", include_in_schema=False)
    def teacher_console_redirect() -> RedirectResponse:
        return RedirectResponse(url="/teacher/")

    if admin_root.exists():
        app.mount("/teacher", StaticFiles(directory=admin_root, html=True), name="teacher-console")

    app.include_router(enrollment_router)
    app.include_router(attendance_router)
    app.include_router(operations_router)
    return app


app = create_app()
