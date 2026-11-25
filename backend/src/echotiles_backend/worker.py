"""Worker sequencial separado da API, com isolamento e quota durante download."""

import fcntl
import hashlib
import json
import multiprocessing
import os
import shutil
import signal
import time
from pathlib import Path
from types import SimpleNamespace

import psutil

from .analysis import generate_chart, validate_chart
from .config import Settings
from .models import BackendError, canonical_source, error_value
from .storage import Storage, new_id


def stop_process_tree(pid):
    """Encerra somente o job e seus descendentes, mesmo com sessões próprias."""
    descendants = {}
    try:
        root = psutil.Process(pid)
        root.suspend()
        # Suspender antes de enumerar evita que o job inicie a próxima conversão.
        while True:
            fresh = [
                child for child in root.children(recursive=True) if child.pid not in descendants
            ]
            if not fresh:
                break
            for child in fresh:
                descendants[child.pid] = child
                try:
                    child.suspend()
                except psutil.NoSuchProcess:
                    pass
        for child in reversed(list(descendants.values())):
            try:
                child.kill()
            except psutil.NoSuchProcess:
                pass
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            root.kill()
        except psutil.NoSuchProcess:
            pass
    except psutil.NoSuchProcess:
        pass
    finally:
        psutil.wait_procs(list(descendants.values()), timeout=0.2)


def _download_child(connection, settings, downloader, reference, destination):
    os.setsid()
    try:
        if downloader is None:
            from .downloader import VideoReference

            reference = VideoReference(
                reference.video_id, reference.url, reference.title, reference.unavailable
            )
        downloader = downloader if downloader is not None else make_downloader(settings)

        def progress(status, value):
            if status in {"downloading", "preparing_audio"}:
                connection.send(("progress", (status, value)))

        result = downloader.download(reference, destination, progress)
        connection.send(
            (
                "result",
                {
                    key: getattr(result, key)
                    for key in (
                        "video_id",
                        "title",
                        "artist",
                        "source_url",
                        "duration_ms",
                        "audio_path",
                        "sha256",
                        "size_bytes",
                    )
                },
            )
        )
    except Exception as exc:  # noqa: BLE001 - fronteira do downloader; nunca publica stderr.
        code = getattr(exc, "code", None)
        if isinstance(exc, OSError) and exc.errno == 28:
            code = "disk_quota"
        connection.send(
            ("error", error_value(code or "download_failed", getattr(exc, "retryable", False)))
        )
    finally:
        connection.close()


def make_downloader(settings):
    # Importação tardia permite os testes sem a implementação externa, com a mesma interface.
    from .downloader import DownloadConfig, YoutubeDownloader

    return YoutubeDownloader(
        DownloadConfig(
            command=settings.downloader_command,
            js_runtime=settings.js_runtime,
            max_duration_seconds=settings.max_duration_seconds,
            max_playlist_items=settings.max_playlist_items,
            timeout_seconds=settings.download_timeout_seconds,
        )
    )


class Worker:
    def __init__(self, settings: Settings, *, downloader=None, chart_generator=generate_chart):
        self.settings = settings
        self.storage = Storage(settings.data_dir)
        self.injected_downloader = downloader
        self.downloader = downloader if downloader is not None else make_downloader(settings)
        self.chart_generator = chart_generator
        self.stopping = False

    def _check_quota(self):
        if self.storage.cache_bytes() >= self.settings.cache_limit_bytes:
            raise BackendError("disk_quota")

    def _download(self, ref, stage, item_id):
        self._check_quota()
        # spawn evita herdar locks de bibliotecas de análise ou de threads da API/testes.
        context = multiprocessing.get_context("spawn")
        receiver, sender = context.Pipe(duplex=False)
        process = context.Process(
            target=_download_child,
            args=(sender, self.settings, self.injected_downloader, ref, stage),
        )
        process.start()
        sender.close()
        started = time.monotonic()
        result = None
        try:
            while True:
                self._check_quota()
                if (
                    self.stopping
                    or time.monotonic() - started > self.settings.download_timeout_seconds
                ):
                    raise BackendError("download_failed", retryable=True)
                if receiver.poll(0.05):
                    try:
                        kind, value = receiver.recv()
                    except EOFError:
                        break
                    if kind == "progress":
                        self.storage.update_item(item_id, value[0], value[1])
                    elif kind == "error":
                        raise BackendError(value["code"], value["retryable"])
                    elif kind == "result":
                        result = SimpleNamespace(**value)
                        break
                elif not process.is_alive():
                    break
            if result is None:
                raise BackendError("download_failed", retryable=True)
            self._check_quota()
            return result
        finally:
            process.join(0.05)
            if process.is_alive():
                stop_process_tree(process.pid)
            process.join(2)
            receiver.close()

    def _process_item(self, item):
        cached = self.storage.find_track(item["video_id"])
        if cached:
            self.storage.update_item(item["id"], "ready", 1, track_id=cached["id"])
            return
        stage = self.storage.staging / new_id("stage")
        stage.mkdir()
        published = None
        try:
            self.storage.update_item(item["id"], "downloading", 0)
            ref = SimpleNamespace(
                video_id=item["video_id"], url=item["url"], title=item["title"], unavailable=False
            )
            audio = self._download(ref, stage, item["id"])
            path = Path(audio.audio_path).resolve()
            if not path.is_relative_to(stage.resolve()) or not path.is_file():
                raise BackendError("unsupported_media")
            if (
                audio.video_id != item["video_id"]
                or audio.size_bytes <= 0
                or path.stat().st_size != audio.size_bytes
            ):
                raise BackendError("unsupported_media")
            with path.open("rb") as stream:
                sha256 = hashlib.file_digest(stream, "sha256").hexdigest()
            if sha256 != audio.sha256:
                raise BackendError("unsupported_media")
            if type(audio.duration_ms) is not int or audio.duration_ms <= 0:
                raise BackendError("unsupported_media")
            if audio.duration_ms > self.settings.max_duration_seconds * 1000:
                raise BackendError("duration_limit")
            self.storage.update_item(item["id"], "analyzing", 0.8)
            track_id = new_id("track")
            chart = self.chart_generator(path, track_id, sha256)
            validate_chart(chart, track_id, sha256, audio.duration_ms)
            prepared = stage / "published"
            prepared.mkdir()
            os.replace(path, prepared / "audio.m4a")
            (prepared / "chart.json").write_text(
                json.dumps(chart, ensure_ascii=False), encoding="utf-8"
            )
            self._check_quota()
            track = {
                "id": track_id,
                "title": audio.title,
                "artist": audio.artist,
                "durationMs": audio.duration_ms,
                "videoId": audio.video_id,
                "sourceUrl": canonical_source(audio.source_url, "video"),
                "audioUrl": f"/api/tracks/{track_id}/audio",
                "audioSha256": sha256,
                "audioBytes": audio.size_bytes,
                "chartId": chart["id"],
                "chartUrl": f"/api/charts/{chart['id']}",
                "bpm": chart["bpmEstimate"],
            }
            for artifact in prepared.iterdir():
                with artifact.open("rb") as stream:
                    os.fsync(stream.fileno())
            descriptor = os.open(prepared, os.O_DIRECTORY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            published = self.storage.media / track_id
            os.replace(prepared, published)
            descriptor = os.open(self.storage.media, os.O_DIRECTORY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            # Só anuncia ready depois que os dois arquivos estão publicados.
            self.storage.publish(item["id"], track, track_id)
            published = None
        except Exception as exc:  # noqa: BLE001 - uma falha isolada não descarta a playlist.
            if isinstance(exc, BackendError):
                error = exc.error
            elif isinstance(exc, OSError) and exc.errno == 28:
                error = error_value("disk_quota")
            else:
                error = error_value("analysis_failed")
            self.storage.update_item(item["id"], "failed", error=error)
        finally:
            shutil.rmtree(stage, ignore_errors=True)
            if published:
                shutil.rmtree(published, ignore_errors=True)

    def run_once(self):
        job = self.storage.claim_import()
        if job is None:
            return False
        try:
            if job["total_items"] is None:
                resolved = self.downloader.resolve(job["source_url"], job["kind"])
                if len(resolved.items) > self.settings.max_playlist_items:
                    raise BackendError("playlist_limit")
                self.storage.resolve_import(job["id"], resolved)
            for item in self.storage.pending_items(job["id"]):
                if self.stopping:
                    break
                self._process_item(item)
            self.storage.finish_import(job["id"])
        except Exception as exc:  # noqa: BLE001 - fronteira do job com erro público sanitizado.
            error = (
                error_value("disk_quota")
                if isinstance(exc, OSError) and exc.errno == 28
                else (
                    exc.error
                    if isinstance(exc, BackendError)
                    else error_value(
                        getattr(exc, "code", "internal_error"),
                        getattr(exc, "retryable", False),
                    )
                )
            )
            self.storage.fail_import(job["id"], error)
        return True

    def run_forever(self):
        with (self.settings.data_dir / "worker.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RuntimeError("Já existe um worker para esta biblioteca.") from None
            self.storage.recover()
            for sig in (signal.SIGTERM, signal.SIGINT):
                signal.signal(sig, lambda *_: setattr(self, "stopping", True))
            while not self.stopping:
                if not self.run_once():
                    time.sleep(0.2)
