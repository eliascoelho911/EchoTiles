import hashlib
import threading
import time

import psutil
import pytest
from conftest import FakeDownloader, ResolvedSource, VideoReference
from fastapi.testclient import TestClient

from echotiles_backend.analysis import generate_chart
from echotiles_backend.api import create_app
from echotiles_backend.config import Settings
from echotiles_backend.storage import Storage
from echotiles_backend.worker import Worker

URL = "https://www.youtube.com/watch?v=BaW_jenozKc"
PLAYLIST = "https://www.youtube.com/playlist?list=PL1234567890"


def test_partial_playlist_keeps_ready_items(tmp_path, playback):
    settings = Settings(data_dir=tmp_path / "data")
    fake = FakeDownloader(
        playback,
        [
            VideoReference("BaW_jenozKc", URL, "Primeira"),
            VideoReference(None, None, None, unavailable=True),
            VideoReference("jNQXAC9IVRw", "https://www.youtube.com/watch?v=jNQXAC9IVRw", "Última"),
        ],
    )
    with TestClient(create_app(settings)) as client:
        job = client.post("/api/imports", json={"url": PLAYLIST}).json()
        assert Worker(settings, downloader=fake).run_once()
        result = client.get(f"/api/imports/{job['id']}").json()
        assert result["status"] == "partial"
        assert result["totalItems"] == 3
        assert result["readyItems"] == 2
        assert result["failedItems"] == 1
        assert [item["index"] for item in result["items"]] == [0, 1, 2]
        assert [item["status"] for item in result["items"]] == ["ready", "failed", "ready"]
        assert result["items"][1]["error"]["code"] == "unavailable"
        assert len(client.get("/api/tracks").json()["tracks"]) == 2


def test_api_remains_responsive_during_download(tmp_path, playback):
    settings = Settings(data_dir=tmp_path / "data")
    worker = Worker(settings, downloader=FakeDownloader(playback, delay=0.8))
    with TestClient(create_app(settings)) as client:
        client.post("/api/imports", json={"url": URL})
        thread = threading.Thread(target=worker.run_once)
        thread.start()
        try:
            time.sleep(0.15)
            before = time.monotonic()
            assert client.get("/api/health").json() == {"status": "ok", "schemaVersion": 1}
            assert client.get("/api/imports").status_code == 200
            assert time.monotonic() - before < 0.4
        finally:
            thread.join(30)
        assert not thread.is_alive()


def test_duplicate_reuses_intact_track(tmp_path, playback):
    settings = Settings(data_dir=tmp_path / "data")
    with TestClient(create_app(settings)) as client:
        first = client.post("/api/imports", json={"url": URL}).json()
        Worker(settings, downloader=FakeDownloader(playback)).run_once()
        second = client.post("/api/imports", json={"url": URL}).json()
        Worker(settings, downloader=FakeDownloader(playback, fail=True)).run_once()
        first_item = client.get(f"/api/imports/{first['id']}").json()["items"][0]
        second_result = client.get(f"/api/imports/{second['id']}").json()
        assert second_result["status"] == "completed"
        assert second_result["items"][0]["trackId"] == first_item["trackId"]
        assert len(client.get("/api/tracks").json()["tracks"]) == 1


def test_quota_interrupts_transfer_and_keeps_library_empty(tmp_path, playback):
    settings = Settings(data_dir=tmp_path / "data", cache_limit_bytes=100_000)
    with TestClient(create_app(settings)) as client:
        job = client.post("/api/imports", json={"url": URL}).json()
        Worker(settings, downloader=FakeDownloader(playback, grow_bytes=200_000)).run_once()
        result = client.get(f"/api/imports/{job['id']}").json()
        assert result["status"] == "failed"
        assert result["items"][0]["error"]["code"] == "disk_quota"
        assert client.get("/api/tracks").json() == {"tracks": []}
        assert not list(Storage(settings.data_dir).staging.iterdir())


def test_quota_also_stops_descendant_with_its_own_session(tmp_path, playback):
    settings = Settings(data_dir=tmp_path / "data", cache_limit_bytes=100_000)
    pid_file = tmp_path / "detached.pid"
    fake = FakeDownloader(playback, grow_bytes=200_000, detached_pid_file=pid_file)
    child = None
    try:
        with TestClient(create_app(settings)) as client:
            job = client.post("/api/imports", json={"url": URL}).json()
            Worker(settings, downloader=fake).run_once()
            result = client.get(f"/api/imports/{job['id']}").json()
            assert result["items"][0]["error"]["code"] == "disk_quota"
        child = (
            psutil.Process(int(pid_file.read_text()))
            if psutil.pid_exists(int(pid_file.read_text()))
            else None
        )
        assert child is None or not child.is_running() or child.status() == psutil.STATUS_ZOMBIE
    finally:
        if pid_file.exists():
            try:
                process = psutil.Process(int(pid_file.read_text()))
                process.kill()
                psutil.wait_procs([process], timeout=1)
            except psutil.NoSuchProcess:
                pass


def test_audio_range_chart_and_catalog_persist_after_restart(tmp_path, playback):
    settings = Settings(data_dir=tmp_path / "data")
    with TestClient(create_app(settings)) as client:
        client.post("/api/imports", json={"url": URL})
        Worker(settings, downloader=FakeDownloader(playback)).run_once()
        track = client.get("/api/tracks").json()["tracks"][0]
    with TestClient(create_app(settings)) as client:
        assert client.get(f"/api/tracks/{track['id']}").json() == track
        full = client.get(track["audioUrl"])
        assert full.headers["content-type"] == "audio/mp4"
        assert int(full.headers["content-length"]) == track["audioBytes"] == len(full.content)
        assert hashlib.sha256(full.content).hexdigest() == track["audioSha256"]
        partial = client.get(track["audioUrl"], headers={"Range": "bytes=7-38"})
        assert partial.status_code == 206
        assert partial.content == full.content[7:39]
        assert partial.headers["content-range"] == f"bytes 7-38/{len(full.content)}"
        assert int(partial.headers["content-length"]) == 32
        suffix = client.get(track["audioUrl"], headers={"Range": "bytes=-16"})
        assert suffix.status_code == 206
        assert suffix.content == full.content[-16:]
        for value in ["bytes=99999999-", "bytes=5-1", "bytes=-0", "invalid", "bytes=-"]:
            invalid = client.get(track["audioUrl"], headers={"Range": value})
            assert invalid.status_code == 416
            assert invalid.json()["error"]["code"] == "unavailable"
            assert invalid.headers["content-range"] == f"bytes */{len(full.content)}"
        chart = client.get(track["chartUrl"]).json()
        assert chart["id"] == track["chartId"]
        assert chart["durationMs"] == track["durationMs"] == 4000
        assert chart["audioSha256"] == track["audioSha256"]


def test_restart_recovers_interrupted_items_in_order(tmp_path, playback):
    settings = Settings(data_dir=tmp_path / "data")
    storage = Storage(settings.data_dir)
    job = storage.enqueue(PLAYLIST, "playlist")
    storage.claim_import()
    refs = (
        VideoReference("BaW_jenozKc", URL, "Primeira"),
        VideoReference("jNQXAC9IVRw", "https://youtu.be/jNQXAC9IVRw", "Segunda"),
    )
    storage.resolve_import(job["id"], ResolvedSource("playlist", "Fonte", refs))
    first = storage.pending_items(job["id"])[0]
    storage.update_item(first["id"], "analyzing", 0.8)
    (storage.staging / "interrupted").mkdir()
    (storage.media / "orphan").mkdir()
    storage.recover()
    assert not list(storage.staging.iterdir())
    assert not list(storage.media.iterdir())
    assert Worker(settings, downloader=FakeDownloader(playback, refs)).run_once()
    result = Storage(settings.data_dir).get_import(job["id"])
    assert result["status"] == "completed"
    assert [item["title"] for item in result["items"]] == ["Primeira", "Segunda"]
    assert all(item["status"] == "ready" for item in result["items"])


@pytest.mark.parametrize("ready_first", [False, True], ids=["video", "playlist_with_ready_item"])
def test_stop_during_download_recovers_without_losing_ready_items(tmp_path, playback, ready_first):
    settings = Settings(data_dir=tmp_path / "data")
    pid_file = tmp_path / "stopped-download.pid"
    refs = [VideoReference("BaW_jenozKc", URL, "Primeira")]
    with TestClient(create_app(settings)) as client:
        ready_track = None
        if ready_first:
            # A primeira entrada da playlist já está íntegra no catálogo.
            client.post("/api/imports", json={"url": URL})
            Worker(settings, downloader=FakeDownloader(playback)).run_once()
            ready_track = client.get("/api/tracks").json()["tracks"][0]
            refs.append(VideoReference("jNQXAC9IVRw", "https://youtu.be/jNQXAC9IVRw", "Segunda"))
        job = client.post("/api/imports", json={"url": PLAYLIST if ready_first else URL}).json()
        worker = Worker(
            settings,
            downloader=FakeDownloader(playback, refs, delay=10, detached_pid_file=pid_file),
        )
        thread = threading.Thread(target=worker.run_once)
        thread.start()
        try:
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                active = client.get(f"/api/imports/{job['id']}").json()
                if (
                    active["items"]
                    and active["items"][-1]["status"] == "downloading"
                    and active["items"][-1]["progress"] == 0.2
                ):
                    break
                time.sleep(0.01)
            else:
                pytest.fail("O download não informou progresso antes do prazo.")
            assert active["readyItems"] == int(ready_first)
            worker.stopping = True  # Mesmo caminho do handler SIGTERM/SIGINT.
            thread.join(5)
            assert not thread.is_alive()
            stopped = client.get(f"/api/imports/{job['id']}").json()
            assert stopped["status"] == "running"
            assert stopped["items"][-1]["status"] == "downloading"
            assert stopped["items"][-1]["error"] is None
            assert stopped["failedItems"] == 0
            assert not list(Storage(settings.data_dir).staging.iterdir())
            pid = int(pid_file.read_text())
            assert (
                not psutil.pid_exists(pid) or psutil.Process(pid).status() == psutil.STATUS_ZOMBIE
            )
            if ready_first:
                assert stopped["items"][0]["trackId"] == ready_track["id"]
                assert client.get(f"/api/tracks/{ready_track['id']}").json() == ready_track

            replacement = Worker(settings, downloader=FakeDownloader(playback, refs))
            replacement.storage.recover()
            recovered = client.get(f"/api/imports/{job['id']}").json()
            assert recovered["status"] == "queued"
            assert recovered["items"][-1]["status"] == "queued"
            assert recovered["items"][-1]["progress"] is None
            assert recovered["readyItems"] == int(ready_first)
            assert replacement.run_once()
            completed = client.get(f"/api/imports/{job['id']}").json()
            assert completed["status"] == "completed"
            assert completed["readyItems"] == len(refs)
            assert completed["failedItems"] == 0
            if ready_first:
                assert completed["items"][0]["trackId"] == ready_track["id"]
                assert client.get(f"/api/tracks/{ready_track['id']}").json() == ready_track
        finally:
            worker.stopping = True
            thread.join(5)
            if pid_file.exists():
                try:
                    process = psutil.Process(int(pid_file.read_text()))
                    process.kill()
                    psutil.wait_procs([process], timeout=1)
                except psutil.NoSuchProcess:
                    pass


def test_download_timeout_stays_failed_after_recovery(tmp_path, playback):
    settings = Settings(data_dir=tmp_path / "data", download_timeout_seconds=0.5)
    with TestClient(create_app(settings)) as client:
        job = client.post("/api/imports", json={"url": URL}).json()
        Worker(settings, downloader=FakeDownloader(playback, delay=10)).run_once()
        failed = client.get(f"/api/imports/{job['id']}").json()
        assert failed["status"] == "failed"
        assert failed["items"][0]["status"] == "failed"
        assert failed["items"][0]["error"]["code"] == "download_failed"
        assert failed["items"][0]["error"]["retryable"] is True
        assert not list(Storage(settings.data_dir).staging.iterdir())
        replacement = Worker(settings, downloader=FakeDownloader(playback))
        replacement.storage.recover()
        assert not replacement.run_once()
        assert client.get(f"/api/imports/{job['id']}").json() == failed


def test_corrupt_cache_is_not_reused(tmp_path, playback):
    settings = Settings(data_dir=tmp_path / "data")
    with TestClient(create_app(settings)) as client:
        client.post("/api/imports", json={"url": URL})
        Worker(settings, downloader=FakeDownloader(playback)).run_once()
        old = client.get("/api/tracks").json()["tracks"][0]
        audio = Storage(settings.data_dir).audio_path(old["id"])
        raw = bytearray(audio.read_bytes())
        raw[-1] ^= 1  # Corrupção com tamanho inalterado precisa invalidar o hash.
        audio.write_bytes(raw)
        second = client.post("/api/imports", json={"url": URL}).json()
        Worker(settings, downloader=FakeDownloader(playback)).run_once()
        assert client.get(f"/api/imports/{second['id']}").json()["status"] == "completed"
        assert client.get(f"/api/tracks/{old['id']}").status_code == 404
        tracks = client.get("/api/tracks").json()["tracks"]
        assert len(tracks) == 1
        assert tracks[0]["id"] != old["id"]


def test_download_error_never_exposes_raw_diagnostics(tmp_path, playback):
    settings = Settings(data_dir=tmp_path / "data")
    with TestClient(create_app(settings)) as client:
        job = client.post("/api/imports", json={"url": URL}).json()
        Worker(settings, downloader=FakeDownloader(playback, fail=True)).run_once()
        response = client.get(f"/api/imports/{job['id']}")
        assert response.json()["status"] == "failed"
        assert response.json()["items"][0]["error"]["code"] == "download_failed"
        assert response.json()["items"][0]["error"]["retryable"] is True
        assert not any(word in response.text for word in ["secret", "cdn.invalid", "cookie"])


def test_playlist_limit_is_rejected_before_downloading(tmp_path, playback):
    settings = Settings(data_dir=tmp_path / "data", max_playlist_items=1)
    refs = [VideoReference("BaW_jenozKc", URL)] * 2
    with TestClient(create_app(settings)) as client:
        job = client.post("/api/imports", json={"url": PLAYLIST}).json()
        Worker(settings, downloader=FakeDownloader(playback, refs)).run_once()
        result = client.get(f"/api/imports/{job['id']}").json()
        assert result["status"] == "failed"
        assert result["error"]["code"] == "playlist_limit"
        assert client.get("/api/tracks").json() == {"tracks": []}


def test_duration_limit_prevents_publication(tmp_path, playback):
    settings = Settings(data_dir=tmp_path / "data", max_duration_seconds=3)
    with TestClient(create_app(settings)) as client:
        job = client.post("/api/imports", json={"url": URL}).json()
        Worker(settings, downloader=FakeDownloader(playback)).run_once()
        result = client.get(f"/api/imports/{job['id']}").json()
        assert result["status"] == "failed"
        assert result["items"][0]["error"]["code"] == "duration_limit"
        assert client.get("/api/tracks").json() == {"tracks": []}


@pytest.mark.parametrize("field", ["durationMs", "audioSha256"])
def test_mismatched_chart_is_never_published(tmp_path, playback, field):
    settings = Settings(data_dir=tmp_path / "data")

    def invalid_chart(path, track_id, sha256):
        chart = generate_chart(path, track_id, sha256)
        chart[field] = 3900 if field == "durationMs" else "0" * 64
        return chart

    with TestClient(create_app(settings)) as client:
        job = client.post("/api/imports", json={"url": URL}).json()
        Worker(
            settings, downloader=FakeDownloader(playback), chart_generator=invalid_chart
        ).run_once()
        result = client.get(f"/api/imports/{job['id']}").json()
        assert result["status"] == "failed"
        assert result["items"][0]["error"]["code"] == "analysis_failed"
        assert client.get("/api/tracks").json() == {"tracks": []}
        assert not list(Storage(settings.data_dir).media.iterdir())
