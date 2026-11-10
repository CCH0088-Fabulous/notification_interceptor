"""Separate phone-upload and loopback-only administration applications."""

from __future__ import annotations

import csv
from datetime import datetime, timedelta, timezone
from functools import wraps
import hmac
import io
import ipaddress
import json
from pathlib import Path
import secrets
import sqlite3
from urllib.parse import urlsplit

from flask import Flask, Response, abort, jsonify, redirect, render_template, request, send_file, session, stream_with_context, url_for
from werkzeug.exceptions import HTTPException

from .storage import Rejected, Store
from .validation import MAX_BYTES, METRICS, ValidationError, identifier, load_json, validate_payload, validate_enrollment
from .archive import MAX_ZIP_BYTES, read_archive

REPORT_TZ = timezone(timedelta(hours=8))
REPO = Path(__file__).resolve().parents[2]


def _base(name):
    app = Flask(name, template_folder=str(Path(__file__).parent / "templates"),
                static_folder=str(Path(__file__).parent / "static"))
    app.config.update(MAX_CONTENT_LENGTH=MAX_BYTES, MAX_FORM_MEMORY_SIZE=16_384,
                      SESSION_COOKIE_HTTPONLY=True, SESSION_COOKIE_SAMESITE="Strict",
                      PERMANENT_SESSION_LIFETIME=timedelta(hours=8))

    @app.after_request
    def headers(response):
        response.headers.update({
            "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "no-referrer", "X-Frame-Options": "DENY",
            "Content-Security-Policy": "default-src 'none'; style-src 'self'; font-src 'self'; img-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
        })
        return response

    @app.errorhandler(HTTPException)
    def http_error(error):
        return jsonify(error="请求未被接受", status=error.code), error.code

    @app.errorhandler(sqlite3.Error)
    def unavailable(_):
        return jsonify(error="本地数据库暂不可用，请稍后重试"), 503

    return app


def upload_app(store: Store, instance_id: str, enrollment_key: str = ""):
    app = _base("research_upload")

    @app.get("/health")
    def health():
        return jsonify(service="notification-research-receiver", protocol=1, instanceId=instance_id)

    @app.post("/api/research/enroll")
    def enroll():
        supplied = request.headers.get("X-Research-Enrollment-Key", "")
        if not enrollment_key or not hmac.compare_digest(supplied.encode(), enrollment_key.encode()):
            return jsonify(error="内测登记凭证无效"), 401
        if request.mimetype != "application/json":
            abort(415)
        if request.content_length is not None and request.content_length > 4096:
            abort(413)
        authorization = request.headers.get("Authorization", "")
        if not authorization.startswith("Bearer "):
            abort(401)
        if hmac.compare_digest(authorization[7:].encode(), enrollment_key.encode()):
            return jsonify(error="设备上传凭证必须与内测登记凭证独立"), 422
        try:
            raw = request.get_data(cache=False)
            if len(raw) > 4096:
                abort(413)
            payload = validate_enrollment(load_json(raw))
            enrolled = store.enroll(payload["participantId"], authorization[7:])
            return jsonify(enrolledParticipantId=enrolled)
        except ValidationError as error:
            return jsonify(error=str(error)), 422
        except Rejected as error:
            return jsonify(error=str(error)), error.status

    @app.post("/api/research/upload")
    def upload():
        authorization = request.headers.get("Authorization", "")
        if not authorization.startswith("Bearer "):
            return jsonify(error="需要受限上传令牌"), 401
        raw_token = authorization[7:]
        try:
            store.authenticate(raw_token)
            if request.mimetype != "application/json":
                return jsonify(error="仅接受 application/json"), 415
            try:
                value = load_json(request.get_data(cache=False))
            except ValidationError as error:
                return jsonify(error=str(error)), 400
            try:
                batch = validate_payload(value)
            except ValidationError as error:
                return jsonify(error=str(error)), 422
            if request.headers.get("Idempotency-Key") != batch["batchId"]:
                return jsonify(error="批次头与内容编号不一致"), 400
            accepted = store.accept(raw_token, batch)
            return jsonify(acceptedBatchId=accepted)
        except Rejected as error:
            return jsonify(error=str(error)), error.status

    return app


def admin_app(store: Store, config: dict):
    app = _base("research_admin")
    app.secret_key = config["session_secret"]
    app.config["SESSION_COOKIE_NAME"] = "research_receiver_admin"
    app.config.update(MAX_CONTENT_LENGTH=32*1024*1024, MAX_FORM_MEMORY_SIZE=256*1024, MAX_FORM_PARTS=24)

    @app.before_request
    def local_and_csrf():
        try:
            local = ipaddress.ip_address(request.remote_addr or "").is_loopback
            host = urlsplit("http://" + request.host).hostname
        except ValueError:
            abort(403)
        if not local or host not in {"localhost", "127.0.0.1", "::1"}:
            abort(403)
        if request.method == "POST":
            origin = request.headers.get("Origin")
            if origin and origin != request.host_url.rstrip("/"):
                abort(403)
            expected, supplied = session.get("csrf", ""), request.form.get("csrf", "")
            if not expected or not hmac.compare_digest(expected.encode(), supplied.encode()):
                abort(403)

    def protected(view):
        @wraps(view)
        def wrapper(*args, **kwargs):
            if session.get("authenticated") is not True:
                return redirect(url_for("login"))
            return view(*args, **kwargs)
        return wrapper

    @app.context_processor
    def context():
        if "csrf" not in session:
            session["csrf"] = secrets.token_urlsafe(32)
        return {"csrf": session["csrf"], "local_time": local_time}

    @app.get("/font.otf")
    def font():
        return send_file(REPO / "android/generator/src/main/res/font/source_han_serif_sc_regular.otf", mimetype="font/otf")

    @app.get("/font-license.txt")
    def font_license():
        return send_file(REPO / "assets/licenses/SourceHanSerif-OFL.txt", mimetype="text/plain")

    @app.route("/login", methods=["GET", "POST"])
    def login():
        error = None
        if request.method == "POST":
            if hmac.compare_digest(request.form.get("key", "").encode(), config["admin_key"].encode()):
                session.clear()
                session["authenticated"] = True
                session["csrf"] = secrets.token_urlsafe(32)
                session.permanent = True
                return redirect(url_for("dashboard"))
            error = "管理密钥不正确"
        return render_template("login.html", error=error), 401 if error else 200

    @app.post("/logout")
    @protected
    def logout():
        session.clear()
        return redirect(url_for("login"))

    def filters():
        today = datetime.now(REPORT_TZ).date()
        try:
            since = datetime.strptime(request.args.get("since", str(today-timedelta(days=6))), "%Y-%m-%d").date()
            until = datetime.strptime(request.args.get("until", str(today)), "%Y-%m-%d").date()
            cohort = request.args.get("cohort", "pilot")
            page = int(request.args.get("page", "1"))
            if since > until or cohort not in {"pilot", "demo"} or not 1 <= page <= 1_000_000:
                raise ValueError
        except (ValueError, OverflowError):
            abort(400)
        start = int(datetime.combine(since, datetime.min.time(), REPORT_TZ).timestamp()*1000)
        end = int(datetime.combine(until+timedelta(days=1), datetime.min.time(), REPORT_TZ).timestamp()*1000)
        return start, end, cohort, page, {"since": str(since), "until": str(until), "cohort": cohort}

    @app.get("/")
    @protected
    def dashboard():
        start, end, cohort, page, query = filters()
        report = store.report(start, end, cohort, page=page)
        return render_template("dashboard.html", report=report, query=query)

    @app.route("/imports", methods=["GET", "POST"])
    @protected
    def imports():
        results = []
        if request.method == "POST":
            files = request.files.getlist("archives")
            if not 1 <= len(files) <= 10:
                abort(400)
            for file in files:
                try:
                    archive = read_archive(file.stream.read(MAX_ZIP_BYTES+1))
                    store.import_archive(archive)
                    results.append({"ok":True,"name":file.filename,"message":f"已导入 / 确认：{len(archive['hours'])} 个小时组、{len(archive['events'])} 条事件明细；重复内容不叠加"})
                except (ValidationError, Rejected) as error:
                    results.append({"ok":False,"name":file.filename,"message":str(error)})
        return render_template("imports.html", offline=store.offline_status(), results=results)

    @app.post("/offline/<participant>/rename")
    @protected
    def rename_offline(participant):
        try:
            store.rename_offline(participant,request.form.get("label",""))
        except ValueError:
            abort(400)
        return redirect(url_for("imports"))

    @app.get("/participants/<participant>/events.csv")
    @protected
    def export_events(participant):
        if store.participant(participant) is None:
            abort(404)
        metrics = sorted(METRICS)
        @stream_with_context
        def generate():
            buffer = io.StringIO(newline="")
            writer = csv.writer(buffer)
            yield "\ufeff"
            writer.writerow(["installation_id","event_id","at_utc_plus_08","bucket_utc_plus_08","source_utc_offset_minutes","cohort",*metrics])
            yield buffer.getvalue()
            for row in store.event_rows(participant):
                buffer.seek(0);buffer.truncate()
                values=json.loads(row["metrics"])
                writer.writerow([participant,row["id"],local_time(row["at_ms"]),local_time(row["bucket"]),row["offset"],row["cohort"],*(values.get(name,0) for name in metrics)])
                yield buffer.getvalue()
        return Response(generate(),mimetype="text/csv; charset=utf-8",headers={"Content-Disposition":'attachment; filename="research-events.csv"'})

    @app.get("/participants/<participant>")
    @protected
    def participant_detail(participant):
        try:
            identifier(participant)
        except ValidationError:
            abort(404)
        record = store.participant(participant)
        if record is None:
            abort(404)
        start, end, cohort, page, query = filters()
        return render_template("participant.html", participant=record, query=query,
                               report=store.report(start, end, cohort, participant, page))

    @app.post("/participants/<participant>/delete")
    @protected
    def delete(participant):
        if not store.known_participant(participant):
            abort(404)
        if request.form.get("confirm") != participant:
            abort(400)
        store.delete_participant(participant)
        return redirect(url_for("dashboard"))

    @app.route("/tokens", methods=["GET", "POST"])
    @protected
    def tokens():
        raw, error = None, None
        if request.method == "POST":
            try:
                _, raw = store.create_token(request.form.get("label", ""))
            except ValueError as exception:
                error = str(exception)
        return render_template("tokens.html", tokens=store.tokens(), raw_token=raw, error=error,
                               upload_url=f"http://10.0.2.2:{config['upload_port']}/api/research/upload")

    @app.route("/pilot", methods=["GET", "POST"])
    @protected
    def pilot():
        if request.method == "POST":
            store.set_enrollment_open(request.form.get("opened") == "yes")
            return redirect(url_for("pilot"))
        return render_template("pilot.html", enrollment=store.enrollment_status())

    @app.post("/tokens/<token_id>/rename")
    @protected
    def rename(token_id):
        try:
            store.rename_token(token_id, request.form.get("label", ""))
        except ValueError:
            abort(400)
        return redirect(url_for("pilot"))

    @app.post("/tokens/<token_id>/revoke")
    @protected
    def revoke(token_id):
        store.revoke(token_id)
        return redirect(url_for("tokens"))

    @app.get("/export.csv")
    @protected
    def export():
        start, end, cohort, _, _ = filters()
        metrics = sorted(METRICS)
        @stream_with_context
        def generate():
            buffer = io.StringIO(newline="")
            writer = csv.writer(buffer)
            yield "\ufeff"
            writer.writerow(["installation_id", "bucket_utc", "bucket_utc_plus_08", "source_utc_offset_minutes", "cohort", "revision", *metrics])
            yield buffer.getvalue()
            for row in store.export_rows(start, end, cohort):
                buffer.seek(0)
                buffer.truncate()
                values = json.loads(row["metrics"])
                writer.writerow([row["participant_id"], datetime.fromtimestamp(row["bucket"]/1000, timezone.utc).isoformat(),
                                 local_time(row["bucket"]), row["offset"], row["cohort"], row["revision"],
                                 *(values.get(name, 0) for name in metrics)])
                yield buffer.getvalue()
        return Response(generate(), mimetype="text/csv; charset=utf-8",
                        headers={"Content-Disposition": 'attachment; filename="research-hours.csv"'})

    return app


def local_time(milliseconds):
    return datetime.fromtimestamp(milliseconds / 1000, REPORT_TZ).strftime("%Y-%m-%d %H:%M:%S")
