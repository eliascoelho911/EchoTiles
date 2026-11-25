import hashlib
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pytest
import soundfile as sf


@dataclass
class VideoReference:
    video_id: str | None
    url: str | None
    title: str | None = None
    unavailable: bool = False


@dataclass
class ResolvedSource:
    source_kind: str
    title: str | None
    items: tuple[VideoReference, ...]


@dataclass
class DownloadedAudio:
    video_id: str
    title: str
    artist: str
    source_url: str
    duration_ms: int
    audio_path: Path
    sha256: str
    size_bytes: int


class DownloadFailure(Exception):
    def __init__(self, code="download_failed"):
        self.code = code
        self.message = "secret https://cdn.invalid/token?private=cookie"
        self.retryable = True


def write_click_audio(path, times=(1, 1.5, 2, 2.5), duration=4, m4a=False):
    sr = 22050
    data = np.zeros(int(sr * duration), dtype=np.float32)
    # Ataques sintéticos conhecidos, sem downloads e com um início silencioso.
    rng = np.random.default_rng(23)
    for timestamp in times:
        start = int(timestamp * sr)
        count = min(int(0.035 * sr), len(data) - start)
        if count > 0:
            pulse = rng.uniform(-1, 1, count) * np.exp(-np.arange(count) / (sr * 0.008))
            data[start : start + count] += pulse
    wav = path.with_suffix(".wav") if m4a else path
    sf.write(wav, data, sr)
    if m4a:
        subprocess.run(
            ["ffmpeg", "-v", "error", "-nostdin", "-i", str(wav), "-c:a", "aac", "-y", str(path)],
            check=True,
        )
    return path


@pytest.fixture
def playback(tmp_path):
    return write_click_audio(tmp_path / "fixture.m4a", m4a=True)


class FakeDownloader:
    def __init__(
        self, audio, refs=None, *, delay=0, fail=False, grow_bytes=0, detached_pid_file=None
    ):
        self.audio = audio
        self.refs = refs or (
            VideoReference("BaW_jenozKc", "https://www.youtube.com/watch?v=BaW_jenozKc", "Faixa"),
        )
        self.delay = delay
        self.fail = fail
        self.grow_bytes = grow_bytes
        self.detached_pid_file = detached_pid_file

    def resolve(self, url, kind="auto"):
        return ResolvedSource("playlist" if "list=" in url else "video", "Fonte", tuple(self.refs))

    def download(self, video, destination, progress=None):
        if self.detached_pid_file:
            child = subprocess.Popen(
                [sys.executable, "-c", "import time; time.sleep(60)"],
                start_new_session=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            self.detached_pid_file.write_text(str(child.pid))
        if progress:
            progress("downloading", 0.2)
        if self.grow_bytes:
            with (destination / "transfer.part").open("wb") as stream:
                stream.write(b"q" * self.grow_bytes)
            time.sleep(0.4)
        time.sleep(self.delay)
        if self.fail:
            raise DownloadFailure()
        if progress:
            progress("preparing_audio", 0.7)
        target = destination / "playback.m4a"
        shutil.copyfile(self.audio, target)
        return DownloadedAudio(
            video.video_id,
            video.title or "Faixa",
            "Artista",
            video.url,
            4000,
            target,
            hashlib.sha256(target.read_bytes()).hexdigest(),
            target.stat().st_size,
        )
