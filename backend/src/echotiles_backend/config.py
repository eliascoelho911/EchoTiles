"""Configuração local do servidor; nunca recebe comandos por HTTP."""

import os
import shlex
import sys
from dataclasses import dataclass, field
from pathlib import Path


@dataclass(frozen=True)
class Settings:
    data_dir: Path = field(default_factory=lambda: Path.home() / ".local/share/echotiles")
    max_playlist_items: int = 50
    max_duration_seconds: int = 900
    cache_limit_bytes: int = 2 * 1024**3
    downloader_command: tuple[str, ...] = (sys.executable, "-m", "yt_dlp")
    js_runtime: str | None = None
    download_timeout_seconds: float = 1200

    def __post_init__(self):
        object.__setattr__(self, "data_dir", Path(self.data_dir).expanduser().resolve())
        if min(self.max_playlist_items, self.max_duration_seconds, self.cache_limit_bytes) <= 0:
            raise ValueError("Os limites precisam ser positivos.")
        if not self.downloader_command or self.download_timeout_seconds <= 0:
            raise ValueError("Configuração de download inválida.")

    @classmethod
    def from_env(cls):
        command = os.getenv("PIANO_YT_DLP")
        return cls(
            data_dir=Path(os.getenv("PIANO_DATA_DIR", str(Path.home() / ".local/share/echotiles"))),
            max_playlist_items=int(os.getenv("PIANO_MAX_PLAYLIST_ITEMS", "50")),
            max_duration_seconds=int(os.getenv("PIANO_MAX_DURATION_SECONDS", "900")),
            cache_limit_bytes=int(os.getenv("PIANO_CACHE_LIMIT_BYTES", str(2 * 1024**3))),
            downloader_command=tuple(shlex.split(command)) if command else cls.downloader_command,
            js_runtime=os.getenv("PIANO_JS_RUNTIME") or None,
        )
