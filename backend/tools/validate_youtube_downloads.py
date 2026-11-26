#!/usr/bin/env python3
"""Downloads reais com registro persistente e sanitizado de tentativas (sem simulação).

Execute com PYTHONPATH=backend/src. Mídias e relatórios devem ficar fora do Git.
A amostra padrão é musical; a disponibilidade das fontes é verificada na execução.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import math
import re
import subprocess
import sys
import tempfile
import time
from dataclasses import asdict
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlsplit

from echotiles_backend.downloader import (
    DownloadConfig,
    DownloadError,
    YoutubeDownloader,
)

SAMPLE = [
    'https://www.youtube.com/watch?v=J---aiyznGQ',  # Keyboard Cat
    'https://www.youtube.com/watch?v=9bZkp7q19f0',  # PSY
    'https://www.youtube.com/watch?v=kJQP7kiw5Fk',  # Luis Fonsi
    'https://www.youtube.com/watch?v=fJ9rUzIMcZQ',  # Queen
    'https://www.youtube.com/watch?v=y6120QOlsfU',  # Darude
    'https://www.youtube.com/watch?v=dQw4w9WgXcQ',  # Rick Astley
    'https://www.youtube.com/watch?v=OPf0YbXqDm0',  # Mark Ronson
    'https://www.youtube.com/watch?v=RgKAFK5djSk',  # Wiz Khalifa
    'https://www.youtube.com/watch?v=7cFkae0j_Ns',  # Scott Joplin piano
    'https://www.youtube.com/watch?v=ND2rMET4MVw',  # Historical piano roll
]


def public_url(url: str) -> str:
    """Only publish the public identity, discarding tracking/auth query fields."""
    try:
        parts = urlsplit(url)
        if parts.hostname not in {'youtube.com', 'www.youtube.com', 'm.youtube.com', 'music.youtube.com', 'youtu.be', 'www.youtu.be'}:
            return '[endereço inválido]'
        query = parse_qs(parts.query)
        safe_query = {key: query[key][0] for key in ('v', 'list') if key in query and re.fullmatch(r'[A-Za-z0-9_-]{1,150}', query[key][0])}
        path = parts.path if re.fullmatch(r'/[A-Za-z0-9_/-]*', parts.path) else '/'
        return f'https://{parts.hostname}{path}' + ('?' + urlencode(safe_query) if safe_query else '')
    except (ValueError, TypeError):
        return '[endereço inválido]'


def version(command: list[str]) -> str:
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=20, check=True)
        first = result.stdout.strip().splitlines()[0]
        return first if re.fullmatch(r'[A-Za-z0-9 ._,():/-]{1,150}', first) else 'não identificada'
    except (OSError, subprocess.SubprocessError, IndexError):
        return 'não identificada'


def now() -> str:
    return datetime.now(UTC).isoformat()


def save(path: Path, ledger: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(ledger, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    temporary.chmod(0o600)
    temporary.replace(path)


def totals(attempts: list[dict]) -> dict:
    # Cache hits are useful observations, but never proof of a new transfer.
    videos: dict[str, list[dict]] = {}
    for attempt in attempts:
        if attempt.get('transfer') == 'cache':
            continue
        # Recover the ID from a public URL even when metadata failed. This
        # keeps aliases and failed first attempts in the same denominator.
        video_id = attempt.get('videoId')
        if not video_id:
            parts = urlsplit(attempt['sourceUrl'])
            video_id = parse_qs(parts.query).get('v', [None])[0]
            if not video_id and (parts.hostname in {'youtu.be', 'www.youtu.be'} or parts.path.startswith(('/shorts/', '/embed/', '/live/'))):
                video_id = parts.path.rstrip('/').rsplit('/', 1)[-1]
        key = video_id if isinstance(video_id, str) and re.fullmatch(r'[A-Za-z0-9_-]{11}', video_id) else attempt['sourceUrl']
        videos.setdefault(key, []).append(attempt)
    eligible = [rows for rows in videos.values() if rows[0].get('eligible', True)]
    return {
        'distinctCandidates': len(videos), 'eligibleVideos': len(eligible),
        'excludedVideos': len(videos) - len(eligible),
        'firstAttemptSuccesses': sum(rows[0]['success'] for rows in eligible),
        'afterRecoverySuccesses': sum(any(row['success'] for row in rows) for rows in eligible),
        'freshAttempts': sum(row.get('transfer') == 'fresh' for row in attempts),
        'cacheHits': sum(row.get('transfer') == 'cache' for row in attempts),
    }


def cached_audio(row: dict, ffprobe: str) -> dict | None:
    """A cache observation requires hash, bytes, AAC and final duration checks."""
    try:
        path = Path(row['audioPath'])
        if not path.is_file() or path.is_symlink() or path.stat().st_size != row['audioBytes']:
            return None
        with path.open('rb') as stream:
            if hashlib.file_digest(stream, 'sha256').hexdigest() != row['audioSha256']:
                return None
        result = subprocess.run([ffprobe, '-v', 'error', '-show_format', '-show_streams', '-of', 'json', str(path)],
                                capture_output=True, text=True, timeout=30, check=True)
        probe = json.loads(result.stdout)
        duration = float(probe['format']['duration'])
        if not math.isfinite(duration) or duration <= 0 or round(duration * 1000) != row['durationMs']:
            return None
        if 'mp4' not in probe['format']['format_name'] or not any(s.get('codec_type') == 'audio' and s.get('codec_name') == 'aac' for s in probe['streams']):
            return None
        return {key: row[key] for key in ('videoId', 'title', 'artist', 'audioPath', 'audioBytes', 'audioSha256', 'durationMs')}
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--urls-file', type=Path, help='Lista JSON de URLs ou uma URL pública por linha')
    parser.add_argument('--playlist', action='append', default=[])
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--report', type=Path)
    parser.add_argument('--label', default='default-clients')
    parser.add_argument('--python', default=sys.executable)
    parser.add_argument('--yt-dlp', help='Executável opcional do yt-dlp em vez de python -m yt_dlp')
    parser.add_argument('--extra-arg', action='append', default=[], help='Opção explícita do yt-dlp; os valores são omitidos no registro público')
    parser.add_argument('--js-runtime')
    parser.add_argument('--attempts', type=int, default=1)
    parser.add_argument('--gap-seconds', type=float, default=5)
    parser.add_argument('--sleep-min', type=float, default=5)
    parser.add_argument('--sleep-max', type=float, default=10)
    parser.add_argument('--timeout', type=float, default=1200)
    parser.add_argument('--reuse-cache', action='store_true')
    args = parser.parse_args()
    if args.attempts < 1 or args.attempts > 3 or args.gap_seconds < 0:
        parser.error('Use 1 a 3 tentativas e intervalo não negativo.')
    urls = SAMPLE
    if args.urls_file:
        contents = args.urls_file.read_text(encoding='utf-8')
        urls = json.loads(contents) if contents.lstrip().startswith('[') else [line.strip() for line in contents.splitlines() if line.strip() and not line.startswith('#')]
        if not isinstance(urls, list) or not all(isinstance(url, str) for url in urls):
            parser.error('A lista deve conter somente URLs.')
    args.output_dir.mkdir(parents=True, exist_ok=True)
    args.output_dir.chmod(0o700)
    report_path = args.report or args.output_dir / 'attempts.json'
    ledger = json.loads(report_path.read_text()) if report_path.exists() else {'schemaVersion': 1, 'runs': [], 'playlists': [], 'attempts': []}
    command = ([args.yt_dlp] if args.yt_dlp else [args.python, '-m', 'yt_dlp']) + args.extra_arg
    config = DownloadConfig(command=tuple(command), js_runtime=args.js_runtime, timeout_seconds=args.timeout,
                            sleep_min_seconds=args.sleep_min, sleep_max_seconds=args.sleep_max)
    downloader = YoutubeDownloader(config)
    run_id = now()
    try:
        ejs_version = importlib.metadata.version('yt-dlp-ejs') if not args.yt_dlp and args.python == sys.executable else 'verificar no ambiente do comando'
    except importlib.metadata.PackageNotFoundError:
        ejs_version = 'não instalado neste Python'
    run = {'id': run_id, 'label': args.label, 'ytDlpVersion': version(command + ['--ignore-config', '--version']),
           'ejsVersion': ejs_version, 'jsRuntime': args.js_runtime or 'default',
           'runtimeVersion': version([args.js_runtime.split(':', 1)[-1], '--version']) if args.js_runtime else 'não identificado',
           'pythonVersion': sys.version.split()[0], 'sleepMinSeconds': args.sleep_min, 'sleepMaxSeconds': args.sleep_max,
           'gapSeconds': args.gap_seconds, 'timeoutSeconds': args.timeout, 'maxDurationSeconds': config.max_duration_seconds,
           'maxPlaylistItems': config.max_playlist_items, 'concurrentFragments': 1, 'retries': 2, 'extractorRetries': 1,
           'extraArgsCount': len(args.extra_arg), 'extraArgsValues': '[omitidos; documentar somente opções públicas no relatório]',
           'freshTransfersByDefault': not args.reuse_cache}
    ledger['runs'].append(run)
    print(json.dumps({'run': run}, ensure_ascii=False), flush=True)
    save(report_path, ledger)
    work = [(url, 'video', None) for url in urls]
    for url in args.playlist:
        time.sleep(args.gap_seconds)
        try:
            source = downloader.resolve(url, 'playlist')
            playlist = {'runId': run_id, 'sourceUrl': public_url(url), 'title': source.title, 'totalItems': len(source.items),
                        'items': [asdict(item) for item in source.items], 'success': True}
            ledger['playlists'].append(playlist)
            work.extend((item.url, 'playlist_item', item) for item in source.items)
        except DownloadError as error:
            ledger['playlists'].append({'runId': run_id, 'sourceUrl': public_url(url), 'success': False,
                                        'error': {'code': error.code, 'message': error.message, 'retryable': error.retryable}})
        save(report_path, ledger)
    for index, (url, origin, reference) in enumerate(work):
        for attempt_number in range(args.attempts):
            if index or attempt_number:
                time.sleep(args.gap_seconds)
            started = time.monotonic()
            identity = public_url(url) if url else f'[item indisponível {index}]'
            row = {'runId': run_id, 'sourceUrl': identity, 'origin': origin, 'startedAt': now(),
                   'transfer': 'fresh', 'success': False, 'eligible': True}
            try:
                source = downloader.resolve(url, 'video') if reference is None else None
                item = source.items[0] if source else reference
                row['videoId'] = item.video_id
                if args.reuse_cache:
                    previous = next((cached for cached in reversed(ledger['attempts']) if cached.get('videoId') == item.video_id and cached.get('success')), None)
                    cached = cached_audio(previous, config.ffprobe_path) if previous else None
                    if cached:
                        row.update(cached, transfer='cache', success=True)
                if not row['success']:
                    staging = Path(tempfile.mkdtemp(prefix=f'item-{index:02d}-', dir=args.output_dir))
                    audio = downloader.download(item, staging)
                    row.update(videoId=audio.video_id, title=audio.title, artist=audio.artist, audioPath=str(audio.audio_path),
                               audioBytes=audio.size_bytes, audioSha256=audio.sha256, durationMs=audio.duration_ms, success=True)
            except DownloadError as error:
                row.update(error={'code': error.code, 'message': error.message, 'retryable': error.retryable})
                # Only a documented unavailable/over-duration source is excluded;
                # transient access, rate-limit and conversion failures stay in.
                if error.code in {'unavailable', 'duration_limit', 'invalid_url'}:
                    row['eligible'] = False
            row['elapsedSeconds'] = round(time.monotonic() - started, 3)
            ledger['attempts'].append(row)
            ledger['totals'] = totals(ledger['attempts'])
            save(report_path, ledger)
            print(json.dumps(row, ensure_ascii=False), flush=True)
            if row['success'] or not row.get('error', {}).get('retryable'):
                break
    ledger['finishedAt'] = now()
    ledger['totals'] = totals(ledger['attempts'])
    save(report_path, ledger)
    print(json.dumps({'totals': ledger['totals'], 'report': str(report_path)}, ensure_ascii=False), flush=True)
    current = totals([row for row in ledger['attempts'] if row['runId'] == run_id])
    return 0 if current['afterRecoverySuccesses'] == current['eligibleVideos'] and all(p['success'] for p in ledger['playlists'] if p['runId'] == run_id) else 1


if __name__ == '__main__':
    raise SystemExit(main())
