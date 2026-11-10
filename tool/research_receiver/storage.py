"""Transactional, revision-aware persistence; never stores request bodies or raw tokens."""

from __future__ import annotations

from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import secrets
import re
import sqlite3
import time
import uuid

from .validation import canonical_json, digest


class Rejected(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


def now_ms():
    return int(time.time() * 1000)


def secret_hash(value: str):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


SCHEMA = """
CREATE TABLE tokens (
 id TEXT PRIMARY KEY, hash TEXT UNIQUE NOT NULL, label TEXT NOT NULL,
 created_at INTEGER NOT NULL, revoked_at INTEGER, participant_id TEXT
);
CREATE TABLE participants (
 id TEXT PRIMARY KEY, first_received INTEGER NOT NULL, last_received INTEGER NOT NULL,
 created_at INTEGER NOT NULL, version TEXT NOT NULL, android_api INTEGER NOT NULL,
 consent_at INTEGER NOT NULL, config_revision INTEGER NOT NULL, structures_enabled INTEGER NOT NULL,
 coverage TEXT NOT NULL
);
CREATE TABLE batches (
 participant_id TEXT NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
 id TEXT NOT NULL, hash TEXT NOT NULL, received_at INTEGER NOT NULL,
 PRIMARY KEY(participant_id,id)
);
CREATE TABLE hours (
 participant_id TEXT NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
 bucket INTEGER NOT NULL, offset INTEGER NOT NULL, cohort TEXT NOT NULL,
 revision INTEGER NOT NULL, hash TEXT NOT NULL, metrics TEXT NOT NULL, received_at INTEGER NOT NULL,
 PRIMARY KEY(participant_id,bucket,offset,cohort)
);
CREATE INDEX hours_filter ON hours(cohort,bucket);
CREATE TABLE profiles (
 participant_id TEXT PRIMARY KEY REFERENCES participants(id) ON DELETE CASCADE,
 revision INTEGER NOT NULL, hash TEXT NOT NULL, captured_at INTEGER NOT NULL, structures TEXT NOT NULL
);
CREATE TABLE blocked_participants (hash TEXT PRIMARY KEY, deleted_at INTEGER NOT NULL);
PRAGMA user_version=1;
"""


class Store:
    def __init__(self, path: Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.connection() as db:
            db.execute("PRAGMA journal_mode=WAL")
            version = db.execute("PRAGMA user_version").fetchone()[0]
            if version == 0:
                if db.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchone():
                    raise RuntimeError("拒绝覆盖未知 SQLite 数据库")
                db.executescript(SCHEMA)
            elif version not in (1, 2, 3):
                raise RuntimeError("不支持的接收端数据库版本")
            db.execute("BEGIN IMMEDIATE")
            if db.execute("PRAGMA user_version").fetchone()[0] == 1:
                db.execute("CREATE TABLE enrollment_settings (id INTEGER PRIMARY KEY CHECK(id=1), opened INTEGER NOT NULL)")
                db.execute("INSERT INTO enrollment_settings VALUES (1,0)")
                db.execute("CREATE TABLE enrollments (participant_id TEXT PRIMARY KEY, token_id TEXT UNIQUE NOT NULL REFERENCES tokens(id), registered_at INTEGER NOT NULL)")
                db.execute("PRAGMA user_version=2")
            if db.execute("PRAGMA user_version").fetchone()[0] == 2:
                db.execute("CREATE TABLE offline_installations (participant_id TEXT PRIMARY KEY REFERENCES participants(id) ON DELETE CASCADE, label TEXT NOT NULL, first_import INTEGER NOT NULL, last_import INTEGER NOT NULL)")
                db.execute("CREATE TABLE imports (id TEXT PRIMARY KEY, participant_id TEXT NOT NULL REFERENCES participants(id) ON DELETE CASCADE, hash TEXT NOT NULL, received_at INTEGER NOT NULL, metadata TEXT NOT NULL)")
                db.execute("CREATE TABLE offline_events (participant_id TEXT NOT NULL REFERENCES participants(id) ON DELETE CASCADE, id TEXT NOT NULL, at_ms INTEGER NOT NULL, bucket INTEGER NOT NULL, offset INTEGER NOT NULL, cohort TEXT NOT NULL, hash TEXT NOT NULL, metrics TEXT NOT NULL, PRIMARY KEY(participant_id,id))")
                db.execute("CREATE INDEX offline_events_at ON offline_events(participant_id,at_ms)")
                db.execute("PRAGMA user_version=3")

    @contextmanager
    def connection(self):
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys=ON")
        db.execute("PRAGMA synchronous=FULL")
        db.execute("PRAGMA secure_delete=ON")
        try:
            with db:
                yield db
        finally:
            db.close()

    def create_token(self, label: str):
        label = label.strip()
        if not 1 <= len(label) <= 80 or any(ord(c) < 32 for c in label):
            raise ValueError("备注请使用 1–80 个可见字符")
        raw = secrets.token_urlsafe(32)
        token_id = str(uuid.uuid4())
        with self.connection() as db:
            db.execute("INSERT INTO tokens VALUES (?,?,?,?,NULL,NULL)",
                       (token_id, secret_hash(raw), label, now_ms()))
        return token_id, raw

    def tokens(self):
        with self.connection() as db:
            return [dict(r) for r in db.execute(
                "SELECT id,label,created_at,revoked_at,participant_id FROM tokens ORDER BY created_at DESC")]

    def revoke(self, token_id):
        with self.connection() as db:
            db.execute("UPDATE tokens SET revoked_at=? WHERE id=?", (now_ms(), token_id))

    def rename_token(self, token_id, label):
        label = label.strip()
        if not 1 <= len(label) <= 80 or any(ord(c) < 32 for c in label):
            raise ValueError("备注请使用 1–80 个可见字符")
        with self.connection() as db:
            db.execute("UPDATE tokens SET label=? WHERE id=?", (label, token_id))

    def enrollment_status(self):
        with self.connection() as db:
            rows = [dict(r) for r in db.execute("""SELECT e.*, t.label,t.revoked_at,
                EXISTS(SELECT 1 FROM participants p WHERE p.id=e.participant_id) AS has_data
                FROM enrollments e JOIN tokens t ON t.id=e.token_id ORDER BY e.registered_at""")]
            return {"opened": bool(db.execute("SELECT opened FROM enrollment_settings WHERE id=1").fetchone()[0]),
                    "limit": 10, "used": len(rows), "devices": rows}

    def set_enrollment_open(self, opened):
        with self.connection() as db:
            db.execute("UPDATE enrollment_settings SET opened=? WHERE id=1", (int(opened),))

    def enroll(self, participant, raw):
        # Client persists this random credential before the request, so lost replies
        # never require the server to retain/recover a plaintext upload credential.
        if not isinstance(raw, str) or not re.fullmatch(r"[A-Za-z0-9_-]{43}", raw):
            raise Rejected(422, "登记需要独立随机上传凭证")
        hashed = secret_hash(raw)
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            if db.execute("SELECT 1 FROM blocked_participants WHERE hash=?", (secret_hash(participant),)).fetchone():
                raise Rejected(403, "该研究编号已删除")
            old = db.execute("SELECT t.* FROM enrollments e JOIN tokens t ON e.token_id=t.id WHERE e.participant_id=?", (participant,)).fetchone()
            if old:
                if old["hash"] != hashed:
                    raise Rejected(409, "该研究编号已绑定其他凭证")
                if old["revoked_at"] is not None:
                    raise Rejected(403, "该安装的上传权限已撤销")
                return participant
            if not db.execute("SELECT opened FROM enrollment_settings WHERE id=1").fetchone()[0]:
                raise Rejected(403, "新设备登记已关闭")
            if db.execute("SELECT COUNT(*) FROM enrollments").fetchone()[0] >= 10:
                raise Rejected(409, "10 个安装名额已满")
            if (db.execute("SELECT 1 FROM participants WHERE id=?", (participant,)).fetchone()
                    or db.execute("SELECT 1 FROM tokens WHERE hash=? OR participant_id=?", (hashed, participant)).fetchone()):
                raise Rejected(409, "研究编号或上传凭证已被使用")
            token_id = str(uuid.uuid4())
            db.execute("INSERT INTO tokens VALUES (?,?,?,?,NULL,?)", (token_id, hashed, "内测设备 · " + participant[:8], now_ms(), participant))
            db.execute("INSERT INTO enrollments VALUES (?,?,?)", (participant, token_id, now_ms()))
        return participant

    def known_participant(self, participant):
        with self.connection() as db:
            return bool(db.execute("SELECT 1 FROM participants WHERE id=? UNION ALL SELECT 1 FROM enrollments WHERE participant_id=?", (participant, participant)).fetchone())

    def authenticate(self, raw):
        with self.connection() as db:
            self._token(db, raw)

    @staticmethod
    def _token(db, raw):
        if not isinstance(raw, str) or not 30 <= len(raw) <= 200:
            raise Rejected(401, "上传令牌无效")
        token = db.execute("SELECT * FROM tokens WHERE hash=?", (secret_hash(raw),)).fetchone()
        if token is None:
            raise Rejected(401, "上传令牌无效")
        if token["revoked_at"] is not None:
            raise Rejected(403, "上传令牌已撤销")
        return token

    def accept(self, raw: str, batch: dict, *, offline=None):
        """Caller validates the entire wire object before invoking this method."""
        participant, batch_id = batch["participantId"], batch["batchId"]
        batch_hash = digest(batch)
        received = now_ms()
        consent = batch["consent"]
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            token = self._token(db, raw) if offline is None else None
            if db.execute("SELECT 1 FROM blocked_participants WHERE hash=?", (secret_hash(participant),)).fetchone():
                raise Rejected(403, "该研究编号已删除；拒绝恢复旧数据")
            if token is not None and token["participant_id"] not in (None, participant):
                raise Rejected(403, "上传令牌已绑定另一安装实例")
            if offline is not None:
                full_hash = digest(offline)
                previous = db.execute("SELECT hash FROM imports WHERE id=?", (batch_id,)).fetchone()
                if previous:
                    if previous[0] != full_hash:
                        raise Rejected(409, "相同导出编号的文件内容发生变化")
                    return batch_id
                exists = db.execute("SELECT 1 FROM offline_installations WHERE participant_id=?", (participant,)).fetchone()
                if not exists and db.execute("SELECT COUNT(*) FROM offline_installations").fetchone()[0] >= 10:
                    raise Rejected(409, "已接纳 10 个离线内测编号，请先管理旧编号")
            previous = None if offline is not None else db.execute("SELECT hash FROM batches WHERE participant_id=? AND id=?",
                                                                 (participant, batch_id)).fetchone()
            if previous:
                if previous[0] != batch_hash:
                    raise Rejected(409, "相同批次编号的内容发生变化")
                return batch_id
            current = db.execute("SELECT * FROM participants WHERE id=?", (participant,)).fetchone()
            if current is None:
                db.execute("INSERT INTO participants VALUES (?,?,?,?,?,?,?,?,?,?)", (
                    participant, received, received, batch["createdAt"], batch["app"]["version"],
                    batch["app"]["androidApi"], consent["acceptedAt"], consent["configurationRevision"],
                    int(consent["ruleStructures"]), canonical_json(batch["coverage"])))
            else:
                if (consent["configurationRevision"] == current["config_revision"]
                        and consent["ruleStructures"] != bool(current["structures_enabled"])):
                    raise Rejected(409, "相同配置修订的同意范围冲突")
                db.execute("UPDATE participants SET last_received=? WHERE id=?", (received, participant))
                if batch["createdAt"] >= current["created_at"]:
                    db.execute("UPDATE participants SET created_at=?,version=?,android_api=?,coverage=? WHERE id=?", (
                        batch["createdAt"], batch["app"]["version"], batch["app"]["androidApi"],
                        canonical_json(batch["coverage"]), participant))
                if consent["configurationRevision"] > current["config_revision"]:
                    db.execute("UPDATE participants SET config_revision=?,structures_enabled=?,consent_at=? WHERE id=?", (
                        consent["configurationRevision"], int(consent["ruleStructures"]), consent["acceptedAt"], participant))
            # Only the highest consent configuration can enable or remove a profile.
            current = db.execute("SELECT * FROM participants WHERE id=?", (participant,)).fetchone()
            if not current["structures_enabled"]:
                db.execute("DELETE FROM profiles WHERE participant_id=?", (participant,))
            profile = batch["ruleSnapshot"]
            if (profile is not None and current["structures_enabled"]
                    and consent["configurationRevision"] == current["config_revision"]):
                old = db.execute("SELECT revision,hash FROM profiles WHERE participant_id=?", (participant,)).fetchone()
                profile_hash = digest(profile)
                if old and old["revision"] == profile["revision"] and old["hash"] != profile_hash:
                    raise Rejected(409, "相同规则结构修订的内容冲突")
                if old is None or profile["revision"] > old["revision"]:
                    db.execute("INSERT OR REPLACE INTO profiles VALUES (?,?,?,?,?)", (
                        participant, profile["revision"], profile_hash, profile["capturedAtBucket"],
                        canonical_json(profile["structures"])))
            for hour in batch["hours"]:
                key = (participant, hour["bucketStart"], hour["utcOffsetMinutes"], hour["cohort"])
                old = db.execute("SELECT revision,hash FROM hours WHERE participant_id=? AND bucket=? AND offset=? AND cohort=?", key).fetchone()
                hour_hash = digest(hour["metrics"])
                if old and old["revision"] == hour["revision"] and old["hash"] != hour_hash:
                    raise Rejected(409, "相同小时修订的累计指标冲突")
                if old is None or hour["revision"] > old["revision"]:
                    db.execute("INSERT OR REPLACE INTO hours VALUES (?,?,?,?,?,?,?,?)", (
                        *key, hour["revision"], hour_hash, canonical_json(hour["metrics"]), received))
            if offline is None:
                db.execute("UPDATE tokens SET participant_id=? WHERE id=?", (participant, token["id"]))
                db.execute("INSERT INTO batches VALUES (?,?,?,?)", (participant, batch_id, batch_hash, received))
            else:
                for event in offline["events"]:
                    event_hash = digest(event)
                    previous_event = db.execute("SELECT hash FROM offline_events WHERE participant_id=? AND id=?", (participant,event["eventId"])).fetchone()
                    if previous_event and previous_event[0] != event_hash:
                        raise Rejected(409, "相同事件明细编号的内容冲突，整份文件未导入")
                    db.execute("INSERT OR IGNORE INTO offline_events VALUES (?,?,?,?,?,?,?,?)", (
                        participant,event["eventId"],event["at"],event["bucketStart"],event["utcOffsetMinutes"],
                        event["cohort"],event_hash,canonical_json(event["metrics"])))
                metadata = {key: offline[key] for key in ("period","retention","coverage","captureFailuresSinceProcessStart")}
                metadata.update(createdAt=offline["createdAt"],hourCount=len(offline["hours"]),eventCount=len(offline["events"]))
                db.execute("INSERT OR IGNORE INTO offline_installations VALUES (?,?,?,?)", (participant,"内测设备 · "+participant[:8],received,received))
                db.execute("UPDATE offline_installations SET last_import=? WHERE participant_id=?", (received,participant))
                db.execute("INSERT INTO imports VALUES (?,?,?,?,?)", (batch_id,participant,full_hash,received,canonical_json(metadata)))
        return batch_id

    def import_archive(self, archive):
        from .archive import as_batch
        return self.accept("", as_batch(archive), offline=archive)

    def offline_status(self):
        with self.connection() as db:
            devices = [dict(r) for r in db.execute("SELECT i.*,(SELECT COUNT(*) FROM offline_events e WHERE e.participant_id=i.participant_id) AS event_count FROM offline_installations i ORDER BY last_import DESC")]
            for device in devices:
                latest = db.execute("SELECT metadata FROM imports WHERE participant_id=? ORDER BY json_extract(metadata,'$.createdAt') DESC,rowid DESC LIMIT 1", (device["participant_id"],)).fetchone()
                device["latest"] = json.loads(latest[0])
            return {"devices":devices,"used":len(devices),"limit":10}

    def rename_offline(self, participant, label):
        label = label.strip()
        if not 1 <= len(label) <= 80 or any(ord(c)<32 for c in label):
            raise ValueError("备注请使用 1–80 个可见字符")
        with self.connection() as db:
            db.execute("UPDATE offline_installations SET label=? WHERE participant_id=?", (label,participant))

    def event_rows(self, participant):
        with self.connection() as db:
            for row in db.execute("SELECT id,at_ms,bucket,offset,cohort,metrics FROM offline_events WHERE participant_id=? ORDER BY at_ms,id", (participant,)):
                yield dict(row)

    def delete_participant(self, participant):
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            db.execute("INSERT OR IGNORE INTO blocked_participants VALUES (?,?)", (secret_hash(participant), now_ms()))
            db.execute("UPDATE tokens SET revoked_at=?,participant_id=NULL WHERE participant_id=?", (now_ms(), participant))
            db.execute("DELETE FROM enrollments WHERE participant_id=?", (participant,))
            db.execute("DELETE FROM participants WHERE id=?", (participant,))
        # Checkpoint removes ordinary WAL remnants; backups need separate deletion.
        with self.connection() as db:
            db.execute("PRAGMA wal_checkpoint(TRUNCATE)")

    def participant(self, participant):
        with self.connection() as db:
            row = db.execute("SELECT * FROM participants WHERE id=?", (participant,)).fetchone()
            if row is None:
                return None
            result = dict(row)
            profile = db.execute("SELECT * FROM profiles WHERE participant_id=?", (participant,)).fetchone()
            result["profile"] = None if profile is None else dict(profile)
            if result["profile"]:
                result["profile"]["structures"] = json.loads(result["profile"]["structures"])
            result["coverage"] = json.loads(result["coverage"])
            return result

    @staticmethod
    def _where(start, end, cohort, participant=None):
        sql, args = "bucket>=? AND bucket<? AND cohort=?", [start, end, cohort]
        if participant:
            sql += " AND participant_id=?"
            args.append(participant)
        return sql, args

    def report(self, start, end, cohort, participant=None, page=1):
        where, args = self._where(start, end, cohort, participant)
        with self.connection() as db:
            counts = db.execute(f"SELECT COUNT(*), COUNT(DISTINCT participant_id) FROM hours WHERE {where}", args).fetchone()
            sums = {}
            # JSON1 is bundled with supported Python SQLite; no user SQL fragments.
            names = ("processed", "allow", "log_only", "intercept_matched", "cancel_success", "cancel_failed",
                     "cancel_rejected", "cancel_unconfirmed", "foreground_ms", "engine_enabled_observed_ms",
                     "listener_connected_observed_ms", "observation_gap_ms", "existing_processed", "existing_cancel_success")
            expressions = ",".join(f"COALESCE(SUM(json_extract(metrics,'$.{name}')),0)" for name in names)
            sums.update(zip(names, db.execute(f"SELECT {expressions} FROM hours WHERE {where}", args).fetchone()))
            sums["actions"] = db.execute(f"SELECT COALESCE(SUM(j.value),0) FROM hours, json_each(hours.metrics) j WHERE {where} AND substr(j.key,1,7)='action_'", args).fetchone()[0]
            rows = [dict(r) for r in db.execute(f"SELECT * FROM hours WHERE {where} ORDER BY bucket DESC,participant_id,offset LIMIT 50 OFFSET ?", [*args, (page-1)*50])]
            for row in rows:
                row["metrics"] = json.loads(row["metrics"])
            return {"rows": rows, "total": counts[0], "installations": counts[1], "sums": sums, "page": page}

    def export_rows(self, start, end, cohort, participant=None):
        where, args = self._where(start, end, cohort, participant)
        with self.connection() as db:
            for row in db.execute(f"SELECT * FROM hours WHERE {where} ORDER BY bucket,participant_id,offset", args):
                yield dict(row)
