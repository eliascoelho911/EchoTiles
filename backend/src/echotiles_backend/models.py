"""Valores e erros públicos do contrato v1."""

import re
from typing import Literal
from urllib.parse import parse_qs, urlsplit

from pydantic import BaseModel, ConfigDict

MESSAGES = {
    "invalid_url": "Informe um link válido de vídeo ou playlist do YouTube.",
    "playlist_limit": "A playlist ultrapassa o limite de faixas do servidor.",
    "duration_limit": "A faixa ultrapassa o limite de duração do servidor.",
    "unavailable": "A faixa está indisponível.",
    "access_required": "O YouTube exige acesso para esta faixa.",
    "rate_limited": "O YouTube limitou as solicitações. Tente novamente mais tarde.",
    "download_failed": "Não foi possível baixar a faixa.",
    "unsupported_media": "O áudio desta faixa não é compatível.",
    "no_playable_events": "Não foram encontrados ataques musicais para jogar.",
    "disk_quota": "O armazenamento do servidor atingiu o limite.",
    "analysis_failed": "Não foi possível analisar o ritmo desta faixa.",
    "internal_error": "Não foi possível concluir a operação.",
}


def error_value(code: str, retryable: bool = False) -> dict:
    code = code if code in MESSAGES else "internal_error"
    return {"code": code, "message": MESSAGES[code], "retryable": bool(retryable)}


class BackendError(Exception):
    def __init__(self, code: str, retryable: bool = False):
        self.error = error_value(code, retryable)
        super().__init__(self.error["message"])


class ImportRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    url: str
    kind: Literal["auto", "video", "playlist"] = "auto"


def canonical_source(url: str, kind: str) -> str:
    """Validação sem rede para enfileirar; o downloader revalida a fonte."""
    try:
        if len(url) > 2048 or any(c.isspace() for c in url):
            raise ValueError
        parsed = urlsplit(url)
        host = (parsed.hostname or "").lower()
        if (
            parsed.scheme not in {"https", "http"}
            or parsed.username
            or parsed.password
            or parsed.port not in {None, 80, 443}
            or host
            not in {
                "youtube.com",
                "www.youtube.com",
                "m.youtube.com",
                "music.youtube.com",
                "youtu.be",
                "www.youtu.be",
            }
        ):
            raise ValueError
        query = parse_qs(parsed.query)
        segments = parsed.path.strip("/").split("/")
        video = None
        if host.endswith("youtu.be") and len(segments) == 1:
            video = segments[0]
        elif parsed.path == "/watch":
            video = query.get("v", [None])[0]
        elif len(segments) == 2 and segments[0] in {"shorts", "embed", "live"}:
            video = segments[1]
        playlist = query.get("list", [None])[0]
        if video and not re.fullmatch(r"[A-Za-z0-9_-]{11}", video):
            raise ValueError
        if playlist and not re.fullmatch(r"[A-Za-z0-9_-]{10,200}", playlist):
            raise ValueError
        if kind == "playlist" or (kind == "auto" and not video):
            if not playlist:
                raise ValueError
            return f"https://www.youtube.com/playlist?list={playlist}"
        if not video:
            raise ValueError
        return f"https://www.youtube.com/watch?v={video}"
    except (TypeError, ValueError):
        raise BackendError("invalid_url") from None
