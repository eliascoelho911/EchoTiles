"""Mapa de ataques absolutos do arquivo de playback, sem remover silêncio."""

import hashlib
import json
import subprocess
from pathlib import Path

import librosa
import numpy as np

from .models import BackendError

SAMPLE_RATE = 22050
HOP_LENGTH = 256
MIN_GAP_MS = 180
GENERATOR_VERSION = "rhythm-v1"


def generate_chart(audio_path: Path, track_id: str, audio_sha256: str) -> dict:
    try:
        if audio_path.stat().st_size == 0:
            raise BackendError("no_playable_events")
        decoded = subprocess.run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-nostdin",
                "-i",
                str(audio_path),
                "-f",
                "f32le",
                "-ac",
                "1",
                "-ar",
                str(SAMPLE_RATE),
                "pipe:1",
            ],
            capture_output=True,
            check=True,
            timeout=180,
        )
        audio = np.frombuffer(decoded.stdout, dtype="<f4")
        if not audio.size or not np.isfinite(audio).all() or np.max(np.abs(audio)) < 1e-5:
            raise BackendError("no_playable_events")
        probe = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "json",
                str(audio_path),
            ],
            capture_output=True,
            check=True,
            timeout=30,
        )
        duration_ms = round(float(json.loads(probe.stdout)["format"]["duration"]) * 1000)
        if duration_ms <= 0:
            raise BackendError("no_playable_events")
        envelope = librosa.onset.onset_strength(
            y=audio,
            sr=SAMPLE_RATE,
            hop_length=HOP_LENGTH,
            n_fft=1024,
        )
        frames = librosa.onset.onset_detect(
            onset_envelope=envelope,
            sr=SAMPLE_RATE,
            hop_length=HOP_LENGTH,
            units="frames",
            backtrack=False,
        )
        candidates = []
        amplitude_gate = max(1e-5, float(np.max(np.abs(audio))) * 0.005)
        for frame in frames:
            sample = int(frame) * HOP_LENGTH
            # A evidência sonora precisa existir perto do pico espectral.
            window = audio[max(0, sample - 2 * HOP_LENGTH) : sample + HOP_LENGTH]
            if window.size and np.max(np.abs(window)) >= amplitude_gate:
                candidates.append((round(sample * 1000 / SAMPLE_RATE), float(envelope[frame])))
        if np.max(np.abs(audio[:HOP_LENGTH])) >= amplitude_gate:
            candidates.insert(0, (0, float(np.max(envelope))))
        attacks = []
        for timestamp, strength in sorted(candidates):
            if timestamp < duration_ms and (
                not attacks or timestamp - attacks[-1][0] >= MIN_GAP_MS
            ):
                attacks.append((timestamp, strength))
        if not attacks:
            raise BackendError("no_playable_events")
        seed = hashlib.sha256(f"{track_id}:{audio_sha256}".encode()).digest()
        median_strength = float(np.median([strength for _, strength in attacks]))
        notes = []
        lane = seed[0] % 4
        for index, (timestamp, strength) in enumerate(attacks):
            lane = (lane + 1 + seed[(index + 1) % len(seed)] % 3) % 4
            notes.append({"id": len(notes), "timeMs": timestamp, "lane": lane, "type": "tap"})
            if index % 8 == 7 and strength >= median_strength:
                second_lane = (lane + 2) % 4
                notes.append(
                    {"id": len(notes), "timeMs": timestamp, "lane": second_lane, "type": "tap"}
                )
        intervals = np.diff([timestamp for timestamp, _ in attacks])
        intervals = intervals[(intervals >= 250) & (intervals <= 2000)]
        bpm = round(60000 / float(np.median(intervals)), 2) if intervals.size >= 2 else None
        digest = hashlib.sha256(
            f"{GENERATOR_VERSION}:{track_id}:{audio_sha256}".encode()
        ).hexdigest()
        return {
            "schemaVersion": 1,
            "id": f"chart_{digest[:24]}",
            "trackId": track_id,
            "audioSha256": audio_sha256,
            "generatorVersion": GENERATOR_VERSION,
            "lanes": 4,
            "durationMs": duration_ms,
            "bpmEstimate": bpm,
            "notes": notes,
        }
    except BackendError:
        raise
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        raise BackendError("analysis_failed") from None


def validate_chart(chart: dict, track_id: str, sha256: str, duration_ms: int):
    """Rejeita publicação sem correspondência exata e contatos válidos."""
    try:
        if (
            chart["schemaVersion"] != 1
            or chart["lanes"] != 4
            or chart["trackId"] != track_id
            or chart["audioSha256"] != sha256
            or chart["durationMs"] != duration_ms
            or not chart["notes"]
        ):
            raise ValueError
        ids = set()
        last_order = (-1, -1)
        lane_ends = [-1] * 4
        same_time = 0
        for note in chart["notes"]:
            timestamp, note_id, lane = note["timeMs"], note["id"], note["lane"]
            if any(type(n) is not int for n in (timestamp, note_id, lane)):
                raise ValueError
            if not 0 <= timestamp < duration_ms or not 0 <= lane < 4 or note_id in ids:
                raise ValueError
            if (timestamp, note_id) <= last_order or timestamp <= lane_ends[lane]:
                raise ValueError
            same_time = same_time + 1 if timestamp == last_order[0] else 1
            if same_time > 2:
                raise ValueError
            length = note.get("durationMs", 0)
            if type(length) is not int or timestamp + length > duration_ms:
                raise ValueError
            if note["type"] == "tap" and length == 0:
                pass
            elif note["type"] != "hold" or length <= 0:
                raise ValueError
            lane_ends[lane] = timestamp + length
            ids.add(note_id)
            last_order = (timestamp, note_id)
    except (ValueError, KeyError, TypeError):
        raise BackendError("analysis_failed") from None
