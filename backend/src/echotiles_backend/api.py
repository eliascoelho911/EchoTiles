"""API HTTP sem trabalho de download ou análise no processo de requisições."""

import re

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse
from starlette.exceptions import HTTPException

from .config import Settings
from .models import BackendError, ImportRequest, canonical_source, error_value
from .storage import Storage


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    storage = Storage(settings.data_dir)
    app = FastAPI(title="EchoTiles", docs_url=None, redoc_url=None)

    @app.exception_handler(BackendError)
    async def backend_error(request, exc):
        return JSONResponse({"error": exc.error}, status_code=400)

    @app.exception_handler(RequestValidationError)
    async def validation_error(request, exc):
        return JSONResponse({"error": error_value("invalid_url")}, status_code=400)

    @app.exception_handler(HTTPException)
    async def http_error(request, exc):
        return JSONResponse(
            {"error": error_value("unavailable")}, status_code=exc.status_code, headers=exc.headers
        )

    @app.exception_handler(Exception)
    async def internal_error(request, exc):
        return JSONResponse({"error": error_value("internal_error")}, status_code=500)

    @app.get("/api/health")
    def health():
        return {"status": "ok", "schemaVersion": 1}

    @app.post("/api/imports", status_code=202)
    def create_import(request: ImportRequest):
        return storage.enqueue(canonical_source(request.url, request.kind), request.kind)

    @app.get("/api/imports")
    def list_imports():
        return {"imports": storage.list_imports()}

    @app.get("/api/imports/{import_id}")
    def read_import(import_id: str):
        result = storage.get_import(import_id)
        if result is None:
            raise HTTPException(404)
        return result

    @app.get("/api/tracks")
    def list_tracks():
        return {"tracks": storage.list_tracks()}

    @app.get("/api/tracks/{track_id}")
    def read_track(track_id: str):
        result = storage.get_track(track_id)
        if result is None:
            raise HTTPException(404)
        return result

    @app.get("/api/tracks/{track_id}/audio")
    def read_audio(track_id: str, request: Request):
        path = storage.audio_path(track_id)
        if path is None:
            raise HTTPException(404)
        # FileResponse responde erros de Range em texto; conserve o envelope JSON do contrato.
        if value := request.headers.get("range"):
            size = path.stat().st_size
            try:
                if not value.startswith("bytes="):
                    raise ValueError
                for part in value[6:].split(","):
                    match = re.fullmatch(r"\s*(\d*)-(\d*)\s*", part)
                    if not match or not any(match.groups()):
                        raise ValueError
                    start, end = match.groups()
                    if start and (int(start) >= size or (end and int(end) < int(start))):
                        raise ValueError
                    if not start and int(end) == 0:
                        raise ValueError
            except ValueError:
                raise HTTPException(416, headers={"Content-Range": f"bytes */{size}"}) from None
        return FileResponse(path, media_type="audio/mp4")

    @app.get("/api/charts/{chart_id}")
    def read_chart(chart_id: str):
        result = storage.get_chart(chart_id)
        if result is None:
            raise HTTPException(404)
        return result

    return app
