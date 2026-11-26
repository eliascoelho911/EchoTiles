import hashlib
from itertools import pairwise

import pytest
from conftest import write_click_audio

from echotiles_backend.analysis import generate_chart, validate_chart
from echotiles_backend.models import BackendError


@pytest.mark.parametrize("m4a", [False, True])
def test_clicks_keep_absolute_times_and_pauses(tmp_path, m4a):
    path = write_click_audio(
        tmp_path / ("clicks.m4a" if m4a else "clicks.wav"),
        times=(1, 1.5, 2, 4, 4.5),
        duration=6,
        m4a=m4a,
    )
    chart = generate_chart(path, "track_test", hashlib.sha256(path.read_bytes()).hexdigest())
    times = sorted({note["timeMs"] for note in chart["notes"]})
    assert len(times) == 5
    assert all(
        abs(actual - expected) <= 65
        for actual, expected in zip(times, [1000, 1500, 2000, 4000, 4500])
    )
    assert chart["lanes"] == 4
    assert chart["durationMs"] == 6000
    assert chart["generatorVersion"] == "rhythm-v1"
    assert not any(2100 < t < 3900 for t in times)


@pytest.mark.parametrize("duration", [0, 3])
def test_empty_or_silent_audio_has_no_playable_events(tmp_path, duration):
    path = write_click_audio(tmp_path / "silence.wav", times=(), duration=duration)
    with pytest.raises(BackendError) as error:
        generate_chart(path, "track_test", "f" * 64)
    assert error.value.error["code"] == "no_playable_events"


def test_close_attacks_are_filtered_and_lanes_are_deterministic(tmp_path):
    path = write_click_audio(
        tmp_path / "dense.wav", times=(0.5, 0.53, 0.57, 1, 1.04, 1.5, 2, 2.5, 3), duration=4
    )
    first = generate_chart(path, "track_test", "f" * 64)
    second = generate_chart(path, "track_test", "f" * 64)
    assert first == second
    notes = first["notes"]
    assert notes == sorted(notes, key=lambda n: (n["timeMs"], n["id"]))
    assert len({note["id"] for note in notes}) == len(notes)
    assert {note["lane"] for note in notes} <= {0, 1, 2, 3}
    times = sorted({note["timeMs"] for note in notes})
    assert all(b - a >= 180 for a, b in pairwise(times))
    for timestamp in times:
        group = [n for n in notes if n["timeMs"] == timestamp]
        assert 1 <= len(group) <= 2
        assert len({note["lane"] for note in group}) == len(group)
    assert all(0 <= note["timeMs"] < first["durationMs"] for note in notes)


def test_zero_byte_audio_has_no_playable_events(tmp_path):
    path = tmp_path / "empty.wav"
    path.touch()
    with pytest.raises(BackendError) as error:
        generate_chart(path, "track_test", "f" * 64)
    assert error.value.error["code"] == "no_playable_events"


def test_schema_accepts_valid_holds_and_rejects_lane_conflicts():
    chart = {
        "schemaVersion": 1,
        "lanes": 4,
        "trackId": "test",
        "audioSha256": "a" * 64,
        "durationMs": 4000,
        "notes": [
            {"id": 0, "timeMs": 1000, "lane": 0, "type": "hold", "durationMs": 500},
            {"id": 1, "timeMs": 1000, "lane": 2, "type": "tap"},
            {"id": 2, "timeMs": 2000, "lane": 1, "type": "tap"},
        ],
    }
    validate_chart(chart, "test", "a" * 64, 4000)
    chart["notes"][1]["lane"] = 0
    with pytest.raises(BackendError):
        validate_chart(chart, "test", "a" * 64, 4000)


def test_long_click_fixture_uses_all_lanes_and_selective_doubles(tmp_path):
    path = write_click_audio(
        tmp_path / "long.wav", times=tuple(0.5 + index * 0.5 for index in range(16)), duration=9
    )
    chart = generate_chart(path, "test", "f" * 64)
    assert {note["lane"] for note in chart["notes"]} == {0, 1, 2, 3}
    assert 16 < len(chart["notes"]) <= 18
    validate_chart(chart, "test", "f" * 64, 9000)
