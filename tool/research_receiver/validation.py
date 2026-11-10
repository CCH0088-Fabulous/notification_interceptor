"""Strict v1 wire contract. Unknown/free-text fields never reach storage."""

from __future__ import annotations

import hashlib
import json
import re
import uuid

MAX_BYTES = 512 * 1024
HOUR_MS = 3_600_000
MAX_TIMESTAMP = 4_102_444_800_000  # 2100-01-01 UTC
MAX_COUNTER = 10**12
ACTIONS = {
    "page_feed", "page_rules", "page_history", "page_settings", "open_presets",
    "open_comparison", "comparison_completed", "scene_switch", "scene_end",
    "preset_apply", "preset_restore", "preset_import", "preset_export",
}
METRICS = {
    "foreground_sessions", "foreground_ms", "engine_enabled_observed_ms",
    "listener_connected_observed_ms", "observation_gap_ms", "listener_connections",
    "listener_disconnects", "processed", "allow", "log_only", "intercept_matched",
    "cancel_success", "cancel_failed", "cancel_rejected", "cancel_unconfirmed",
    "existing_processed", "existing_allow", "existing_log_only", "existing_intercept_matched",
    "existing_cancel_success", "existing_cancel_failed", "existing_cancel_rejected",
    "existing_cancel_unconfirmed", "summaries_excluded", "rules_saved", "rules_added",
    "rules_removed", "rules_modified", "rules_toggled", "global_toggled", "presets_saved",
    "preset_version_saved", "history_cleared", "history_exported", "manual_cancel_requested",
    "retention_dropped_events", "retention_dropped_hours", "retention_dropped_batches",
} | {f"action_{action}" for action in ACTIONS}
STRUCTURE_FIELDS = {
    "kind", "action", "enabled", "mode", "keywordCountBand", "applicationCountBand",
    "hasRegex", "hasChannelCondition", "hasSchedule", "count",
}


class ValidationError(ValueError):
    """Safe error text: never echoes received data or unknown field names."""


def canonical_json(value: object) -> str:
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False)


def digest(value: object) -> str:
    return hashlib.sha256(canonical_json(value).encode("utf-8")).hexdigest()


def _object(value: object, fields: set[str]) -> dict:
    if type(value) is not dict or set(value) != fields:
        raise ValidationError("字段与 v1 协议不一致；不接受额外文本或调试字段")
    return value


def _integer(value: object, low: int = 0, high: int = MAX_COUNTER) -> int:
    if type(value) is not int or not low <= value <= high:
        raise ValidationError("整数、计数或时间超出协议范围")
    return value


def _timestamp(value: object, *, hour: bool = False) -> int:
    result = _integer(value, 946_684_800_000, MAX_TIMESTAMP)
    if hour and result % HOUR_MS:
        raise ValidationError("小时起点必须按 UTC 整小时对齐")
    return result


def _boolean(value: object) -> bool:
    if type(value) is not bool:
        raise ValidationError("布尔开关格式无效")
    return value


def _enum(value: object, choices: set[str]) -> str:
    if type(value) is not str or value not in choices:
        raise ValidationError("枚举值不在协议范围内")
    return value


def identifier(value: object) -> str:
    if type(value) is not str:
        raise ValidationError("研究或批次编号格式无效")
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError):
        raise ValidationError("研究或批次编号格式无效") from None
    if str(parsed) != value or parsed.int == 0:
        raise ValidationError("研究或批次编号格式无效")
    return value


def validate_enrollment(value: object) -> dict:
    obj = _object(value, {"schemaVersion", "participantId", "consentVersion"})
    if type(obj["schemaVersion"]) is not int or obj["schemaVersion"] != 1:
        raise ValidationError("不支持的登记协议版本")
    if type(obj["consentVersion"]) is not int or obj["consentVersion"] not in (1,2):
        raise ValidationError("需要有效的研究同意版本")
    identifier(obj["participantId"])
    return obj


def load_json(raw: bytes, max_bytes=MAX_BYTES) -> dict:
    if not raw or len(raw) > max_bytes:
        raise ValidationError("内容为空或超过允许的文件大小")

    def unique_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValidationError("JSON 包含重复字段")
            result[key] = value
        return result

    def reject_constant(_):
        raise ValidationError("JSON 数值格式无效")

    try:
        parsed = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_pairs, parse_constant=reject_constant)
        pending = [(parsed, 0)]
        while pending:
            node, depth = pending.pop()
            if depth > 16:
                raise ValidationError("JSON 嵌套超过协议所需范围")
            if isinstance(node, dict):
                pending.extend((child, depth+1) for child in node.values())
            elif isinstance(node, list):
                pending.extend((child, depth+1) for child in node)
        return parsed
    except ValidationError:
        raise
    except (ValueError, RecursionError):
        raise ValidationError("请求必须是有效 UTF-8 JSON") from None


def validate_payload(value: object, *, max_hours=96) -> dict:
    batch = _object(value, {
        "schemaVersion", "kind", "batchId", "participantId", "createdAt", "consent",
        "app", "scope", "hours", "ruleSnapshot", "coverage",
    })
    if type(batch["schemaVersion"]) is not int or batch["schemaVersion"] != 1 or batch["kind"] != "notification_research_batch":
        raise ValidationError("不支持的研究协议版本或类型")
    identifier(batch["batchId"])
    identifier(batch["participantId"])
    _timestamp(batch["createdAt"])
    consent = _object(batch["consent"], {"version", "acceptedAt", "ruleStructures", "configurationRevision"})
    if type(consent["version"]) is not int or consent["version"] not in (1, 2):
        raise ValidationError("不支持的同意说明版本")
    _timestamp(consent["acceptedAt"])
    _integer(consent["configurationRevision"], 1)
    _boolean(consent["ruleStructures"])
    app = _object(batch["app"], {"version", "androidApi"})
    if type(app["version"]) is not str or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+\-]{0,79}", app["version"]):
        raise ValidationError("软件版本格式无效")
    _integer(app["androidApi"], 26, 100)
    scope = _object(batch["scope"], {"unit", "historyIndependent", "foregroundAndCoverage", "retentionDays"})
    if (scope["unit"] != "processing_event" or scope["historyIndependent"] is not True
            or scope["foregroundAndCoverage"] != "observed_only"
            or type(scope["retentionDays"]) is not int or scope["retentionDays"] != 30):
        raise ValidationError("统计口径与当前发送端不一致")
    coverage = _object(batch["coverage"], {"retentionDroppedEvents", "retentionDroppedHours", "retentionDroppedBatches"})
    for count in coverage.values():
        _integer(count)
    hours = batch["hours"]
    if type(hours) is not list or len(hours) > max_hours:
        raise ValidationError("小时分组数量超过允许范围")
    seen = set()
    for hour in hours:
        _object(hour, {"bucketStart", "utcOffsetMinutes", "cohort", "revision", "metrics"})
        _timestamp(hour["bucketStart"], hour=True)
        _integer(hour["utcOffsetMinutes"], -840, 840)
        _enum(hour["cohort"], {"pilot", "demo"})
        _integer(hour["revision"], 1)
        key = (hour["bucketStart"], hour["utcOffsetMinutes"], hour["cohort"])
        if key in seen:
            raise ValidationError("同一批次重复包含小时分组")
        seen.add(key)
        metrics = hour["metrics"]
        if type(metrics) is not dict or not metrics or not set(metrics) <= METRICS:
            raise ValidationError("指标不在固定白名单中")
        for count in metrics.values():
            _integer(count)
        for prefix in ("", "existing_"):
            count = lambda name: metrics.get(prefix + name, 0)
            if count("processed") != count("allow") + count("log_only") + count("intercept_matched"):
                raise ValidationError("处理总数与动作计数不一致")
            if sum(count(name) for name in ("cancel_success", "cancel_failed", "cancel_rejected", "cancel_unconfirmed")) > count("intercept_matched"):
                raise ValidationError("最终移出结果超过命中数量")
    profile = batch["ruleSnapshot"]
    if profile is not None:
        if not consent["ruleStructures"]:
            raise ValidationError("未同意结构统计的批次不能包含结构快照")
        _object(profile, {"revision", "capturedAtBucket", "structures"})
        _integer(profile["revision"], 1)
        _timestamp(profile["capturedAtBucket"], hour=True)
        structures = profile["structures"]
        if type(structures) is not list or len(structures) > 2048:
            raise ValidationError("规则结构数量超限")
        signatures = set()
        for structure in structures:
            _object(structure, STRUCTURE_FIELDS)
            _enum(structure["kind"], {"scene", "keywords", "manual_or_legacy"})
            _enum(structure["action"], {"allow", "intercept", "log_only"})
            _enum(structure["mode"], {"all", "any"})
            for field in ("enabled", "hasRegex", "hasChannelCondition", "hasSchedule"):
                _boolean(structure[field])
            for field in ("keywordCountBand", "applicationCountBand"):
                _enum(structure[field], {"0", "1", "2-5", "6-20", "21+"})
            _integer(structure["count"], 1, 100_000)
            signature = canonical_json({k: v for k, v in structure.items() if k != "count"})
            if signature in signatures:
                raise ValidationError("相同规则结构需要先合并计数")
            signatures.add(signature)
    # Freeze away any caller-owned objects; canonical hashing ignores JSON key order.
    return json.loads(canonical_json(batch))
