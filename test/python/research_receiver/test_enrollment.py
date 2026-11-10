from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
import json
from pathlib import Path
import secrets
import sqlite3
import tempfile
import unittest
import uuid

from tool.research_receiver.storage import SCHEMA, Store, Rejected
from tool.research_receiver.web import upload_app, admin_app

ROOT = Path(__file__).resolve().parents[3]


class EnrollmentTests(unittest.TestCase):
    def setUp(self):
        root = ROOT/"build/receiver-verification"
        root.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=root)
        assert Path(self.temp.name).resolve().parent == root.resolve()
        self.addCleanup(self.temp.cleanup)
        self.store = Store(Path(self.temp.name)/"receiver.sqlite3")
        self.key = secrets.token_urlsafe(32)
        self.client = upload_app(self.store,"test",self.key).test_client()
        self.pid = str(uuid.uuid4())
        self.token = secrets.token_urlsafe(32)

    def register(self, pid=None, token=None, **kwargs):
        headers={"Authorization":"Bearer "+(token or self.token),"X-Research-Enrollment-Key":self.key}
        headers.update(kwargs.pop("headers",{}))
        return self.client.post("/api/research/enroll",json={"schemaVersion":1,"participantId":pid or self.pid,"consentVersion":1},headers=headers,**kwargs)

    def test_default_closed_opened_and_idempotent_after_closing(self):
        self.assertEqual(self.register().status_code,403)
        self.store.set_enrollment_open(True)
        self.assertEqual(self.register().json,{"enrolledParticipantId":self.pid})
        self.store.set_enrollment_open(False)
        self.assertEqual(self.register().status_code,200)
        self.assertEqual(self.register(str(uuid.uuid4()),secrets.token_urlsafe(32)).status_code,403)
        self.assertEqual(self.store.enrollment_status()["used"],1)
        self.assertNotIn(self.token,json.dumps(self.store.tokens()))

    def test_requires_build_credential_and_consent_no_extra_text(self):
        self.store.set_enrollment_open(True)
        self.assertEqual(self.register(headers={"X-Research-Enrollment-Key":"wrong"}).status_code,401)
        self.assertEqual(self.register(token=self.key).status_code,422)
        headers={"Authorization":"Bearer "+self.token,"X-Research-Enrollment-Key":self.key}
        for payload in ({"schemaVersion":1,"participantId":self.pid,"consentVersion":0},
                        {"schemaVersion":1,"participantId":self.pid,"consentVersion":1,"phone":"PRIVATE"}):
            response=self.client.post("/api/research/enroll",json=payload,headers=headers)
            self.assertEqual(response.status_code,422)
            self.assertNotIn("PRIVATE",response.text)
        self.assertEqual(self.store.enrollment_status()["used"],0)

    def test_ten_limit_and_twenty_concurrent_new_installs(self):
        self.store.set_enrollment_open(True)
        installs=[(str(uuid.uuid4()),secrets.token_urlsafe(32)) for _ in range(20)]
        def attempt(item):
            try:
                self.store.enroll(*item); return 200
            except Rejected as error:
                return error.status
        with ThreadPoolExecutor(max_workers=12) as pool:
            codes=list(pool.map(attempt,installs))
        self.assertEqual(codes.count(200),10)
        self.assertEqual(codes.count(409),10)
        self.assertEqual(self.store.enrollment_status()["used"],10)

    def test_concurrent_same_install_consumes_one_slot(self):
        self.store.set_enrollment_open(True)
        with ThreadPoolExecutor(max_workers=8) as pool:
            result=list(pool.map(lambda _: self.store.enroll(self.pid,self.token),range(12)))
        self.assertEqual(set(result),{self.pid})
        self.assertEqual(self.store.enrollment_status()["used"],1)

    def test_bound_at_registration_cannot_upload_for_other_install(self):
        self.store.set_enrollment_open(True); self.register()
        batch=json.loads((ROOT/"test/fixtures/research_upload_v1.json").read_text())
        batch["participantId"]=str(uuid.uuid4())
        headers={"Authorization":"Bearer "+self.token,"Idempotency-Key":batch["batchId"]}
        self.assertEqual(self.client.post("/api/research/upload",json=batch,headers=headers).status_code,403)
        batch["participantId"]=self.pid
        self.assertEqual(self.client.post("/api/research/upload",json=batch,headers=headers).status_code,200)
        self.assertEqual(self.client.post("/api/research/upload",json=batch,headers={**headers,"Authorization":"Bearer "+self.key}).status_code,401)

    def test_credential_conflicts_revocation_delete_releases_and_denies_old(self):
        self.store.set_enrollment_open(True); self.register()
        self.assertEqual(self.register(token=secrets.token_urlsafe(32)).status_code,409)
        self.assertEqual(self.register(pid=str(uuid.uuid4())).status_code,409)
        self.store.revoke(self.store.tokens()[0]["id"])
        self.assertEqual(self.register().status_code,403)
        self.assertEqual(self.store.enrollment_status()["used"],1)
        self.store.delete_participant(self.pid)
        self.assertEqual(self.store.enrollment_status()["used"],0)
        self.assertEqual(self.register().status_code,403)
        self.assertEqual(self.register(str(uuid.uuid4()),secrets.token_urlsafe(32)).status_code,200)

    def test_admin_switch_rename_and_delete_before_first_upload(self):
        self.assertEqual(self.client.get("/pilot").status_code,404)
        client=admin_app(self.store,{"session_secret":"s"*64,"admin_key":"a"*60,"upload_port":8765}).test_client()
        with client.session_transaction() as session:
            session.update(authenticated=True,csrf="test-csrf")
        self.assertEqual(client.post("/pilot",data={"opened":"yes"}).status_code,403)
        self.assertEqual(client.post("/pilot",data={"csrf":"test-csrf","opened":"yes"}).status_code,302)
        self.register()
        token_id=self.store.tokens()[0]["id"]
        self.assertEqual(client.post(f"/tokens/{token_id}/rename",data={"csrf":"test-csrf","label":"试用者 A"}).status_code,302)
        page=client.get("/pilot")
        self.assertEqual(page.status_code,200)
        self.assertIn("试用者 A",page.text)
        self.assertNotIn(self.key,page.text)
        self.assertEqual(client.post(f"/participants/{self.pid}/delete",data={"csrf":"test-csrf","confirm":self.pid}).status_code,302)
        self.assertEqual(self.store.enrollment_status()["used"],0)

    def test_v1_migration_preserves_existing_tokens(self):
        old=Path(self.temp.name)/"old.sqlite3"
        with closing(sqlite3.connect(old)) as db:
            db.executescript(SCHEMA)
            db.execute("INSERT INTO tokens VALUES (?,?,?,?,NULL,NULL)",(str(uuid.uuid4()),"hash","legacy",123))
            db.commit()
        migrated=Store(old)
        self.assertEqual(migrated.tokens()[0]["label"],"legacy")
        self.assertFalse(migrated.enrollment_status()["opened"])
        self.assertEqual(Store(old).enrollment_status()["used"],0)
