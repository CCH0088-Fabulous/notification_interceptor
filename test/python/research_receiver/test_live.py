"""Actual Waitress sockets, process lifecycle, sender-compatible HTTP and persistence."""

from contextlib import closing
import csv
import http.cookiejar
import io
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPCookieProcessor, Request, build_opener, urlopen
import uuid

from tool.research_receiver.storage import Store

ROOT = Path(__file__).resolve().parents[3]


class LiveServiceTest(unittest.TestCase):
    def test_http_ack_revision_restart_admin_isolation_and_stop(self):
        temporary_root = ROOT / "build/receiver-verification"
        temporary_root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=temporary_root) as directory_name:
            directory = Path(directory_name)
            assert directory.resolve().parent == temporary_root.resolve()
            ports = []
            for _ in range(2):
                with closing(socket.socket()) as sock:
                    sock.bind(("127.0.0.1", 0)); ports.append(sock.getsockname()[1])
            upload, admin = (f"http://127.0.0.1:{port}" for port in ports)
            args = [sys.executable, str(ROOT/"tool/run_research_receiver.py"), "serve", "--data-dir", str(directory),
                    "--upload-port", str(ports[0]), "--admin-port", str(ports[1])]
            with (directory/"process.log").open("w", encoding="utf-8") as log:
                process = None
                def start():
                    nonlocal process
                    process = subprocess.Popen(args, cwd=ROOT, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
                    for _ in range(100):
                        if process.poll() is not None:
                            self.fail("Verification service exited before becoming ready")
                        try:
                            with urlopen(upload+"/health", timeout=.3) as reply:
                                return json.load(reply)["instanceId"]
                        except (URLError, OSError):
                            time.sleep(.1)
                    self.fail("Verification service readiness timed out")

                def stop():
                    state = json.loads((directory/"runtime.json").read_text(encoding="utf-8"))
                    (directory/"stop.request").write_text(state["instance_id"], encoding="utf-8")
                    self.assertEqual(process.wait(timeout=15), 0)

                def post(batch, token):
                    request = Request(upload+"/api/research/upload", data=json.dumps(batch).encode(), headers={
                        "Content-Type": "application/json; charset=utf-8", "Authorization": "Bearer "+token,
                        "Idempotency-Key": batch["batchId"]})
                    with urlopen(request, timeout=5) as reply:
                        return json.load(reply)
                try:
                    first_instance = start()
                    store = Store(directory/"receiver.sqlite3")
                    _, token = store.create_token("live socket verification")
                    batch = json.loads((ROOT/"test/fixtures/research_upload_v1.json").read_text(encoding="utf-8"))
                    self.assertEqual(post(batch, token)["acceptedBatchId"], batch["batchId"])
                    self.assertEqual(post(batch, token)["acceptedBatchId"], batch["batchId"])
                    batch["batchId"] = str(uuid.uuid4())
                    batch["hours"][0]["revision"] += 1
                    batch["hours"][0]["metrics"].update(processed=5, allow=4)
                    post(batch, token)
                    with self.assertRaises(HTTPError) as error:
                        urlopen(upload+"/tokens", timeout=3)
                    self.assertEqual(error.exception.code, 404)
                    error.exception.close()
                    # Host protection applies even to local connections and forwarded headers.
                    with self.assertRaises(HTTPError) as error:
                        urlopen(Request(admin+"/login", headers={"Host":"attacker.invalid"}), timeout=3)
                    self.assertEqual(error.exception.code, 403)
                    error.exception.close()
                    stop()
                    second_instance = start()
                    self.assertNotEqual(first_instance, second_instance)
                    self.assertEqual(store.report(0,4102444800000,"demo")["sums"]["processed"], 5)
                    # Authenticate with the actual cookie + CSRF form and export over HTTP.
                    browser = build_opener(HTTPCookieProcessor(http.cookiejar.CookieJar()))
                    with browser.open(admin+"/login", timeout=3) as reply:
                        html = reply.read().decode()
                    csrf = html.split('name="csrf" value="',1)[1].split('"',1)[0]
                    key = (directory/"admin-key.txt").read_text(encoding="utf-8").strip()
                    with browser.open(admin+"/login", data=urlencode({"csrf":csrf,"key":key}).encode(), timeout=3) as reply:
                        self.assertEqual(reply.status, 200)
                    with browser.open(admin+"/export.csv?since=2026-11-01&until=2026-11-30&cohort=demo", timeout=3) as reply:
                        rows = list(csv.DictReader(io.StringIO(reply.read().decode("utf-8-sig"))))
                    self.assertEqual(rows[0]["processed"], "5")
                    stop()
                    self.assertEqual(json.loads((directory/"runtime.json").read_text())["state"], "stopped")
                finally:
                    if process is not None and process.poll() is None:
                        process.terminate()
                        process.wait(timeout=15)
