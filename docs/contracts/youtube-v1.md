# Contrato entre o servidor e o APK

Versão 1, fixada antes da implementação paralela. JSON em camelCase, tempos inteiros em ms, UTF-8. A base configurada no APK é a origem do servidor; os caminhos de mídia/mapa são relativos a ela. Campos adicionais podem ser ignorados. Erros HTTP: `{"error":{"code":"invalid_url","message":"Mensagem compreensível","retryable":false}}`.

## Endpoints

- `GET /api/health` → `{"status":"ok","schemaVersion":1}`.
- `POST /api/imports`, corpo `{"url":"https://...","kind":"auto"}` → 202 com Import. `kind`: `auto`, `video`, `playlist`. Auto com URL contendo vídeo e lista trata como vídeo; a UI oferece escolha explícita.
- `GET /api/imports` → `{"imports":[Import]}`, recentes primeiro.
- `GET /api/imports/{id}` → Import; inexistente retorna 404.
- `GET /api/tracks` → `{"tracks":[Track]}`, somente prontas.
- `GET /api/tracks/{id}` → Track.
- `GET /api/tracks/{id}/audio` → áudio M4A/AAC, `Content-Type: audio/mp4`, tamanho correto e suporte a Range.
- `GET /api/charts/{id}` → Chart.

## Import

`{"id":"imp_a","sourceUrl":"https://www.youtube.com/playlist?list=...","sourceKind":"playlist","status":"running","createdAt":"2026-11-25T00:00:00Z","totalItems":2,"readyItems":1,"failedItems":0,"error":null,"items":[Item]}`.

Status de Import: `queued`, `resolving`, `running`, `completed`, `partial`, `failed`. Depois de resolver, sourceKind é `video` ou `playlist`; enquanto desconhecido pode ser `auto`. `totalItems` é null antes da resolução. `error` é null ou Error.

Item: `{"id":"item_a","index":0,"videoId":"BaW_jenozKc","title":"Faixa","status":"analyzing","progress":0.7,"trackId":null,"error":null}`. Status: `queued`, `downloading`, `preparing_audio`, `analyzing`, `ready`, `failed`. `progress` é null ou número de 0 a 1; não implica percentual exato de tempo restante. videoId e title podem ser null para entrada indisponível. Item pronto tem trackId; falho tem Error.

Error: `{"code":"unavailable","message":"A faixa está indisponível.","retryable":false}`. Códigos estáveis: `invalid_url`, `playlist_limit`, `duration_limit`, `unavailable`, `access_required`, `rate_limited`, `download_failed`, `unsupported_media`, `no_playable_events`, `disk_quota`, `analysis_failed`, `internal_error`. Não mostrar stderr cru nem URLs de CDN.

## Track

`{"id":"yt_BaW_jenozKc","title":"Faixa","artist":"Canal","durationMs":12000,"videoId":"BaW_jenozKc","sourceUrl":"https://www.youtube.com/watch?v=BaW_jenozKc","audioUrl":"/api/tracks/yt_BaW_jenozKc/audio","audioSha256":"<64 caracteres hex>","audioBytes":24000,"chartId":"chart_a","chartUrl":"/api/charts/chart_a","bpm":120.0}`.

ID é opaco para o cliente. durationMs > 0; audioBytes > 0. artist pode ser vazio e bpm pode ser null. Fonte e dados não são HTML executável.

## Chart

`{"schemaVersion":1,"id":"chart_a","trackId":"yt_BaW_jenozKc","audioSha256":"<64 caracteres hex>","generatorVersion":"rhythm-v1","lanes":4,"durationMs":12000,"bpmEstimate":120.0,"notes":[{"id":0,"timeMs":1000,"lane":1,"type":"tap"},{"id":1,"timeMs":1500,"lane":3,"type":"hold","durationMs":400}]}`.

Eventos ordenados por timeMs e id; id inteiro único; timeMs >= 0 e < durationMs; lane inteiro 0..3. Tap omite durationMs ou usa 0. Hold tem durationMs > 0 e fim <= duração. No máximo duas peças no mesmo timestamp e nenhuma sobreposição conflitante na mesma lane. O hash e duração precisam corresponder ao Track e ao arquivo reproduzido. BPM pode ser null. Não aplicar offset ao timestamp para remover introduções silenciosas.

## Interface Python do downloader

Módulo `echotiles_backend.downloader`, localizado em `backend/src/echotiles_backend/downloader.py`:

- `DownloadConfig` dataclass: `command: tuple[str, ...]` (default Python atual + `-m yt_dlp`), `ffmpeg_path: str = "ffmpeg"`, `ffprobe_path: str = "ffprobe"`, `js_runtime: str | None = None`, `timeout_seconds: float = 1200`, `max_duration_seconds: int = 900`, `max_playlist_items: int = 50`, `sleep_min_seconds: float = 5`, `sleep_max_seconds: float = 10`.
- `VideoReference` dataclass: `video_id: str | None`, `url: str | None`, `title: str | None = None`, `unavailable: bool = False`.
- `ResolvedSource` dataclass: `source_kind: str`, `title: str | None`, `items: tuple[VideoReference, ...]`.
- `DownloadedAudio` dataclass: `video_id: str`, `title: str`, `artist: str`, `source_url: str`, `duration_ms: int`, `audio_path: pathlib.Path`, `sha256: str`, `size_bytes: int`.
- `DownloadError(Exception)` expõe `code: str`, `message: str`, `retryable: bool` e aceita esses três argumentos; mensagem pública é sanitizada.
- `YoutubeDownloader(config: DownloadConfig | None = None)`.
- `YoutubeDownloader.resolve(url: str, kind: str = "auto") -> ResolvedSource` valida/canonicaliza URL e enumera playlist limitada a max+1 para detectar excesso; preserva placeholders indisponíveis na ordem.
- `YoutubeDownloader.download(video: VideoReference, destination: pathlib.Path, progress: Callable[[str, float | None], None] | None = None) -> DownloadedAudio` faz download e valida áudio final; progress usa etapas `downloading` ou `preparing_audio`.

O chamador fornece diretório de staging exclusivo. O downloader é síncrono e executado no worker; não bloqueia a API. Exige duração finita, limita tamanho/tempo e rejeita lives sem término. Configurações empíricas novas devem preservar essa interface; o relatório identifica o método e a versão realmente validados.
