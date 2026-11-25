import time

import pytest
from fastapi.testclient import TestClient

from echotiles_backend.api import create_app
from echotiles_backend.config import Settings


def test_import_is_queued_and_immediately_queryable(tmp_path):
    with TestClient(create_app(Settings(data_dir=tmp_path))) as client:
        before = time.monotonic()
        response = client.post(
            "/api/imports", json={"url": "https://youtu.be/BaW_jenozKc", "kind": "auto"}
        )
        elapsed = time.monotonic() - before
        assert response.status_code == 202
        assert elapsed < 0.5
        result = response.json()
        assert result["status"] == "queued"
        assert result["totalItems"] is None
        assert result["items"] == []
        assert client.get(f"/api/imports/{result['id']}").json() == result
        assert client.get("/api/imports").json() == {"imports": [result]}
        assert client.get("/api/tracks").json() == {"tracks": []}


@pytest.mark.parametrize(
    "url",
    [
        "file:///etc/passwd",
        "https://youtube.com.evil.invalid/watch?v=BaW_jenozKc",
        "https://user:pass@youtube.com/watch?v=BaW_jenozKc",
        "https://127.0.0.1/watch?v=BaW_jenozKc",
        "https://youtu.be/../../etc/passwd",
        "https://www.youtube.com/watch?v=bad",
        "https://www.youtube.com:1234/watch?v=BaW_jenozKc",
        "--exec secret",
    ],
)
def test_rejects_invalid_sources_without_resolving(tmp_path, url):
    with TestClient(create_app(Settings(data_dir=tmp_path))) as client:
        response = client.post("/api/imports", json={"url": url})
        assert response.status_code == 400
        assert response.json()["error"]["code"] == "invalid_url"
        assert response.json()["error"]["retryable"] is False
        assert client.get("/api/imports").json() == {"imports": []}


def test_auto_chooses_video_and_explicit_playlist_keeps_list(tmp_path):
    url = "https://www.youtube.com/watch?v=BaW_jenozKc&list=PL1234567890"
    with TestClient(create_app(Settings(data_dir=tmp_path))) as client:
        auto = client.post("/api/imports", json={"url": url, "kind": "auto"}).json()
        playlist = client.post("/api/imports", json={"url": url, "kind": "playlist"}).json()
        assert auto["sourceUrl"] == "https://www.youtube.com/watch?v=BaW_jenozKc"
        assert playlist["sourceUrl"] == "https://www.youtube.com/playlist?list=PL1234567890"
        assert client.get("/api/imports").json()["imports"][0]["id"] == playlist["id"]


def test_unknown_ids_and_validation_errors_are_sanitized(tmp_path):
    with TestClient(create_app(Settings(data_dir=tmp_path))) as client:
        for path in [
            "/api/imports/missing",
            "/api/tracks/missing",
            "/api/tracks/missing/audio",
            "/api/charts/missing",
        ]:
            response = client.get(path)
            assert response.status_code == 404
            assert set(response.json()) == {"error"}
        response = client.post("/api/imports", json={"url": 4, "command": "--exec secret"})
        assert response.status_code == 400
        assert "secret" not in response.text
        assert response.json()["error"]["code"] == "invalid_url"
