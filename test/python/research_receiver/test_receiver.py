from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from contextlib import closing
import csv
import io
import json
from pathlib import Path
import re
import sqlite3
import tempfile
import unittest
import uuid

from tool.research_receiver.storage import Store, Rejected
from tool.research_receiver.validation import MAX_BYTES, ValidationError, load_json, validate_payload
from tool.research_receiver.web import admin_app, upload_app

ROOT = Path(__file__).resolve().parents[3]
FIXTURE = ROOT / "test/fixtures/research_upload_v1.json"


def fixture():
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


def revision(batch, **values):
    result = deepcopy(batch)
    result["batchId"] = str(uuid.uuid4())
    result["hours"][0]["revision"] += 1
    result["hours"][0]["metrics"].update(values)
    return result


class ValidationTests(unittest.TestCase):
    def test_sender_contract(self):
        self.assertEqual(validate_payload(fixture()), fixture())

    def test_rejects_additional_text_at_every_level(self):
        for path in ((), ("consent",), ("app",), ("scope",), ("coverage",),
                     ("hours", 0), ("hours", 0, "metrics"), ("ruleSnapshot",),
                     ("ruleSnapshot", "structures", 0)):
            with self.subTest(path=path):
                batch = fixture()
                obj = batch
                for key in path:
                    obj = obj[key]
                obj["notification_body"] = "DO NOT STORE"
                with self.assertRaises(ValidationError):
                    validate_payload(batch)

    def test_bad_counters_and_bucket(self):
        for value in (-1, True, 1.2, "123", 10**13):
            batch = fixture()
            batch["hours"][0]["metrics"]["foreground_ms"] = value
            with self.assertRaises(ValidationError):
                validate_payload(batch)
        batch = fixture()
        batch["hours"][0]["bucketStart"] += 1
        with self.assertRaises(ValidationError):
            validate_payload(batch)

    def test_scope_versions_consistency_and_duplicates(self):
        batches = []
        batch = fixture(); batch["schemaVersion"] = True; batches.append(batch)
        batch = fixture(); batch["hours"][0]["metrics"]["processed"] = 1; batches.append(batch)
        batch = fixture(); batch["hours"][0]["metrics"]["cancel_success"] = 3; batches.append(batch)
        batch = fixture(); batch["hours"] *= 2; batches.append(batch)
        batch = fixture(); batch["ruleSnapshot"]["structures"] *= 2; batches.append(batch)
        batch = fixture(); batch["consent"]["ruleStructures"] = False; batches.append(batch)
        for batch in batches:
            with self.assertRaises(ValidationError):
                validate_payload(batch)

    def test_strict_json(self):
        for raw in (b'{"x":1,"x":2}', b'{"x":NaN}', b'{"x":Infinity}', b'\xff', b'[]'*2000,
                    b'{"x":'+b'1'*5000+b'}', b'['*2000+b']'*2000, b'x'*(MAX_BYTES+1)):
            with self.subTest(raw=raw[:30]):
                with self.assertRaises(ValidationError):
                    load_json(raw)


class ReceiverTests(unittest.TestCase):
    def setUp(self):
        temporary_root = ROOT / "build/receiver-verification"
        temporary_root.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=temporary_root)
        assert Path(self.temp.name).resolve().parent == temporary_root.resolve()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "receiver.sqlite3"
        self.store = Store(self.path)
        self.token_id, self.token = self.store.create_token("test device")
        self.batch = fixture()
        self.pid = self.batch["participantId"]
        self.upload = upload_app(self.store, "test-instance").test_client()
        self.admin_key = "admin-" + "a"*60
        self.admin = admin_app(self.store, {"admin_key": self.admin_key, "session_secret": "s"*64, "upload_port": 8765}).test_client()

    def post(self, batch=None, token=None, **kwargs):
        batch = self.batch if batch is None else batch
        headers = {"Authorization": "Bearer " + (self.token if token is None else token), "Idempotency-Key": batch["batchId"]}
        headers.update(kwargs.pop("headers", {}))
        return self.upload.post("/api/research/upload", json=batch, headers=headers, **kwargs)

    def report(self):
        return self.store.report(0, 4102444800000, "demo")

    def csrf(self):
        with self.admin.session_transaction() as state:
            return state["csrf"]

    def login(self):
        self.admin.get("/login")
        response = self.admin.post("/login", data={"csrf": self.csrf(), "key": self.admin_key})
        self.assertEqual(response.status_code, 302)

    def test_ack_dedup_and_restart(self):
        self.assertEqual(self.post().json, {"acceptedBatchId": self.batch["batchId"]})
        self.assertEqual(self.post(dict(reversed(list(self.batch.items())))).status_code, 200)
        self.assertEqual(Store(self.path).report(0, 4102444800000, "demo")["sums"]["processed"], 2)
        with self.store.connection() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM batches").fetchone()[0], 1)
            self.assertNotIn(self.token.encode(), self.path.read_bytes())

    def test_batch_conflict(self):
        self.post()
        batch = deepcopy(self.batch); batch["createdAt"] += 1
        self.assertEqual(self.post(batch).status_code, 409)

    def test_newer_replaces_equal_and_stale_do_not_add(self):
        self.post()
        newer = revision(self.batch, processed=5, allow=4)
        self.assertEqual(self.post(newer).status_code, 200)
        equal = deepcopy(newer); equal["batchId"] = str(uuid.uuid4())
        self.assertEqual(self.post(equal).status_code, 200)
        stale = deepcopy(self.batch); stale["batchId"] = str(uuid.uuid4())
        self.assertEqual(self.post(stale).status_code, 200)
        self.assertEqual(self.report()["sums"]["processed"], 5)

    def test_hour_conflict_rolls_back_profile_binding_and_consent(self):
        self.post()
        batch = deepcopy(self.batch)
        batch["batchId"] = str(uuid.uuid4())
        batch["consent"]["configurationRevision"] += 1
        batch["consent"]["ruleStructures"] = False
        batch["ruleSnapshot"] = None
        batch["hours"][0]["metrics"].update(processed=4, allow=3)
        self.assertEqual(self.post(batch).status_code, 409)
        self.assertTrue(self.store.participant(self.pid)["structures_enabled"])
        self.assertIsNotNone(self.store.participant(self.pid)["profile"])
        self.assertEqual(self.report()["sums"]["processed"], 2)

    def test_invalid_payload_never_binds_token(self):
        self.batch["secret"] = "private text"
        response = self.post()
        self.assertEqual(response.status_code, 422)
        self.assertNotIn(b"private text", response.data)
        self.assertIsNone(self.store.tokens()[0]["participant_id"])

    def test_concurrent_duplicate_requests(self):
        with ThreadPoolExecutor(max_workers=6) as pool:
            results = list(pool.map(lambda _: self.store.accept(self.token, self.batch), range(12)))
        self.assertEqual(len(set(results)), 1)
        self.assertEqual(self.report()["sums"]["processed"], 2)

    def test_token_binding_and_second_installation(self):
        self.post()
        second = deepcopy(self.batch); second["participantId"] = str(uuid.uuid4())
        self.assertEqual(self.post(second).status_code, 403)
        _, token = self.store.create_token("another device")
        self.assertEqual(self.post(second, token).status_code, 200)
        self.assertEqual(self.report()["installations"], 2)
        self.assertEqual(self.report()["sums"]["processed"], 4)

    def test_revocation_and_admin_key_not_upload_token(self):
        self.assertEqual(self.post(token=self.admin_key).status_code, 401)
        self.store.revoke(self.token_id)
        self.assertEqual(self.post().status_code, 403)

    def test_newer_consent_off_purges_and_delayed_true_cannot_restore(self):
        self.post()
        disabled = revision(self.batch)
        disabled["consent"].update(configurationRevision=5, ruleStructures=False)
        disabled["ruleSnapshot"] = None
        self.assertEqual(self.post(disabled).status_code, 200)
        self.assertIsNone(self.store.participant(self.pid)["profile"])
        delayed = revision(self.batch, processed=3, allow=2)
        delayed["hours"][0]["revision"] += 1
        self.assertEqual(self.post(delayed).status_code, 200)
        self.assertIsNone(self.store.participant(self.pid)["profile"])
        self.assertFalse(self.store.participant(self.pid)["structures_enabled"])

    def test_contradictory_consent_and_profile_revision(self):
        self.post()
        batch = revision(self.batch)
        batch["consent"]["ruleStructures"] = False; batch["ruleSnapshot"] = None
        self.assertEqual(self.post(batch).status_code, 409)
        batch = revision(self.batch)
        batch["ruleSnapshot"]["structures"][0]["count"] = 2
        self.assertEqual(self.post(batch).status_code, 409)
        batch["ruleSnapshot"]["revision"] += 1
        self.assertEqual(self.post(batch).status_code, 200)
        self.assertEqual(self.store.participant(self.pid)["profile"]["structures"][0]["count"], 2)

    def test_delete_cascades_and_refuses_resurrection(self):
        self.post()
        self.store.delete_participant(self.pid)
        self.assertIsNone(self.store.participant(self.pid))
        self.assertEqual(self.post().status_code, 403)
        _, new_token = self.store.create_token("replacement")
        self.assertEqual(self.post(token=new_token).status_code, 403)
        with self.store.connection() as db:
            for table in ("participants", "hours", "profiles", "batches"):
                self.assertEqual(db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0], 0)
            self.assertEqual(db.execute("SELECT COUNT(*) FROM blocked_participants").fetchone()[0], 1)

    def test_content_type_idempotency_size_and_malformed_json(self):
        self.assertEqual(self.post(headers={"Idempotency-Key": "bad"}).status_code, 400)
        headers = {"Authorization": "Bearer " + self.token}
        for content, mime, code in ((b"{}", "text/plain", 415), (b'{"a":1,"a":2}', "application/json", 400),
                                    (b"x"*(MAX_BYTES+1), "application/json", 413)):
            self.assertEqual(self.upload.post("/api/research/upload", data=content, content_type=mime, headers=headers).status_code, code)

    def test_admin_never_on_upload_listener(self):
        for path in ("/", "/login", "/tokens", "/export.csv", "/participants/"+self.pid):
            self.assertEqual(self.upload.get(path).status_code, 404)
        self.assertEqual(self.upload.get("/health").json["instanceId"], "test-instance")

    def test_admin_requires_local_host_and_login(self):
        self.assertEqual(self.admin.get("/").status_code, 302)
        self.assertEqual(self.admin.get("/login", headers={"Host": "example.com"}).status_code, 403)
        self.assertEqual(self.admin.get("/login", environ_overrides={"REMOTE_ADDR": "192.168.1.9"}).status_code, 403)
        self.assertEqual(self.admin.get("/login", headers={"X-Forwarded-For": "192.168.1.9"}).status_code, 200)
        response = self.admin.post("/login", data={"csrf": self.csrf(), "key": self.token})
        self.assertEqual(response.status_code, 401)
        self.assertEqual(self.admin.post("/login", data={"csrf": self.csrf(), "key": "错误密钥"}).status_code, 401)

    def test_csrf_and_cross_origin_for_all_mutations(self):
        self.admin.get("/login")
        self.assertEqual(self.admin.post("/login", data={"key": self.admin_key}).status_code, 403)
        self.login()
        for path in ("/tokens", "/logout", "/tokens/"+self.token_id+"/revoke", "/participants/"+self.pid+"/delete"):
            self.assertEqual(self.admin.post(path).status_code, 403)
            self.assertEqual(self.admin.post(path, data={"csrf": self.csrf()}, headers={"Origin": "https://example.com"}).status_code, 403)

    def test_dashboard_filters_csv_and_details(self):
        self.post()
        self.login()
        query = "?since=2026-11-01&until=2026-11-30&cohort=demo"
        self.assertEqual(self.admin.get("/"+query).status_code, 200)
        response = self.admin.get("/participants/"+self.pid+query)
        self.assertEqual(response.status_code, 200)
        self.assertIn(b"manual_or_legacy", response.data)
        response = self.admin.get("/export.csv"+query)
        rows = list(csv.DictReader(io.StringIO(response.data.decode("utf-8-sig"))))
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["processed"], "2")
        self.assertEqual(rows[0]["installation_id"], self.pid)
        self.assertEqual(len(list(csv.DictReader(io.StringIO(self.admin.get("/export.csv"+query.replace('demo','pilot')).data.decode("utf-8-sig"))))), 0)
        self.assertEqual(self.admin.get("/?since=oops").status_code, 400)
        self.assertEqual(self.admin.get("/?cohort=unknown").status_code, 400)

    def test_token_shown_once_escaped_label_and_revoked(self):
        self.login()
        response = self.admin.post("/tokens", data={"csrf": self.csrf(), "label": "<script>alert(1)</script>"})
        self.assertEqual(response.status_code, 200)
        raw = re.search(r'aria-label="新上传令牌">([^<]+)', response.text).group(1)
        self.assertNotIn(raw, self.admin.get("/tokens").text)
        self.assertNotIn("<script>", response.text)
        self.assertNotIn(raw, response.headers.get("Set-Cookie", ""))
        self.assertEqual(self.admin.post("/tokens/"+self.token_id+"/revoke", data={"csrf": self.csrf()}).status_code, 302)
        self.assertEqual(self.post().status_code, 403)

    def test_admin_delete_requires_confirmation(self):
        self.post(); self.login()
        path = "/participants/"+self.pid+"/delete"
        self.assertEqual(self.admin.post(path, data={"csrf": self.csrf(), "confirm": "wrong"}).status_code, 400)
        self.assertEqual(self.admin.post(path, data={"csrf": self.csrf(), "confirm": self.pid}).status_code, 302)
        self.assertIsNone(self.store.participant(self.pid))

    def test_security_headers_font_and_session(self):
        self.login()
        response = self.admin.get("/")
        self.assertEqual(response.headers["Cache-Control"], "no-store")
        self.assertIn("frame-ancestors 'none'", response.headers["Content-Security-Policy"])
        font = self.admin.get("/font.otf")
        self.assertEqual(font.status_code, 200)
        font.close()
        license_response = self.admin.get("/font-license.txt")
        self.assertEqual(license_response.status_code, 200)
        license_response.close()

    def test_refuses_unknown_database(self):
        unknown = Path(self.temp.name)/"unknown.sqlite"
        with closing(sqlite3.connect(unknown)) as db:
            db.execute("CREATE TABLE unrelated(x)")
        with self.assertRaises(RuntimeError):
            Store(unknown)


if __name__ == "__main__":
    unittest.main()
