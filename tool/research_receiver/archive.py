"""Bounded offline archive reader. Never extracts a file onto disk."""

import io
import re
import zipfile
import zlib

from .validation import (METRICS, ValidationError, _integer, _object, _timestamp,
                         load_json, validate_payload)

MAX_ZIP_BYTES = 24 * 1024 * 1024
MAX_JSON_BYTES = 64 * 1024 * 1024


def read_archive(raw: bytes):
    if not raw or len(raw) > MAX_ZIP_BYTES:
        raise ValidationError("请选择不超过 24 MiB 的内测 ZIP 文件")
    try:
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            entries = archive.infolist()
            if (len(entries) != 1 or entries[0].filename != "research.json" or entries[0].is_dir()
                    or entries[0].flag_bits & 1 or entries[0].file_size > MAX_JSON_BYTES
                    or entries[0].compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED)):
                raise ValidationError("内测文件结构或解压大小不符合协议")
            with archive.open(entries[0]) as stream:
                content = stream.read(MAX_JSON_BYTES+1)
        return validate_archive(load_json(content, max_bytes=MAX_JSON_BYTES))
    except ValidationError:
        raise
    except (zipfile.BadZipFile, RuntimeError, EOFError, NotImplementedError, ValueError, zlib.error):
        raise ValidationError("内测文件损坏或格式不受支持") from None


def as_batch(archive):
    fields = ("schemaVersion", "participantId", "createdAt", "consent", "app", "scope", "hours", "ruleSnapshot", "coverage")
    return {**{key: archive[key] for key in fields}, "kind": "notification_research_batch", "batchId": archive["exportId"]}


def validate_archive(value):
    _object(value, {"schemaVersion", "kind", "exportId", "participantId", "createdAt", "consent", "app", "scope",
                    "period", "retention", "captureFailuresSinceProcessStart", "coverage", "hours", "events", "ruleSnapshot"})
    if value["kind"] != "notification_research_export":
        raise ValidationError("请选择手机生成的完整内测文件")
    # Reuse the same strict hourly/structure vocabulary, with a larger file limit.
    validate_payload(as_batch(value), max_hours=4096)
    period = _object(value["period"], {"startedAt", "endedAt"})
    _timestamp(period["startedAt"])
    if period["startedAt"] != value["consent"]["acceptedAt"]:
        raise ValidationError("周期开始与同意时间不一致")
    _integer(period["endedAt"], 0, 4_102_444_800_000)
    if period["endedAt"] and not period["startedAt"] <= period["endedAt"] <= value["createdAt"]:
        raise ValidationError("内测结束时间不在有效周期内")
    if period["startedAt"] > value["createdAt"]:
        raise ValidationError("内测开始时间晚于文件创建时间")
    retention = _object(value["retention"], {"eventDays", "hourDays", "eventLimit", "hourLimit", "databaseMaxBytes"})
    expected = {"eventDays":14 if value["consent"]["version"] == 2 else 7,"hourDays":30,"eventLimit":50000,"hourLimit":4096,"databaseMaxBytes":64*1024*1024}
    if any(type(retention[k]) is not int or retention[k] != v for k,v in expected.items()):
        raise ValidationError("内测文件保留范围不受支持")
    _integer(value["captureFailuresSinceProcessStart"])
    events = value["events"]
    if type(events) is not list or len(events) > 50000:
        raise ValidationError("事件明细数量超限")
    seen = set()
    for event in events:
        _object(event, {"eventId", "at", "bucketStart", "utcOffsetMinutes", "cohort", "metrics"})
        if type(event["eventId"]) is not str or not re.fullmatch(r"[a-f0-9]{64}", event["eventId"]) or event["eventId"] in seen:
            raise ValidationError("事件明细编号无效或重复")
        seen.add(event["eventId"])
        _timestamp(event["at"])
        _timestamp(event["bucketStart"], hour=True)
        _integer(event["utcOffsetMinutes"], -840, 840)
        if event["cohort"] not in ("pilot", "demo"):
            raise ValidationError("事件明细分组无效")
        metrics = event["metrics"]
        if type(metrics) is not dict or not metrics or not set(metrics) <= METRICS:
            raise ValidationError("事件明细包含不允许的字段")
        for count in metrics.values():
            _integer(count)
    return value
