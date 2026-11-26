import sys

import pytest

from echotiles_backend.config import Settings


def test_environment_configures_limits_and_command_without_shell(monkeypatch, tmp_path):
    monkeypatch.setenv("PIANO_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("PIANO_MAX_PLAYLIST_ITEMS", "12")
    monkeypatch.setenv("PIANO_MAX_DURATION_SECONDS", "120")
    monkeypatch.setenv("PIANO_CACHE_LIMIT_BYTES", "4000000")
    monkeypatch.setenv(
        "PIANO_YT_DLP", '/opt/tools/python -m yt_dlp --config-location "/opt/a b/config"'
    )
    monkeypatch.setenv("PIANO_JS_RUNTIME", "deno:/opt/tools/deno")
    settings = Settings.from_env()
    assert settings.data_dir == tmp_path
    assert settings.max_playlist_items == 12
    assert settings.max_duration_seconds == 120
    assert settings.cache_limit_bytes == 4_000_000
    assert settings.downloader_command == (
        "/opt/tools/python",
        "-m",
        "yt_dlp",
        "--config-location",
        "/opt/a b/config",
    )
    assert settings.js_runtime == "deno:/opt/tools/deno"


def test_default_limits_and_command_match_contract(monkeypatch, tmp_path):
    for key in [
        "PIANO_DATA_DIR",
        "PIANO_MAX_PLAYLIST_ITEMS",
        "PIANO_MAX_DURATION_SECONDS",
        "PIANO_CACHE_LIMIT_BYTES",
        "PIANO_YT_DLP",
        "PIANO_JS_RUNTIME",
    ]:
        monkeypatch.delenv(key, raising=False)
    settings = Settings.from_env()
    assert settings.max_playlist_items == 50
    assert settings.max_duration_seconds == 900
    assert settings.cache_limit_bytes == 2 * 1024**3
    assert settings.downloader_command == (sys.executable, "-m", "yt_dlp")


@pytest.mark.parametrize(
    "options",
    [
        {"max_playlist_items": 0},
        {"max_duration_seconds": -1},
        {"cache_limit_bytes": 0},
        {"downloader_command": ()},
        {"download_timeout_seconds": 0},
    ],
)
def test_invalid_operational_limits_fail_early(options):
    with pytest.raises(ValueError):
        Settings(**options)
