"""Downloader contract tests using a controllable CLI at the process boundary."""
import json
import sys
from pathlib import Path

import pytest
from echotiles_backend.downloader import (
    DownloadConfig,
    DownloadError,
    YoutubeDownloader,
)

VIDEO_ID = 'BaW_jenozKc'
VIDEO_URL = f'https://www.youtube.com/watch?v={VIDEO_ID}'


def tool(tmp_path: Path, metadata: dict, *, body: str = '') -> tuple[str, ...]:
    script = tmp_path / 'yt_tool.py'
    script.write_text(
        'import json, sys\n'
        f'data = json.loads({json.dumps(metadata)!r})\n'
        + body
        + '\nprint(json.dumps(data))\n',
        encoding='utf-8',
    )
    return (sys.executable, str(script))


def config(command: tuple[str, ...], **kwargs) -> DownloadConfig:
    return DownloadConfig(command=command, sleep_min_seconds=0, sleep_max_seconds=0, **kwargs)


@pytest.mark.parametrize('url', [
    'file:///etc/passwd', 'https://youtube.com.evil.example/watch?v=BaW_jenozKc',
    'https://evil.youtube.example/watch?v=BaW_jenozKc', 'https://youtube.com@evil.example/watch?v=BaW_jenozKc',
    'https://www.youtube.com:444/watch?v=BaW_jenozKc', 'https://youtu.be/too-short',
    'https://www.youtube.com/watch?v=BaW_jenozKc&v=jNQXAC9IVRw',
])
def test_invalid_urls_fail_before_external_process(url, tmp_path):
    downloader = YoutubeDownloader(config(('missing-command',)))
    with pytest.raises(DownloadError) as error:
        downloader.resolve(url)
    assert error.value.code == 'invalid_url'
    assert error.value.retryable is False


@pytest.mark.parametrize('kind', ['auto', 'video'])
def test_video_with_list_remains_one_canonical_video(kind, tmp_path):
    downloader = YoutubeDownloader(config(tool(tmp_path, {'id': VIDEO_ID, 'title': 'Vídeo', 'duration': 12})))
    source = downloader.resolve(f'{VIDEO_URL}&list=PL1234567890', kind)
    assert source.source_kind == 'video'
    assert len(source.items) == 1
    assert source.items[0].url == VIDEO_URL
    assert source.items[0].video_id == VIDEO_ID


def test_explicit_playlist_keeps_private_and_deleted_positions(tmp_path):
    metadata = {'title': 'Lista', 'entries': [
        {'id': VIDEO_ID, 'url': VIDEO_URL, 'title': 'Primeira'},
        {'id': 'jNQXAC9IVRw', 'title': '[Private video]', 'availability': 'private'},
        None,
    ]}
    command = tool(tmp_path, metadata, body="assert sys.argv[sys.argv.index('--playlist-end')+1] == '51'\n")
    source = YoutubeDownloader(config(command)).resolve(f'{VIDEO_URL}&list=PL1234567890', 'playlist')
    assert source.source_kind == 'playlist'
    assert source.title == 'Lista'
    assert len(source.items) == 3
    assert source.items[0].url == VIDEO_URL
    assert source.items[1].unavailable is True
    assert source.items[1].video_id == 'jNQXAC9IVRw'
    assert source.items[2].unavailable is True
    assert source.items[2].video_id is None


def test_playlist_reads_one_extra_item_to_detect_limit(tmp_path):
    metadata = {'entries': [{'id': VIDEO_ID}] * 3}
    command = tool(tmp_path, metadata, body="assert sys.argv[sys.argv.index('--playlist-end')+1] == '3'\n")
    with pytest.raises(DownloadError) as error:
        YoutubeDownloader(config(command, max_playlist_items=2)).resolve('https://www.youtube.com/playlist?list=PL1234567890')
    assert error.value.code == 'playlist_limit'
    assert error.value.retryable is False


@pytest.mark.parametrize(('body', 'code', 'retryable'), [
    ("sys.stderr.write('HTTP Error 429: Too Many Requests'); sys.exit(1)", 'rate_limited', True),
    ("sys.stderr.write('Sign in to confirm you are not a bot https://secret.example/?token=hidden'); sys.exit(1)", 'access_required', False),
    ("sys.stderr.write('Private video'); sys.exit(1)", 'unavailable', False),
    ("sys.stderr.write('HTTP Error 503: Service Unavailable'); sys.exit(1)", 'download_failed', True),
])
def test_extractor_failures_have_structured_public_errors(tmp_path, body, code, retryable):
    with pytest.raises(DownloadError) as error:
        YoutubeDownloader(config(tool(tmp_path, {}, body=body))).resolve(VIDEO_URL)
    assert error.value.code == code
    assert error.value.retryable is retryable
    assert 'secret.example' not in error.value.message
    assert 'hidden' not in error.value.message


def test_extractor_timeout_becomes_retryable_error(tmp_path):
    command = tool(tmp_path, {}, body='import time; time.sleep(2)\n')
    with pytest.raises(DownloadError) as error:
        YoutubeDownloader(config(command, timeout_seconds=0.05)).resolve(VIDEO_URL)
    assert error.value.code == 'download_failed'
    assert error.value.retryable is True


@pytest.fixture
def audio_fixture(tmp_path):
    import subprocess
    path = tmp_path / 'tone.wav'
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=1', str(path)], check=True)
    return path


def media_tool(tmp_path, source, *, duration=1, **extra):
    metadata = {'id': VIDEO_ID, 'title': 'Faixa de teste', 'channel': 'Canal', 'duration': duration, **extra}
    body = (
        "if '--dump-single-json' not in sys.argv:\n"
        "    import shutil\n"
        "    from pathlib import Path\n"
        "    output = Path(sys.argv[sys.argv.index('--output')+1].replace('%(ext)s', 'wav'))\n"
        f"    shutil.copyfile({str(source)!r}, output)\n"
        "    print(json.dumps(str(output)))\n"
        "    sys.exit(0)\n"
    )
    return tool(tmp_path, metadata, body=body)


def test_complete_download_returns_real_aac_hash_size_and_final_duration(tmp_path, audio_fixture):
    import hashlib
    import subprocess

    from echotiles_backend.downloader import VideoReference
    stages = []
    audio = YoutubeDownloader(config(media_tool(tmp_path, audio_fixture))).download(
        VideoReference(VIDEO_ID, VIDEO_URL), tmp_path / 'staging', lambda stage, value: stages.append((stage, value)),
    )
    assert audio.video_id == VIDEO_ID
    assert audio.title == 'Faixa de teste'
    assert audio.artist == 'Canal'
    assert audio.source_url == VIDEO_URL
    assert audio.audio_path.suffix == '.m4a'
    assert audio.size_bytes == audio.audio_path.stat().st_size > 1000
    assert audio.sha256 == hashlib.sha256(audio.audio_path.read_bytes()).hexdigest()
    probe = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_format', '-show_streams', '-of', 'json', str(audio.audio_path)]))
    assert probe['streams'][0]['codec_name'] == 'aac'
    assert audio.duration_ms == 1000
    assert {'downloading', 'preparing_audio'} <= {stage for stage, _ in stages}
    assert all(stage in {'downloading', 'preparing_audio'} for stage, _ in stages)
    assert not list((tmp_path / 'staging').rglob('*.wav'))


def test_private_playlist_item_fails_without_invoking_a_process(tmp_path):
    from echotiles_backend.downloader import VideoReference
    with pytest.raises(DownloadError) as error:
        YoutubeDownloader(config(('missing-command',))).download(
            VideoReference(VIDEO_ID, None, unavailable=True), tmp_path / 'staging',
        )
    assert error.value.code == 'unavailable'


@pytest.mark.parametrize('extra', [
    {'duration': 901}, {'duration': None}, {'duration': float('inf')},
    {'is_live': True}, {'live_status': 'is_upcoming'},
])
def test_unbounded_or_excessive_recording_is_rejected(tmp_path, extra):
    from echotiles_backend.downloader import VideoReference
    metadata = {'id': VIDEO_ID, 'duration': 1, **extra}
    with pytest.raises(DownloadError) as error:
        YoutubeDownloader(config(tool(tmp_path, metadata))).download(VideoReference(VIDEO_ID, VIDEO_URL), tmp_path / 'staging')
    assert error.value.code in {'duration_limit', 'unsupported_media'}
    assert not list((tmp_path / 'staging').rglob('*.m4a'))


def test_video_without_audio_is_rejected(tmp_path):
    import subprocess

    from echotiles_backend.downloader import VideoReference
    source = tmp_path / 'silent_video.mp4'
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=black:s=16x16:d=1', '-c:v', 'mpeg4', str(source)], check=True)
    with pytest.raises(DownloadError) as error:
        YoutubeDownloader(config(media_tool(tmp_path, source))).download(VideoReference(VIDEO_ID, VIDEO_URL), tmp_path / 'staging')
    assert error.value.code == 'unsupported_media'


def test_failed_conversion_cannot_publish_success(tmp_path, audio_fixture):
    from echotiles_backend.downloader import VideoReference
    with pytest.raises(DownloadError):
        YoutubeDownloader(config(media_tool(tmp_path, audio_fixture), ffmpeg_path='/bin/false')).download(
            VideoReference(VIDEO_ID, VIDEO_URL), tmp_path / 'staging',
        )
    assert not list((tmp_path / 'staging').rglob('*.m4a'))


def test_truncated_recording_cannot_publish_success(tmp_path, audio_fixture):
    from echotiles_backend.downloader import VideoReference
    with pytest.raises(DownloadError) as error:
        YoutubeDownloader(config(media_tool(tmp_path, audio_fixture, duration=60))).download(
            VideoReference(VIDEO_ID, VIDEO_URL), tmp_path / 'staging',
        )
    assert error.value.code == 'unsupported_media'


def test_harness_keeps_failed_first_attempt_in_recovery_denominator(tmp_path, audio_fixture):
    import os
    import subprocess
    base = media_tool(tmp_path, audio_fixture)
    script = Path(base[1])
    original = script.read_text()
    counter = tmp_path / 'attempt-count'
    script.write_text(
        'from pathlib import Path\nimport sys\n'
        f'counter = Path({str(counter)!r})\n'
        "if '--dump-single-json' in sys.argv and not counter.exists():\n"
        "    counter.write_text('failed')\n"
        "    sys.stderr.write('HTTP Error 503: Service Unavailable')\n"
        "    sys.exit(1)\n" + original
    )
    wrapper = tmp_path / 'fake-yt-dlp'
    import shlex
    wrapper.write_text('#!/bin/sh\nexec ' + shlex.join(base) + ' "$@"\n')
    wrapper.chmod(0o755)
    urls = tmp_path / 'urls.json'
    urls.write_text(json.dumps([VIDEO_URL]))
    output = tmp_path / 'validation'
    harness = Path(__file__).parents[1] / 'tools' / 'validate_youtube_downloads.py'
    result = subprocess.run([sys.executable, str(harness), '--urls-file', str(urls), '--output-dir', str(output),
                             '--yt-dlp', str(wrapper), '--attempts', '2', '--gap-seconds', '0', '--sleep-min', '0', '--sleep-max', '0'],
                            env={**os.environ, 'PYTHONPATH': str(Path(__file__).parents[1] / 'src')}, capture_output=True, text=True, timeout=30, check=False)
    # --version is also executed, so do not count it as the first metadata attempt.
    assert result.returncode == 0, result.stderr
    ledger = json.loads((output / 'attempts.json').read_text())
    assert ledger['totals']['eligibleVideos'] == 1
    assert ledger['totals']['firstAttemptSuccesses'] == 0
    assert ledger['totals']['afterRecoverySuccesses'] == 1
    assert len(ledger['attempts']) == 2
