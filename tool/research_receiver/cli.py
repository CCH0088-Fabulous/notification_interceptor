"""Small desktop service lifecycle; no OS startup tasks or network exposure."""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import secrets
import signal
import threading
import time
from urllib.error import URLError
from urllib.request import urlopen
import uuid

from .storage import Store
from .web import admin_app, upload_app

ROOT = Path(__file__).resolve().parents[2]


def _secret(path, factory):
    try:
        with path.open("x", encoding="utf-8") as file:
            os.chmod(path, 0o600)
            file.write(factory())
    except FileExistsError:
        pass
    return path.read_text(encoding="utf-8").strip()


def credentials(directory):
    directory.mkdir(parents=True, exist_ok=True)
    return {"admin_key": _secret(directory / "admin-key.txt", lambda: secrets.token_urlsafe(40)),
            "session_secret": _secret(directory / "session-secret.txt", lambda: secrets.token_hex(32)),
            "enrollment_key": _secret(directory / "enrollment-key.txt", lambda: secrets.token_urlsafe(32))}


@contextmanager
def service_lock(path):
    with path.open("a+b") as file:
        file.seek(0, 2)
        if file.tell() == 0:
            file.write(b"0")
            file.flush()
        file.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(file.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise RuntimeError("此数据目录已有接收端运行") from None
        try:
            yield
        finally:
            file.seek(0)
            if os.name == "nt":
                msvcrt.locking(file.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(file, fcntl.LOCK_UN)


def _write_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(path)


def running(directory):
    try:
        runtime = json.loads((directory / "runtime.json").read_text(encoding="utf-8"))
        if runtime.get("state") != "running":
            return None
        with urlopen(f"http://127.0.0.1:{int(runtime['upload_port'])}/health", timeout=2) as reply:
            health = json.load(reply)
        return runtime if health.get("instanceId") == runtime["instance_id"] else None
    except (OSError, ValueError, KeyError, URLError):
        return None


def serve(directory, upload_port, admin_port):
    from waitress import create_server

    if upload_port == admin_port:
        raise ValueError("上传与管理端口必须不同")
    directory.mkdir(parents=True, exist_ok=True)
    with service_lock(directory / "service.lock"):
        config = credentials(directory)
        config["upload_port"] = upload_port
        store = Store(directory / "receiver.sqlite3")
        instance_id = str(uuid.uuid4())
        stop_event = threading.Event()
        for signal_name in ("SIGINT", "SIGTERM"):
            signal.signal(getattr(signal, signal_name), lambda *_: stop_event.set())
        servers = []
        threads = []
        runtime = {"state": "running", "pid": os.getpid(), "instance_id": instance_id,
                   "upload_port": upload_port, "admin_port": admin_port, "started_at": int(time.time())}
        try:
            for application, port, workers in (
                (upload_app(store, instance_id, config["enrollment_key"]), upload_port, 4), (admin_app(store, config), admin_port, 2)
            ):
                server = create_server(application, host="127.0.0.1", port=port, map={}, threads=workers,
                                       max_request_body_size=512*1024, max_request_header_size=16*1024,
                                       channel_timeout=30, connection_limit=64, expose_tracebacks=False,
                                       clear_untrusted_proxy_headers=True, ident="LocalResearchReceiver",
                                       asyncore_loop_timeout=0.2)
                servers.append(server)
                thread = threading.Thread(target=server.run, name=f"receiver-{port}", daemon=True)
                thread.start()
                threads.append(thread)
            _write_json(directory / "runtime.json", runtime)
            print(f"Admin: http://127.0.0.1:{admin_port}", flush=True)
            print(f"Upload: http://127.0.0.1:{upload_port}/api/research/upload", flush=True)
            print(f"Admin key file: {directory / 'admin-key.txt'}", flush=True)
            while not stop_event.wait(0.25):
                marker = directory / "stop.request"
                if marker.exists() and marker.read_text(encoding="utf-8").strip() == instance_id:
                    marker.unlink()
                    break
                if any(not thread.is_alive() for thread in threads):
                    raise RuntimeError("接收监听线程意外停止")
        finally:
            for server in servers:
                server.close()
                server.task_dispatcher.shutdown(timeout=5)
            for thread in threads:
                thread.join(timeout=2)
            runtime["state"] = "stopped"
            _write_json(directory / "runtime.json", runtime)


def main():
    parser = argparse.ArgumentParser(description="手机通知研究：本地 SQLite 接收端")
    parser.add_argument("action", choices=("serve", "status", "stop"), nargs="?", default="serve")
    parser.add_argument("--data-dir", type=Path, default=ROOT / ".local/research-receiver")
    parser.add_argument("--upload-port", type=int, default=8765)
    parser.add_argument("--admin-port", type=int, default=8766)
    args = parser.parse_args()
    directory = args.data_dir.resolve()
    if not all(1024 <= port <= 65535 for port in (args.upload_port, args.admin_port)):
        parser.error("端口须为 1024–65535")
    try:
        if args.action == "serve":
            serve(directory, args.upload_port, args.admin_port)
        else:
            runtime = running(directory)
            if not runtime:
                print("Receiver is not running.")
                return 1 if args.action == "status" else 0
            if args.action == "status":
                print(f"Running. Admin: http://127.0.0.1:{runtime['admin_port']} | Upload port: {runtime['upload_port']}")
            else:
                (directory / "stop.request").write_text(runtime["instance_id"], encoding="utf-8")
                for _ in range(80):
                    time.sleep(0.25)
                    if not running(directory):
                        print("Receiver stopped.")
                        return 0
                raise RuntimeError("停止请求已提交，接收端仍在完成请求；请检查本地日志")
    except (OSError, RuntimeError, ValueError) as error:
        print(f"Receiver: {error}")
        return 1
    return 0
