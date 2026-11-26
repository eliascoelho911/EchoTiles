"""Catálogo SQLite; cada operação usa uma conexão e uma transação curta."""

import hashlib
import json
import shutil
import sqlite3
import uuid
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path

from .analysis import validate_chart
from .models import BackendError, error_value


def new_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex}"


class Storage:
    def __init__(self, data_dir: Path):
        self.root = Path(data_dir)
        self.root.mkdir(parents=True, exist_ok=True)
        self.media = self.root / "media"
        self.staging = self.root / "staging"
        self.media.mkdir(exist_ok=True)
        self.staging.mkdir(exist_ok=True)
        self.database = self.root / "library.sqlite3"
        with self.connect() as db:
            db.executescript("""
                PRAGMA journal_mode=WAL;
                CREATE TABLE IF NOT EXISTS imports (
                  id TEXT PRIMARY KEY, source_url TEXT NOT NULL, kind TEXT NOT NULL,
                  source_kind TEXT NOT NULL, status TEXT NOT NULL, created_at TEXT NOT NULL,
                  total_items INTEGER, error TEXT
                );
                CREATE TABLE IF NOT EXISTS items (
                  id TEXT PRIMARY KEY, import_id TEXT NOT NULL REFERENCES imports(id),
                  item_index INTEGER NOT NULL, video_id TEXT, url TEXT, title TEXT,
                  status TEXT NOT NULL, progress REAL, track_id TEXT, error TEXT,
                  UNIQUE(import_id, item_index)
                );
                CREATE TABLE IF NOT EXISTS tracks (
                  id TEXT PRIMARY KEY, video_id TEXT NOT NULL UNIQUE,
                  chart_id TEXT NOT NULL UNIQUE, payload TEXT NOT NULL, directory TEXT NOT NULL,
                  created_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS items_import ON items(import_id, item_index);
            """)

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.database, timeout=10)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        try:
            with db:
                yield db
        finally:
            db.close()

    def enqueue(self, url: str, kind: str) -> dict:
        import_id = new_id("imp")
        created = datetime.now(UTC).isoformat(timespec="microseconds").replace("+00:00", "Z")
        with self.connect() as db:
            db.execute(
                "INSERT INTO imports VALUES (?, ?, ?, ?, 'queued', ?, NULL, NULL)",
                (import_id, url, kind, kind, created),
            )
        return self.get_import(import_id)

    def get_import(self, import_id: str) -> dict | None:
        with self.connect() as db:
            db.execute("BEGIN")
            row = db.execute("SELECT * FROM imports WHERE id=?", (import_id,)).fetchone()
            if row is None:
                return None
            items = db.execute(
                "SELECT * FROM items WHERE import_id=? ORDER BY item_index", (import_id,)
            ).fetchall()
        values = [self._item_value(item) for item in items]
        return {
            "id": row["id"],
            "sourceUrl": row["source_url"],
            "sourceKind": row["source_kind"],
            "status": row["status"],
            "createdAt": row["created_at"],
            "totalItems": row["total_items"],
            "readyItems": sum(item["status"] == "ready" for item in values),
            "failedItems": sum(item["status"] == "failed" for item in values),
            "error": json.loads(row["error"]) if row["error"] else None,
            "items": values,
        }

    @staticmethod
    def _item_value(row):
        return {
            "id": row["id"],
            "index": row["item_index"],
            "videoId": row["video_id"],
            "title": row["title"],
            "status": row["status"],
            "progress": row["progress"],
            "trackId": row["track_id"],
            "error": json.loads(row["error"]) if row["error"] else None,
        }

    def list_imports(self):
        with self.connect() as db:
            ids = db.execute(
                "SELECT id FROM imports ORDER BY created_at DESC, rowid DESC"
            ).fetchall()
        return [self.get_import(row["id"]) for row in ids]

    def claim_import(self) -> dict | None:
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute(
                "SELECT * FROM imports WHERE status='queued' ORDER BY created_at, rowid LIMIT 1"
            ).fetchone()
            if row is None:
                return None
            status = "resolving" if row["total_items"] is None else "running"
            db.execute("UPDATE imports SET status=? WHERE id=?", (status, row["id"]))
            return dict(row)

    def resolve_import(self, import_id, source):
        with self.connect() as db:
            for index, ref in enumerate(source.items):
                error = json.dumps(error_value("unavailable")) if ref.unavailable else None
                db.execute(
                    "INSERT INTO items VALUES (?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?)",
                    (
                        new_id("item"),
                        import_id,
                        index,
                        ref.video_id,
                        ref.url,
                        ref.title,
                        "failed" if ref.unavailable else "queued",
                        error,
                    ),
                )
            db.execute(
                "UPDATE imports SET source_kind=?, status='running', total_items=? WHERE id=?",
                (source.source_kind, len(source.items), import_id),
            )

    def pending_items(self, import_id):
        with self.connect() as db:
            rows = db.execute(
                "SELECT * FROM items WHERE import_id=? AND status='queued' ORDER BY item_index",
                (import_id,),
            ).fetchall()
        return [dict(row) for row in rows]

    def update_item(self, item_id, status, progress=None, *, track_id=None, error=None):
        if progress is not None:
            progress = max(0.0, min(1.0, float(progress)))
        with self.connect() as db:
            db.execute(
                "UPDATE items SET status=?, progress=?, track_id=?, error=? WHERE id=?",
                (status, progress, track_id, json.dumps(error) if error else None, item_id),
            )

    def fail_import(self, import_id, error):
        with self.connect() as db:
            db.execute(
                "UPDATE imports SET status='failed', error=? WHERE id=?",
                (json.dumps(error), import_id),
            )

    def finish_import(self, import_id):
        with self.connect() as db:
            statuses = [
                row[0]
                for row in db.execute("SELECT status FROM items WHERE import_id=?", (import_id,))
            ]
            if any(status not in {"ready", "failed"} for status in statuses):
                return
            ready = statuses.count("ready")
            status = (
                "completed"
                if ready and ready == len(statuses)
                else "partial"
                if ready
                else "failed"
            )
            error = None
            if not statuses:
                error = json.dumps(error_value("unavailable"))
            db.execute(
                "UPDATE imports SET status=?, error=? WHERE id=?", (status, error, import_id)
            )

    def recover(self):
        """Chamado sob o lock exclusivo do worker, antes de consumir a fila."""
        with self.connect() as db:
            db.execute(
                "UPDATE items SET status='queued', progress=NULL WHERE status IN ('downloading', 'preparing_audio', 'analyzing')"
            )
            db.execute(
                "UPDATE imports SET status='queued' WHERE status IN ('resolving', 'running')"
            )
            directories = {row[0] for row in db.execute("SELECT directory FROM tracks")}
        for path in self.staging.iterdir():
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink()
        for path in self.media.iterdir():
            if path.name not in directories:
                if path.is_dir():
                    shutil.rmtree(path)
                else:
                    path.unlink()
        self.list_tracks()  # Também invalida mídia truncada ou ausente após reinício.

    def cache_bytes(self):
        total = 0
        for root in (self.media, self.staging):
            for path in root.rglob("*"):
                try:
                    if path.is_file():
                        total += path.stat().st_size
                except FileNotFoundError:
                    pass  # Renomeação de um .part pelo downloader entre listagem e stat.
        return total

    def publish(self, item_id, track, directory):
        with self.connect() as db:
            db.execute(
                "INSERT INTO tracks VALUES (?, ?, ?, ?, ?, ?)",
                (
                    track["id"],
                    track["videoId"],
                    track["chartId"],
                    json.dumps(track, ensure_ascii=False),
                    directory,
                    datetime.now(UTC).isoformat(),
                ),
            )
            db.execute(
                "UPDATE items SET status='ready', progress=1, track_id=?, error=NULL, title=? WHERE id=?",
                (track["id"], track["title"], item_id),
            )

    def find_track(self, video_id):
        with self.connect() as db:
            row = db.execute("SELECT id FROM tracks WHERE video_id=?", (video_id,)).fetchone()
        return self.get_track(row[0]) if row else None

    def _track_record(self, track_id):
        with self.connect() as db:
            row = db.execute("SELECT * FROM tracks WHERE id=?", (track_id,)).fetchone()
        if not row:
            return None
        track = json.loads(row["payload"])
        directory = self.media / row["directory"]
        audio, chart_path = directory / "audio.m4a", directory / "chart.json"
        try:
            if not directory.resolve().is_relative_to(self.media.resolve()):
                raise ValueError
            if audio.stat().st_size != track["audioBytes"]:
                raise ValueError
            with audio.open("rb") as stream:
                if hashlib.file_digest(stream, "sha256").hexdigest() != track["audioSha256"]:
                    raise ValueError
            chart = json.loads(chart_path.read_text())
            validate_chart(chart, track_id, track["audioSha256"], track["durationMs"])
            if chart["id"] != track["chartId"]:
                raise ValueError
        except (OSError, ValueError, BackendError, KeyError):
            with self.connect() as db:
                affected = [
                    r[0]
                    for r in db.execute(
                        "SELECT DISTINCT import_id FROM items WHERE track_id=?", (track_id,)
                    )
                ]
                db.execute(
                    "UPDATE items SET status='failed', progress=NULL, track_id=NULL, error=? WHERE track_id=?",
                    (json.dumps(error_value("unavailable")), track_id),
                )
                db.execute("DELETE FROM tracks WHERE id=?", (track_id,))
            if directory.resolve().is_relative_to(self.media.resolve()):
                shutil.rmtree(directory, ignore_errors=True)
            for import_id in affected:
                self.finish_import(import_id)
            return None
        return track, audio, chart

    def get_track(self, track_id):
        record = self._track_record(track_id)
        return record[0] if record else None

    def audio_path(self, track_id):
        record = self._track_record(track_id)
        return record[1] if record else None

    def get_chart(self, chart_id):
        with self.connect() as db:
            row = db.execute("SELECT id FROM tracks WHERE chart_id=?", (chart_id,)).fetchone()
        record = self._track_record(row[0]) if row else None
        return record[2] if record else None

    def list_tracks(self):
        with self.connect() as db:
            ids = [
                r[0]
                for r in db.execute("SELECT id FROM tracks ORDER BY created_at DESC, rowid DESC")
            ]
        return [track for track_id in ids if (track := self.get_track(track_id)) is not None]
