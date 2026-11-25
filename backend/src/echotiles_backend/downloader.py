"""Synchronous, bounded YouTube audio acquisition for the import worker.

The final M4A is the recording used for both analysis and playback. No signed
media URL or extractor stderr is part of this module's public result.
"""
from __future__ import annotations

import hashlib
import json
import math
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import parse_qs, urlsplit


@dataclass(frozen=True)
class DownloadConfig:
    command: tuple[str, ...] = field(default_factory=lambda: (sys.executable, "-m", "yt_dlp"))
    ffmpeg_path: str = "ffmpeg"
    ffprobe_path: str = "ffprobe"
    js_runtime: str | None = None
    timeout_seconds: float = 1200
    max_duration_seconds: int = 900
    max_playlist_items: int = 50
    sleep_min_seconds: float = 5
    sleep_max_seconds: float = 10


@dataclass(frozen=True)
class VideoReference:
    video_id: str | None
    url: str | None
    title: str | None = None
    unavailable: bool = False


@dataclass(frozen=True)
class ResolvedSource:
    source_kind: str
    title: str | None
    items: tuple[VideoReference, ...]


@dataclass(frozen=True)
class DownloadedAudio:
    video_id: str
    title: str
    artist: str
    source_url: str
    duration_ms: int
    audio_path: Path
    sha256: str
    size_bytes: int


class DownloadError(Exception):
    def __init__(self, code: str, message: str, retryable: bool):
        self.code = code
        self.message = re.sub(r"https?://\S+", "[endereço omitido]", message)
        self.message = re.sub(
            r"(?i)(token|cookie|authorization|password)\s*[=:]\s*\S+", "[segredo omitido]", self.message
        )[:500]
        self.retryable = retryable
        super().__init__(self.message)


_VIDEO_ID = re.compile(r"[A-Za-z0-9_-]{11}\Z")
_PLAYLIST_ID = re.compile(r"[A-Za-z0-9_-]{10,150}\Z")
_HOSTS = {"youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be", "www.youtu.be"}
_MAX_OUTPUT_BYTES = 8 * 1024 * 1024
_MAX_MEDIA_BYTES = 128 * 1024 * 1024
_TRANSFER_LOCK = threading.Lock()


def _process_error(stderr: str) -> DownloadError:
    text = stderr.lower()
    if "429" in text or "too many requests" in text or "rate-limit" in text:
        return DownloadError("rate_limited", "O YouTube limitou as solicitações. Tente novamente mais tarde.", True)
    if any(term in text for term in ("private video", "video unavailable", "video is unavailable", "has been removed", "not available in your country")):
        return DownloadError("unavailable", "A faixa está indisponível.", False)
    if any(term in text for term in ("sign in", "login required", "confirm your age", "403", "po token", "members-only", "drm")):
        return DownloadError("access_required", "O YouTube exige acesso ou verificação adicional para esta faixa.", False)
    if "no space left" in text or "disk quota" in text:
        return DownloadError("disk_quota", "Não há espaço disponível para preparar a faixa.", False)
    if "requested format is not available" in text or "no video formats" in text:
        return DownloadError("unsupported_media", "Não há áudio compatível disponível para esta faixa.", False)
    return DownloadError("download_failed", "Não foi possível concluir a transferência do YouTube.", True)


def _source_url(url: str, kind: str) -> tuple[str, str, str]:
    """Return kind, identifier and a canonical public YouTube URL."""
    try:
        if kind not in {"auto", "video", "playlist"} or not isinstance(url, str) or len(url) > 2048:
            raise ValueError
        if any(ord(char) < 33 for char in url) or "\\" in url:
            raise ValueError
        parsed = urlsplit(url)
        if parsed.scheme not in {"http", "https"} or parsed.hostname not in _HOSTS:
            raise ValueError
        if parsed.username is not None or parsed.password is not None or parsed.port not in {None, 80, 443}:
            raise ValueError
        query = parse_qs(parsed.query, keep_blank_values=True)
        if len(query.get("v", [])) > 1 or len(query.get("list", [])) > 1:
            raise ValueError
        path = parsed.path.rstrip("/")
        video_id = None
        if parsed.hostname in {"youtu.be", "www.youtu.be"}:
            video_id = path.removeprefix("/")
        elif path == "/watch":
            video_id = query.get("v", [None])[0]
        elif re.fullmatch(r"/(shorts|embed|live)/[^/]+", path):
            video_id = path.rsplit("/", 1)[-1]
        elif path != "/playlist":
            raise ValueError
        playlist_id = query.get("list", [None])[0]
        if video_id is not None and not _VIDEO_ID.fullmatch(video_id):
            raise ValueError
        if kind != "playlist" and video_id:
            return "video", video_id, f"https://www.youtube.com/watch?v={video_id}"
        if kind == "video" or not playlist_id or not _PLAYLIST_ID.fullmatch(playlist_id):
            raise ValueError
        return "playlist", playlist_id, f"https://www.youtube.com/playlist?list={playlist_id}"
    except (ValueError, TypeError, AttributeError):
        raise DownloadError("invalid_url", "Use um endereço válido de vídeo ou playlist do YouTube.", False) from None


class YoutubeDownloader:
    def __init__(self, config: DownloadConfig | None = None):
        self.config = config or DownloadConfig()
        if (not self.config.command or self.config.timeout_seconds <= 0 or self.config.max_duration_seconds <= 0
                or self.config.max_playlist_items <= 0 or self.config.sleep_min_seconds < 0
                or self.config.sleep_max_seconds < self.config.sleep_min_seconds):
            raise ValueError("Configuração inválida do downloader.")

    def _base(self) -> list[str]:
        args = [*self.config.command, "--ignore-config", "--no-cache-dir", "--socket-timeout", "30",
                "--retries", "2", "--fragment-retries", "2", "--extractor-retries", "1",
                "--retry-sleep", "http:exp=1:30", "--retry-sleep", "fragment:exp=1:30",
                "--sleep-requests", "0.75", "--no-warnings"]
        if self.config.js_runtime:
            args += ["--no-js-runtimes", "--js-runtimes", self.config.js_runtime]
        return args

    def _run(self, args: list[str], deadline: float) -> str:
        # Disk-backed capture avoids retaining unlimited extractor output in RAM.
        with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
            try:
                process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                                           start_new_session=True)
            except OSError:
                raise DownloadError("internal_error", "Uma ferramenta necessária não está disponível no servidor.", False) from None
            try:
                process.wait(timeout=max(0.001, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                # yt-dlp may spawn helpers; cancel the entire group on this Linux server.
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
                raise DownloadError("download_failed", "A preparação excedeu o tempo permitido. Tente novamente mais tarde.", True) from None
            if stdout.tell() > _MAX_OUTPUT_BYTES or stderr.tell() > _MAX_OUTPUT_BYTES:
                raise DownloadError("download_failed", "A resposta do serviço excedeu o limite permitido.", False)
            stderr.seek(0)
            if process.returncode:
                raise _process_error(stderr.read().decode("utf-8", errors="replace"))
            stdout.seek(0)
            return stdout.read().decode("utf-8", errors="replace")

    def _metadata(self, url: str, options: list[str], deadline: float | None = None) -> dict:
        output = self._run([*self._base(), *options, "--dump-single-json", "--skip-download", "--", url],
                           deadline if deadline is not None else time.monotonic() + self.config.timeout_seconds)
        try:
            data = json.loads(output)
            if not isinstance(data, dict):
                raise TypeError
            return data
        except (ValueError, TypeError):
            raise DownloadError("download_failed", "O YouTube retornou metadados inválidos.", True) from None

    def resolve(self, url: str, kind: str = "auto") -> ResolvedSource:
        source_kind, identifier, canonical = _source_url(url, kind)
        if source_kind == "video":
            info = self._metadata(canonical, ["--no-playlist"])
            return ResolvedSource("video", info.get("title"), (VideoReference(identifier, canonical, info.get("title")),))
        info = self._metadata(canonical, ["--yes-playlist", "--flat-playlist", "--ignore-errors",
                                          "--playlist-end", str(self.config.max_playlist_items + 1)])
        entries = info.get("entries")
        if not isinstance(entries, list):
            raise DownloadError("unavailable", "A playlist está indisponível.", False)
        if len(entries) > self.config.max_playlist_items:
            raise DownloadError("playlist_limit", "A playlist excede o limite de faixas permitido.", False)
        items = []
        for entry in entries:
            entry = entry if isinstance(entry, dict) else {}
            video_id = entry.get("id")
            if not isinstance(video_id, str) or not _VIDEO_ID.fullmatch(video_id):
                video_id = None
            title = entry.get("title")
            unavailable = (not video_id or entry.get("availability") in {"private", "premium_only", "subscriber_only", "needs_auth"}
                           or title in {"[Private video]", "[Deleted video]"})
            items.append(VideoReference(video_id, f"https://www.youtube.com/watch?v={video_id}" if video_id else None,
                                        title, unavailable))
        return ResolvedSource("playlist", info.get("title"), tuple(items))

    def _duration(self, value: object) -> float:
        try:
            duration = float(value)
            if isinstance(value, bool) or not math.isfinite(duration) or duration <= 0:
                raise ValueError
        except (TypeError, ValueError, OverflowError):
            raise DownloadError("unsupported_media", "A faixa não informa uma duração finita válida.", False) from None
        if duration > self.config.max_duration_seconds:
            raise DownloadError("duration_limit", "A faixa excede a duração máxima permitida.", False)
        return duration

    def _probe(self, path: Path, deadline: float, *, final: bool = False) -> float:
        if not path.is_file() or path.stat().st_size <= 0:
            raise DownloadError("unsupported_media", "O arquivo de áudio está vazio ou ausente.", False)
        if path.stat().st_size > _MAX_MEDIA_BYTES:
            raise DownloadError("disk_quota", "O áudio excede o tamanho máximo permitido.", False)
        output = self._run([self.config.ffprobe_path, "-v", "error", "-show_format", "-show_streams", "-of", "json", str(path)], deadline)
        try:
            probe = json.loads(output)
            streams = probe.get("streams", [])
            audio = [stream for stream in streams if stream.get("codec_type") == "audio"]
            if not audio:
                raise ValueError
            if final and (audio[0].get("codec_name") != "aac" or "mp4" not in probe["format"].get("format_name", "")):
                raise ValueError
            return self._duration(probe["format"]["duration"])
        except (KeyError, TypeError, ValueError, AttributeError):
            raise DownloadError("unsupported_media", "O arquivo não contém áudio reproduzível compatível.", False) from None

    def download(self, video: VideoReference, destination: Path,
                 progress: Callable[[str, float | None], None] | None = None) -> DownloadedAudio:
        if video.unavailable or not video.url:
            raise DownloadError("unavailable", "A faixa está indisponível.", False)
        _, identifier, canonical = _source_url(video.url, "video")
        if video.video_id != identifier:
            raise DownloadError("invalid_url", "O identificador da faixa não corresponde ao endereço.", False)
        # The worker also uses one queue. This lock prevents parallel transfers
        # when multiple downloader instances are used inside the same process.
        with _TRANSFER_LOCK:
            return self._download(video, identifier, canonical, Path(destination), progress)

    def _download(self, video: VideoReference, identifier: str, canonical: str, destination: Path,
                  progress: Callable[[str, float | None], None] | None) -> DownloadedAudio:
        deadline = time.monotonic() + self.config.timeout_seconds
        info = self._metadata(canonical, ["--no-playlist"], deadline)
        if info.get("is_live") or info.get("live_status") in {"is_live", "is_upcoming", "post_live"}:
            raise DownloadError("unsupported_media", "Aguarde o término e o processamento da transmissão ao vivo.", False)
        if info.get("availability") in {"private", "premium_only", "subscriber_only", "needs_auth"}:
            raise DownloadError("unavailable", "A faixa está indisponível.", False)
        expected_duration = self._duration(info.get("duration"))
        if info.get("id") != identifier:
            raise DownloadError("unsupported_media", "O serviço retornou uma faixa diferente da solicitada.", False)
        try:
            destination.mkdir(parents=True, exist_ok=True)
            target = destination / f"{identifier}.m4a"
            if target.exists() or target.is_symlink():
                raise DownloadError("download_failed", "O diretório de preparação já contém uma faixa concluída.", False)
            with tempfile.TemporaryDirectory(prefix=".transfer-", dir=destination) as staging:
                stage = Path(staging).resolve()
                if progress:
                    progress("downloading", None)
                output = self._run([
                    *self._base(), "--no-playlist", "--concurrent-fragments", "1", "--no-progress", "--quiet",
                    "--sleep-interval", str(self.config.sleep_min_seconds), "--max-sleep-interval", str(self.config.sleep_max_seconds),
                    "--max-filesize", str(_MAX_MEDIA_BYTES), "--match-filters", f"!is_live & duration <= {self.config.max_duration_seconds}",
                    "--format", "bestaudio/best", "--output", str(stage / "source.%(ext)s"),
                    "--no-simulate", "--print", "after_move:%(filepath)j", "--", canonical,
                ], deadline)
                try:
                    source = Path(json.loads(output.strip())).resolve()
                    if not source.is_relative_to(stage):
                        raise ValueError
                except (ValueError, TypeError):
                    raise DownloadError("unsupported_media", "A transferência não produziu um arquivo de áudio completo.", False) from None
                source_duration = self._probe(source, deadline)
                if source_duration + max(2.0, expected_duration * 0.02) < expected_duration:
                    raise DownloadError("unsupported_media", "A gravação transferida está incompleta.", False)
                if progress:
                    progress("preparing_audio", None)
                prepared = stage / "prepared.m4a"
                self._run([
                    self.config.ffmpeg_path, "-nostdin", "-hide_banner", "-loglevel", "error", "-xerror",
                    "-i", str(source), "-map", "0:a:0", "-vn", "-sn", "-dn", "-map_metadata", "-1",
                    "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", "-y", str(prepared),
                ], deadline)
                final_duration = self._probe(prepared, deadline, final=True)
                if abs(final_duration - source_duration) > max(0.25, source_duration * 0.001):
                    raise DownloadError("unsupported_media", "A conversão não preservou a gravação completa.", False)
                with prepared.open("rb") as audio_file:
                    digest = hashlib.file_digest(audio_file, "sha256").hexdigest()
                    os.fsync(audio_file.fileno())
                size = prepared.stat().st_size
                prepared.replace(target)
            return DownloadedAudio(identifier, str(info.get("title") or video.title or identifier),
                                   str(info.get("channel") or info.get("uploader") or ""), canonical,
                                   round(final_duration * 1000), target, digest, size)
        except OSError as error:
            code = "disk_quota" if error.errno in {28, 122} else "download_failed"
            raise DownloadError(code, "Não foi possível gravar o áudio no servidor.", False) from None
