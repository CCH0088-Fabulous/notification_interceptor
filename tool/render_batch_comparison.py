"""Render a self-contained batch-comparison report with FigCompose.

Run using the user's existing environment, without installing dependencies:
  D:\\Anaconda\\envs\\space1\\python.exe tool/render_batch_comparison.py --demo
  D:\\Anaconda\\envs\\space1\\python.exe tool/render_batch_comparison.py INPUT.json --source device

FigCompose is distributed as `figcompose` and imported as `data_visuals`.
All chart canvases/layout/exports below are produced by FigCompose. Custom
alluvial and paired-dot panels use its documented native-panel extension.
"""

from __future__ import annotations

import argparse
import base64
from collections import Counter, defaultdict
from datetime import datetime, timedelta
from html import escape
from importlib.metadata import version
from io import BytesIO
import json
from pathlib import Path
from zoneinfo import ZoneInfo

import matplotlib

matplotlib.use("Agg")
from matplotlib import font_manager
from matplotlib.patches import PathPatch, Rectangle
from matplotlib.path import Path as MplPath
import pandas as pd
from data_visuals import FigureConfig, plot
from data_visuals.core import Figure, PanelResult
from fontTools import subset
from fontTools.ttLib import TTFont


ROOT = Path(__file__).resolve().parents[1]
FONT = ROOT / "android/generator/src/main/res/font/source_han_serif_sc_regular.otf"
FONT_LICENSE = ROOT / "assets/licenses/SourceHanSerif-OFL.txt"
DEFAULT_OUTPUT = ROOT / "docs/visualizations/batch-comparison.html"
DEMO_PATH = ROOT / "docs/visualizations/data/batch-comparison-demo.json"
ACTIONS = ("allow", "log_only", "intercept")
LABELS = {"allow": "放行", "log_only": "仅记录", "intercept": "预计拦截"}
REASONS = {"default": "默认动作", "disabled": "全局关闭", "self": "本应用", "rule": "规则匹配"}


def normalized(payload: dict) -> dict:
    if payload.get("schemaVersion") != 1 or payload.get("kind") != "notification_batch_comparison":
        raise ValueError("请选择 schemaVersion 1 的批量效果对比导出文件")
    rows = payload.get("rows")
    if not isinstance(rows, list) or len(rows) > 1000:
        raise ValueError("rows 必须是最多 1000 条处理事件的数组")
    if payload.get("sampleCount") != len(rows):
        raise ValueError("sampleCount 与 rows 数量不一致")
    for row in rows:
        if not isinstance(row, dict) or type(row.get("timestamp")) is not int:
            raise ValueError("样本缺少历史处理时间")
        if not isinstance(row.get("record"), dict):
            raise ValueError("样本缺少通知快照")
        if row["record"].get("isGroupSummary"):
            raise ValueError("对比样本应已排除系统分组汇总")
        for side in ("before", "after"):
            if not isinstance(row.get(side), dict) or row[side].get("action") not in ACTIONS:
                raise ValueError("样本的回放动作无效")
    result = json.loads(json.dumps(payload, ensure_ascii=False))
    # Debug extras are unnecessary for this shareable presentation.
    for row in result["rows"]:
        row["record"].pop("extras", None)
    calculated = summarize(result["rows"])
    supplied = result.get("summary")
    if isinstance(supplied, dict):
        for key, value in calculated.items():
            if key in supplied and supplied[key] != value:
                raise ValueError(f"导出摘要 {key} 与逐条结果不一致")
    result["summary"] = calculated
    zone_name = result.get("zoneId") or "Asia/Shanghai"
    ZoneInfo(zone_name)
    result["zoneId"] = zone_name
    return result


def changed_rule(row: dict) -> bool:
    return any(row["before"].get(key) != row["after"].get(key) for key in ("ruleId", "reason"))


def summarize(rows: list[dict]) -> dict:
    before, after = Counter(), Counter()
    action_changed = rule_changed = total_changed = more = less = removed = 0
    for row in rows:
        first, second = row["before"]["action"], row["after"]["action"]
        before[first] += 1
        after[second] += 1
        action_changed += first != second
        rule_changed += changed_rule(row)
        total_changed += first != second or changed_rule(row)
        more += first != "intercept" and second == "intercept"
        less += first == "intercept" and second != "intercept"
        removed += row.get("historicalAction") == "intercept" and row.get("cancelStatus") == "success"
    return dict(before={a: before[a] for a in ACTIONS}, after={a: after[a] for a in ACTIONS},
                actionChanged=action_changed, ruleChanged=rule_changed, totalChanged=total_changed,
                moreIntercepted=more, lessIntercepted=less, historicalConfirmedRemoved=removed)


def local_time(timestamp: int, zone: str) -> datetime:
    return datetime.fromtimestamp(timestamp / 1000, tz=ZoneInfo(zone))


def fmt_time(timestamp: int | None, zone: str, short: bool = False) -> str:
    if timestamp is None:
        return "无样本"
    return local_time(timestamp, zone).strftime("%m-%d %H:%M:%S" if short else "%Y-%m-%d %H:%M:%S")


def app_identity(row: dict) -> tuple[str, str]:
    record = row["record"]
    package = record.get("packageName") or "未知应用"
    return package, record.get("appLabel") or package


def configure_font() -> str:
    if not FONT.is_file():
        raise FileNotFoundError(f"缺少仓库内置字体：{FONT}")
    font_manager.fontManager.addfont(str(FONT))
    return font_manager.FontProperties(fname=str(FONT)).get_name()


def flow_panel(rows: list[dict]):
    matrix = Counter((r["before"]["action"], r["after"]["action"]) for r in rows)
    first = Counter(r["before"]["action"] for r in rows)
    second = Counter(r["after"]["action"] for r in rows)

    def draw(ax, ctx):
        artists = []
        kw = ctx.text_kwargs(color="#111111", fontsize=10)
        if not rows:
            return PanelResult(artists=[ax.text(.5, .5, "暂无可比较的处理事件", ha="center", **kw)])
        positions = []
        for totals in (first, second):
            cursor, layout = .86, {}
            for action in ACTIONS:
                height = totals[action] / len(rows) * .61
                layout[action] = (cursor - height, height)
                cursor -= height + .075
            positions.append(layout)
        starts = {a: positions[0][a][0] for a in ACTIONS}
        ends = {a: positions[1][a][0] for a in ACTIONS}
        for a in ACTIONS:
            for b in ACTIONS:
                count = matrix[a, b]
                if not count:
                    continue
                height = count / len(rows) * .61
                y0, y1 = starts[a], ends[b]
                starts[a] += height
                ends[b] += height
                vertices = [(.19, y0), (.43, y0), (.57, y1), (.81, y1),
                            (.81, y1 + height), (.57, y1 + height), (.43, y0 + height),
                            (.19, y0 + height), (.19, y0)]
                codes = [MplPath.MOVETO, MplPath.CURVE4, MplPath.CURVE4, MplPath.CURVE4,
                         MplPath.LINETO, MplPath.CURVE4, MplPath.CURVE4, MplPath.CURVE4, MplPath.CLOSEPOLY]
                band = PathPatch(MplPath(vertices, codes), facecolor="#222222" if a != b else "#DCDCDC",
                                 edgecolor="white", linewidth=.4, alpha=.83 if a != b else .72)
                ax.add_patch(band)
        for index, x in enumerate((.17, .81)):
            for action in ACTIONS:
                y, height = positions[index][action]
                ax.add_patch(Rectangle((x, y), .02, height, facecolor="#111111", linewidth=0))
                text_x, alignment = (.145, "right") if index == 0 else (.855, "left")
                count = (first if index == 0 else second)[action]
                label = f"{LABELS[action]}\n{count} 条" if height >= .025 else f"{LABELS[action]} {count} 条"
                artists.append(ax.text(text_x, y + height / 2, label,
                                       ha=alignment, va="center", linespacing=1.6, **kw))
        for x, label in ((.17, "当前策略回放"), (.83, "候选策略回放")):
            artists.append(ax.text(x, .975, label, ha="center", va="top", **kw))
        artists.append(ax.text(.5, .025, "浅灰：动作保持一致    深灰：处理动作改变",
                               ha="center", va="bottom", **ctx.text_kwargs(fontsize=8, color="#555555")))
        return PanelResult(artists=artists)
    return draw


def paired_panel(rows: list[dict]):
    by_app = defaultdict(list)
    names = {}
    for row in rows:
        package, name = app_identity(row)
        names[package] = name
        by_app[package].append(row)
    packages = sorted(by_app, key=lambda p: (-sum(r["before"]["action"] != r["after"]["action"]
                                                 for r in by_app[p]), -len(by_app[p]), p))[:8]

    def draw(ax, ctx):
        text = ctx.text_kwargs(fontsize=8, color="#111111")
        artists = []
        if not packages:
            return PanelResult(artists=[ax.text(.5, .5, "无应用样本", ha="center", **text)])
        left, right, bottom, top = .32, .91, .15, .89
        for pct in (0, 25, 50, 75, 100):
            x = left + (right - left) * pct / 100
            ax.plot([x, x], [bottom, top], color="#E9E9E9", linewidth=.7, zorder=0)
            artists.append(ax.text(x, bottom - .055, f"{pct}%", ha="center", va="top", **text))
        for index, package in enumerate(packages):
            values = by_app[package]
            y = (top + bottom) / 2 if len(packages) == 1 else top - index / (len(packages) - 1) * (top - bottom)
            before = sum(r["before"]["action"] == "intercept" for r in values) / len(values)
            after = sum(r["after"]["action"] == "intercept" for r in values) / len(values)
            x0, x1 = left + before * (right - left), left + after * (right - left)
            name = names[package]
            if len(name) > 14:
                name = name[:13] + "…"
            artists.append(ax.text(.015, y, f"{name}\n{len(values)} 个处理事件", va="center",
                                   ha="left", linespacing=1.7, **text))
            ax.plot([x0, x1], [y, y], color="#A5A5A5", linewidth=2, zorder=1)
            ax.scatter([x0], [y], facecolor="white", edgecolor="#777777", s=35, linewidth=1.1, zorder=3)
            ax.scatter([x1], [y], facecolor="#111111", edgecolor="white", s=25, linewidth=.5, zorder=4)
        artists.append(ax.text(.61, .015, "○ 当前策略    ● 候选策略", ha="center", va="bottom", **text))
        return PanelResult(artists=artists)
    return draw


def hourly_panel(rows: list[dict], zone: str):
    labels = ("新增预计拦截", "减少预计拦截", "仅命中来源变化")
    counts = [[0] * 24 for _ in labels]
    for row in rows:
        before, after = row["before"]["action"], row["after"]["action"]
        kind = 0 if before != "intercept" and after == "intercept" else (
            1 if before == "intercept" and after != "intercept" else (
                2 if before == after and changed_rule(row) else None))
        if kind is not None:
            counts[kind][local_time(row["timestamp"], zone).hour] += 1

    def draw(ax, ctx):
        artists = []
        maximum = max(max(row) for row in counts) or 1
        left, right, top, height, gap = .16, .98, .76, .18, .055
        width = (right - left) / 24
        for ri, values in enumerate(counts):
            y = top - ri * (height + gap)
            artists.append(ax.text(left - .018, y + height / 2, labels[ri], ha="right", va="center",
                                   **ctx.text_kwargs(fontsize=8, color="#111111")))
            for hour, value in enumerate(values):
                shade = .97 - .86 * value / maximum
                ax.add_patch(Rectangle((left + hour * width, y), width - .002, height,
                                       facecolor=str(shade), edgecolor="white", linewidth=.45))
                if value:
                    artists.append(ax.text(left + (hour + .5) * width, y + height / 2,
                        str(value), ha="center", va="center",
                        **ctx.text_kwargs(fontsize=7, color="white" if shade < .5 else "#111111")))
        for hour in range(0, 24, 2):
            artists.append(ax.text(left + (hour + .5) * width, .23, f"{hour:02d}", ha="center", va="top",
                                   **ctx.text_kwargs(fontsize=8, color="#555555")))
        artists.append(ax.text(.57, .08, f"历史处理时刻 · {zone} · 同一小时跨日期合计",
                               ha="center", va="bottom", **ctx.text_kwargs(fontsize=8, color="#555555")))
        return PanelResult(artists=artists)
    return draw


def svg_contents(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    return "\n".join(line.rstrip() for line in text[text.index("<svg"):].splitlines()) + "\n"


def render_figures(payload: dict, output_dir: Path, font_family: str) -> tuple[dict, list]:
    rows = payload["rows"]
    config = FigureConfig(theme="general", font_family=font_family, background="#FFFFFF")
    figures = {}
    checks = []
    for name, draw, width, height in (
        ("flow", flow_panel(rows), 250, 105),
        ("apps", paired_panel(rows), 150, 122),
        ("hours", hourly_panel(rows, payload["zoneId"]), 250, 82),
    ):
        figure = Figure(rows=1, cols=1, config=config, canvas={"width": width, "height": height}, legend=False)
        figure[0, 0].custom(draw, min_size=(80, 45), preferred_aspect=width / height)
        path = output_dir / f"{name}.svg"
        figure.render(str(path))
        figure.render(str(output_dir / f"{name}.png"), dpi=160)
        report = figure.check()
        checks.append({"figure": name, "ok": report.ok, "summary": report.summary()})
        if not report.ok:
            raise ValueError(f"FigCompose 图形布局检查未通过：{name}: {report.summary()}")
        figures[name] = svg_contents(path)
    counts = Counter((r["before"]["action"], r["after"]["action"]) for r in rows)
    frame = pd.DataFrame([{"before": LABELS[a], "after": LABELS[b], "count": counts[a, b]}
                          for a in ACTIONS for b in ACTIONS])
    matrix = plot(frame, config=config, canvas={"width": 118, "height": 122}, legend=False,
        plots=[{"kind": "confusion", "x": "after", "y": "before", "metric": "count", "title": "",
                "chart_opts": {"color_scheme": ["#FAFAFA", "#111111"], "color_domain": [0, max(1, max(counts.values(), default=0))],
                               "fmt": ".0f", "xlabel": "候选策略", "ylabel": "当前策略"}}])
    matrix.render(str(output_dir / "matrix.svg"))
    matrix.render(str(output_dir / "matrix.png"), dpi=160)
    check = matrix.check()
    checks.append({"figure": "matrix", "ok": check.ok, "summary": check.summary()})
    if not check.ok:
        raise ValueError(f"FigCompose 矩阵布局检查未通过：{check.summary()}")
    figures["matrix"] = svg_contents(output_dir / "matrix.svg")
    return figures, checks


def webfont(text: str) -> str:
    options = subset.Options()
    options.flavor = "woff2"
    options.desubroutinize = True
    # Retain the source copyright, OFL notice and license URL. FontTools' default
    # name-ID subset omits IDs 13/14, even though the generated file embeds a font.
    options.name_IDs = [0, 1, 2, 3, 4, 5, 6, 7, 13, 14, 16, 17, 18, 21, 22]
    options.name_languages = ["*"]
    font = subset.load_font(str(FONT), options)
    worker = subset.Subsetter(options=options)
    worker.populate(text=text)
    worker.subset(font)
    # The OFL source declares "Source" as a Reserved Font Name. This generated
    # subset is a modified font, so give its primary/internal names a new family.
    for record in font["name"].names:
        if record.nameID in (1, 4, 16, 18, 21):
            record.string = "Notification Report Serif".encode(record.getEncoding())
        elif record.nameID == 6:
            record.string = "NotificationReportSerif-Regular".encode(record.getEncoding())
        elif record.nameID == 3:
            record.string = "NotificationReportSerif-Regular;report-subset-v1".encode(record.getEncoding())
    if "CFF " in font:
        cff = font["CFF "].cff
        cff.fontNames = ["NotificationReportSerif-Regular"]
        for top in cff.topDictIndex:
            top.FamilyName = "Notification Report Serif"
            top.FullName = "Notification Report Serif"
    font.flavor = "woff2"
    output = BytesIO()
    font.save(output)
    font.close()
    return base64.b64encode(output.getvalue()).decode("ascii")


def font_license_html() -> str:
    with TTFont(str(FONT), lazy=True) as original:
        copyright_notice = original["name"].getDebugName(0) or ""
    license_text = FONT_LICENSE.read_text(encoding="utf-8")
    return ('<details class="font-license"><summary>内嵌字体来源与 OFL 许可</summary>'
            '<p>网页内嵌衍生子集字体 Notification Report Serif，源自思源宋体 '
            'Source Han Serif SC Regular。以下保留原版字体版权元数据和仓库随附的完整 OFL 许可。</p>'
            f'<pre>{escape(copyright_notice)}\n\n{escape(license_text)}</pre></details>')


def rule_details(title: str, rules: dict) -> str:
    enabled = rules.get("globalEnabled", True)
    pieces = []
    for rule in rules.get("rules", []):
        match = rule.get("match") or {}
        conditions = []
        if match.get("packages"):
            conditions.append("应用：" + "、".join(match["packages"]))
        if match.get("keywordsAny"):
            conditions.append("关键词：" + "、".join(match["keywordsAny"]))
        for key, label in (("titleRegex", "标题正则"), ("textRegex", "正文正则")):
            if match.get(key):
                conditions.append(f"{label}：{match[key]}")
        if match.get("channelIds"):
            conditions.append("渠道：" + "、".join(match["channelIds"]))
        for key, label in (("isOngoing", "常驻通知"), ("isClearable", "可清除")):
            if match.get(key) is not None:
                conditions.append(f"{label}：{'是' if match[key] else '否'}")
        if match.get("quietHours"):
            quiet = match["quietHours"]
            conditions.append(f"时段：{quiet.get('from', '?')}–{quiet.get('to', '?')} / 星期 {quiet.get('days', [])}")
        pieces.append(f'<li><strong>{escape(rule.get("name") or rule.get("id") or "未命名规则")}</strong>'
                      f'<span>{escape(LABELS.get(rule.get("action"), str(rule.get("action"))))}'
                      f'{" · 已停用" if not rule.get("enabled", True) else ""}</span>'
                      f'<small>{"任一条件组命中" if match.get("mode") == "any" else "全部条件组命中"} · '
                      f'{escape("；".join(conditions) or "无匹配条件")}</small></li>')
    default = escape(LABELS.get(rules.get("defaultAction", "allow"), str(rules.get("defaultAction"))))
    return f'<details class="rules"><summary>{escape(title)}<span>{len(pieces)} 条规则 · 全局{"开启" if enabled else "关闭"}</span></summary><p>按下列顺序匹配；默认动作：{default}。</p><ol>{"".join(pieces) or "<li>暂无规则</li>"}</ol></details>'


CSS = r"""
@font-face{font-family:ReportSerifSubset;src:url(data:font/woff2;base64,__FONT__) format('woff2');font-display:swap}
:root{color-scheme:light;--ink:#141414;--muted:#6a6a6a;--line:#dedede;--paper:#fff;--wash:#f6f6f4}
*{box-sizing:border-box}body{margin:0;color:var(--ink);background:var(--paper);font-family:ReportSerifSubset,'Source Han Serif SC','Noto Serif CJK SC',SimSun,serif;font-size:16px;line-height:1.7}
button,input,select{font:inherit}button,select,input{border:1px solid #bcbcbc;border-radius:7px;background:#fff;color:var(--ink)}button{padding:9px 15px;cursor:pointer}button:hover{background:#efefed}button:disabled{opacity:.4;cursor:default}button:focus-visible,input:focus-visible,select:focus-visible{outline:2px solid #111;outline-offset:3px}button.primary{background:#141414;color:#fff;border-color:#141414}
main{max-width:1280px;margin:auto;padding:54px 56px 38px}.topline{display:flex;justify-content:space-between;align-items:center;border-bottom:2px solid var(--ink);padding-bottom:15px;gap:20px}.brand{font-size:14px;letter-spacing:.12em}.badge{font-size:12px;border:1px solid #141414;border-radius:3px;padding:4px 9px;white-space:nowrap}.hero{display:grid;grid-template-columns:1.2fr .8fr;gap:56px;padding:38px 0 24px}.eyebrow{font-size:12px;letter-spacing:.13em;color:var(--muted);margin:0 0 10px}.hero h1{font-size:43px;line-height:1.3;letter-spacing:-.035em;margin:0 0 16px;font-weight:500}.lead{margin:0;color:#555;font-size:17px;max-width:650px}.metadata{border-left:1px solid var(--line);padding-left:27px;display:grid;grid-template-columns:100px 1fr;gap:8px 14px;align-content:start;font-size:13px}.metadata dt{color:#777}.metadata dd{margin:0;overflow-wrap:anywhere}.notice{padding:14px 18px;background:var(--wash);border-left:3px solid #111;margin:0 0 25px;font-size:13px;line-height:1.9}.metrics{display:grid;grid-template-columns:repeat(4,1fr);border-top:1px solid var(--line);border-bottom:1px solid var(--line);margin:20px 0 14px}.metric{padding:24px 20px 23px;border-right:1px solid var(--line)}.metric:first-child{padding-left:0}.metric:last-child{border:0}.metric .label{font-size:13px;color:#555}.metric .value{display:block;font-size:43px;line-height:1.4;letter-spacing:-.03em}.metric .unit{font-size:13px;margin-left:7px;color:#777}.metric small{font-size:12px;color:#777}.secondary{display:flex;gap:22px;flex-wrap:wrap;font-size:12px;color:#666;margin:0 0 40px}.secondary b{color:#111;font-weight:500}.section-title{display:flex;justify-content:space-between;align-items:baseline;gap:20px;margin:0 0 9px}.section-title h2{font-size:23px;font-weight:500;line-height:1.5;margin:0}.section-title .number{font-size:12px;color:#777;margin-right:12px}.section-title p{font-size:12px;color:#777;margin:0}.chart{margin:0;border:1px solid var(--line);border-radius:10px;padding:12px 18px 10px;overflow:hidden;background:#fff}.chart svg{display:block;width:100%;height:auto}.caption{font-size:12px;color:#777;margin:8px 0 0;line-height:1.8}.block{margin-bottom:35px}.pair{display:grid;grid-template-columns:1.23fr 1fr;gap:26px;margin-bottom:35px}.pair .chart{min-height:300px;display:flex;align-items:center}.pair .chart svg{width:100%}.rule-grid{display:grid;grid-template-columns:1fr 1fr;gap:20px;margin-bottom:34px}.rules{border-top:1px solid #aaa;border-bottom:1px solid var(--line);font-size:13px}.rules summary{cursor:pointer;padding:13px 0}.rules summary span{float:right;color:#777;font-size:12px}.rules ol{padding:0 0 0 23px;margin:6px 0 17px}.rules li{padding:8px 10px}.rules li span{color:#777;margin-left:12px}.rules small{display:block;line-height:1.8;color:#666;overflow-wrap:anywhere}.table-title{margin-bottom:17px}.filters{display:grid;grid-template-columns:1.4fr 1fr 1fr;gap:10px;margin:12px 0}.filters input,.filters select{padding:10px 12px;min-width:0;width:100%;background:#fff}.table-help{font-size:12px;color:#777;margin-bottom:13px}.table-wrap{border:1px solid var(--line);border-radius:8px;overflow:auto}table{border-collapse:collapse;width:100%;font-size:12px;line-height:1.7;min-width:820px}th{text-align:left;background:#f6f6f4;padding:12px 14px;border-bottom:1px solid #ccc;font-weight:500;white-space:nowrap}td{padding:15px 14px;border-bottom:1px solid #e8e8e8;vertical-align:top;overflow-wrap:anywhere}tbody tr:last-child td{border-bottom:0}tbody tr:hover{background:#fafafa}.td-time{white-space:nowrap;color:#777}.td-notice{max-width:280px;min-width:190px}.td-notice strong{display:block;font-weight:500;margin-bottom:3px}.td-notice small{display:block;color:#777}.pill{display:inline-block;border:1px solid #b5b5b5;padding:2px 7px;border-radius:4px;font-size:11px;white-space:nowrap}.pill.drop{background:#111;color:#fff;border-color:#111}.pill.trace{background:#e8e8e8}.rule-name{display:block;color:#777;font-size:11px;margin-top:5px;max-width:190px}.hidden-note{font-size:11px;color:#777}.pagination{display:flex;align-items:center;justify-content:space-between;margin:14px 0 35px;gap:15px;font-size:12px;color:#777}.pagination .buttons{display:flex;gap:8px}.empty td{text-align:center;padding:30px;color:#777}.method{border-top:1px solid #aaa;padding-top:23px;font-size:12px;color:#6a6a6a;line-height:1.9}.method h2{font-weight:500;color:#111;font-size:17px;margin:0 0 10px}.method p{margin:7px 0}.footer{display:flex;justify-content:space-between;align-items:center;gap:20px;margin:28px 0 0;padding-top:19px;border-top:1px solid #ddd;font-size:11px;color:#777}.footer a{color:#333}.actions{display:flex;gap:8px}.scope-note{font-size:13px;padding:10px 0 5px}.scope-note strong{font-weight:500}.visually-hidden{position:absolute;width:1px;height:1px;overflow:hidden;clip-path:inset(50%)}
.font-license{font-size:12px;color:#666;border-top:1px solid #ddd;margin-top:22px;padding-top:15px}.font-license summary{cursor:pointer}.font-license pre{white-space:pre-wrap;overflow-wrap:anywhere;font:11px/1.8 monospace;max-height:400px;overflow:auto;background:#f7f7f5;padding:14px}.font-license p{font-size:12px}
@media(max-width:850px){main{padding:25px 20px}.hero{grid-template-columns:1fr;gap:24px;padding:25px 0}.hero h1{font-size:34px}.metadata{padding:0;border:0;grid-template-columns:90px 1fr}.pair,.rule-grid{grid-template-columns:1fr}.metrics{grid-template-columns:repeat(2,1fr)}.metric:nth-child(2){border-right:0}.metric:nth-child(3){padding-left:0;border-top:1px solid var(--line)}.metric:nth-child(4){border-top:1px solid var(--line)}.filters{grid-template-columns:1fr}.section-title{display:block}.section-title p{margin-top:5px}.chart{padding:6px}.pair .chart{min-height:0}.footer{align-items:flex-start;flex-direction:column}.topline{gap:8px}.brand{font-size:11px}.badge{font-size:10px}.metrics .value{font-size:35px}}
@media print{main{max-width:none;padding:0}.actions,.filters,.pagination .buttons{display:none}.block,.pair,.metrics{break-inside:avoid}.hero h1{font-size:30px}.notice{background:#f5f5f5!important}body{font-size:12px}.table-wrap{overflow:visible}table{min-width:0;font-size:9px}.chart{border:0}button{display:none}.footer{margin-top:15px}}
"""


JS = r"""
const report=JSON.parse(document.getElementById('report-data').textContent);
const labels={allow:'放行',log_only:'仅记录',intercept:'预计拦截'};
const reasons={default:'默认动作',disabled:'全局关闭',self:'本应用',rule:'规则匹配'};
const cancel={success:'历史：已确认移除',rejected:'历史：系统拒绝',failed:'历史：取消失败',pending:'历史：尚未确认',not_attempted:'历史：未尝试取消'};
const rows=report.rows; let page=0; const size=30;
const query=document.getElementById('search'), app=document.getElementById('app'), kind=document.getElementById('change');
const tb=document.getElementById('rows');
const ruleChanged=r=>(r.before.ruleId??null)!==(r.after.ruleId??null)||(r.before.reason??null)!==(r.after.reason??null);
const changed=r=>r.before.action!==r.after.action||ruleChanged(r);
const names=new Map();rows.forEach(r=>names.set(r.record.packageName||'未知应用',r.record.appLabel||r.record.packageName||'未知应用'));
for(const [value,label] of [...names.entries()].sort((a,b)=>a[1].localeCompare(b[1],'zh'))){const o=document.createElement('option');o.value=value;o.textContent=label;app.append(o);}
function text(tag,value,cls){const n=document.createElement(tag);n.textContent=value??'';if(cls)n.className=cls;return n;}
function decisionCell(d){const td=document.createElement('td');td.append(text('span',labels[d.action],`pill ${d.action==='intercept'?'drop':d.action==='log_only'?'trace':''}`));td.append(text('small',d.ruleName||reasons[d.reason]||d.reason||'未匹配规则','rule-name'));return td;}
function matches(r){if(app.value&&r.record.packageName!==app.value)return false;const b=r.before.action,a=r.after.action;if(kind.value==='changed'&&!changed(r))return false;if(kind.value==='more'&&!(b!=='intercept'&&a==='intercept'))return false;if(kind.value==='less'&&!(b==='intercept'&&a!=='intercept'))return false;if(kind.value==='source'&&!(a===b&&ruleChanged(r)))return false;const needle=query.value.trim().toLowerCase();return !needle||[r.record.appLabel,r.record.packageName,r.record.title,r.record.text,r.record.bigText,r.before.ruleName,r.after.ruleName].join('\n').toLowerCase().includes(needle);}
function render(){const found=rows.filter(matches).sort((a,b)=>b.timestamp-a.timestamp);page=Math.min(page,Math.max(0,Math.ceil(found.length/size)-1));tb.replaceChildren();const current=found.slice(page*size,(page+1)*size);for(const r of current){const tr=document.createElement('tr');const t=new Intl.DateTimeFormat('zh-CN',{timeZone:report.zoneId,month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hour12:false}).format(r.timestamp);tr.append(text('td',t,'td-time'));const notice=text('td','','td-notice');notice.append(text('strong',r.record.title||'无标题'));notice.append(text('small',r.record.appLabel||r.record.packageName));const body=r.record.text||r.record.bigText||'';if(body)notice.append(text('small',body.length>160?body.slice(0,160)+'…':body));tr.append(notice,decisionCell(r.before),decisionCell(r.after));const nature=r.before.action!==r.after.action?'动作改变':ruleChanged(r)?'仅命中来源改变':'保持一致';tr.append(text('td',nature));tr.append(text('td',cancel[r.cancelStatus]||'历史结果未提供'));tb.append(tr);}if(!current.length){const tr=document.createElement('tr'),td=text('td','当前筛选下没有处理事件');td.colSpan=6;tr.className='empty';tr.append(td);tb.append(tr);}document.getElementById('row-count').textContent=`筛选 ${found.length} / ${rows.length} 个处理事件 · 第 ${found.length?page+1:0} / ${Math.ceil(found.length/size)} 页`;document.getElementById('previous').disabled=page===0;document.getElementById('next').disabled=(page+1)*size>=found.length;}
for(const input of [query,app,kind])input.addEventListener(input===query?'input':'change',()=>{page=0;render()});document.getElementById('previous').onclick=()=>{page--;render()};document.getElementById('next').onclick=()=>{page++;render()};document.getElementById('print').onclick=()=>window.print();document.getElementById('download').onclick=()=>{const blob=new Blob([JSON.stringify(report,null,2)],{type:'application/json'}),url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download='notification-batch-comparison.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000)};render();
"""


def build_html(payload: dict, figures: dict, source: str, label: str | None) -> str:
    rows, summary, zone = payload["rows"], payload["summary"], payload["zoneId"]
    target = payload.get("target") or {}
    scope = payload.get("scope") or {}
    source_label = {"demo": "示例数据 · 非真实效果", "device": "模拟器受控通知回放", "export": "本机导出 · 历史回放"}[source]
    source_note = {
        "demo": "这份示例使用构造的处理事件，只用于展示对比方式与图表，不代表实际产品效果。",
        "device": "本报告使用模拟器受控演示期间记录的通知样本，可能包含系统事件，不代表用户日常生活或整日效果。两套策略均按历史事件时刻回放，候选策略尚未改变通知处理。",
        "export": "图表来自导出的历史处理事件。两套策略均按事件发生时刻回放，候选策略尚未改变通知处理。",
    }[source]
    window = "无样本" if not rows else f'{fmt_time(min(r["timestamp"] for r in rows), zone)} — {fmt_time(max(r["timestamp"] for r in rows), zone)}'
    only_rule = summary["totalChanged"] - summary["actionChanged"]
    n = len(rows)
    share = lambda value: f"{value / n:.1%}" if n else "—"
    title = label or target.get("name") or "候选预设"
    card = lambda heading, value, note: f'<div class="metric"><div class="label">{heading}</div><span class="value">{value}<span class="unit">条</span></span><small>{note}</small></div>'
    metadata = [
        ("候选预设", title), ("样本时间", window), ("回放时区", zone),
        ("样本范围", f'{ {"today":"今天", "week":"近七天", "all":"本地历史"}.get(scope.get("period"), "本地历史")} · 最新 {scope.get("limit", n)} 条上限'),
        ("报告生成", fmt_time(payload.get("generatedAt"), zone)),
    ]
    body = f'''<main><div class="topline"><div class="brand">NOTIFICATION INTERCEPTOR / 策略观察室</div><span class="badge">{escape(source_label)}</span></div>
<header class="hero"><div><p class="eyebrow">BATCH EFFECT COMPARISON</p><h1>一次修改，<br>哪些通知会改变？</h1><p class="lead">{escape(title)}：把当前策略和候选策略放在同一批历史样本上，查看动作迁移、应用差异与命中来源。</p></div><dl class="metadata">{''.join(f'<dt>{escape(k)}</dt><dd>{escape(str(v))}</dd>' for k,v in metadata)}</dl></header>
<p class="notice">{escape(source_note)} <strong>“预计拦截”是规则判断，不等于通知已成功移除。</strong>同一通知的更新可能产生多条处理事件。</p>
<div class="metrics">{card('比较样本',n,'已排除系统分组汇总')}{card('处理动作改变',summary['actionChanged'],f'占样本 {share(summary["actionChanged"])}')}{card('新增预计拦截',summary['moreIntercepted'],'原先放行 / 仅记录 → 预计拦截')}{card('减少预计拦截',summary['lessIntercepted'],'原先预计拦截 → 放行 / 仅记录')}</div>
<div class="secondary"><span>当前预计拦截 <b>{summary['before']['intercept']}</b> → 候选预计拦截 <b>{summary['after']['intercept']}</b></span><span>仅命中来源改变 <b>{only_rule}</b></span><span>总变化 <b>{summary['totalChanged']}</b></span><span>内容被系统隐藏 <b>{payload.get('hiddenContentCount',0)}</b></span></div>
<section class="block"><div class="section-title"><h2><span class="number">01</span>处理路径如何迁移</h2><p>带宽对应处理事件数量</p></div><figure class="chart" aria-label="当前策略与候选策略动作流向图">{figures['flow']}</figure><p class="caption">放行、仅记录、预计拦截各自流向哪里；深灰强调动作变化。更多预计拦截不代表策略更好，需检查下方具体样本。</p></section>
<div class="pair"><section><div class="section-title"><h2><span class="number">02</span>哪些应用受到影响</h2></div><figure class="chart" aria-label="应用级预计拦截率配对点图">{figures['apps']}</figure><p class="caption">按动作变化数量排序，最多展示 8 个应用；比例的分母是该应用在本批样本中的处理事件数。</p></section><section><div class="section-title"><h2><span class="number">03</span>动作迁移矩阵</h2></div><figure class="chart" aria-label="策略前后动作数量矩阵">{figures['matrix']}</figure><p class="caption">对角线为动作不变的样本，非对角线为动作改变。它不是准确率或误报率评估。</p></section></div>
<section class="block"><div class="section-title"><h2><span class="number">04</span>变化集中在哪些时段</h2><p>按历史时间回放，不按生成报告的时间判断场景</p></div><figure class="chart" aria-label="按小时聚合的策略变化热图">{figures['hours']}</figure><p class="caption">单元格是处理事件数；颜色越深表示数量越多。不同日期的同一小时合计，空白不代表完整一天没有通知。</p></section>
<div class="rule-grid">{rule_details('当前规则快照',payload.get('currentRules') or {})}{rule_details('候选规则快照',payload.get('candidateRules') or {})}</div>
<section class="table-title"><div class="section-title"><h2><span class="number">05</span>逐条核对变化</h2><p>默认只看有变化的样本</p></div><div class="filters"><label><span class="visually-hidden">搜索处理事件</span><input id="search" placeholder="搜索应用、标题或规则" type="search"></label><label><span class="visually-hidden">应用筛选</span><select id="app"><option value="">全部应用</option></select></label><label><span class="visually-hidden">变化类型</span><select id="change"><option value="changed">全部变化</option><option value="more">新增预计拦截</option><option value="less">减少预计拦截</option><option value="source">仅命中来源改变</option><option value="all">全部样本</option></select></label></div><p class="table-help">筛选只影响明细；上方图表始终使用完整样本。历史取消结果仅作参考，不是候选策略的执行结果。</p><div class="table-wrap"><table><thead><tr><th>历史时间</th><th>样本 / 应用</th><th>当前策略回放</th><th>候选策略回放</th><th>变化</th><th>历史执行参考</th></tr></thead><tbody id="rows"></tbody></table></div><div class="pagination"><span id="row-count"></span><div class="buttons"><button id="previous">上一页</button><button id="next">下一页</button></div></div></section>
<section class="method"><h2>如何理解这份报告</h2><p>样本来自本机仍保存的历史窗口，最多 1000 条；本次按所选范围采样 {n} 个处理事件。源窗口有 {scope.get('sourceCount',n)} 条，排除系统汇总 {payload.get('skippedSummaries',0)} 条、常驻通知 {payload.get('skippedOngoing',0)} 条。它不一定覆盖完整的一天或一周。</p><p>处理动作、命中规则或命中来源不同均视为变化。动作不变但命中来源改变的样本计入“仅命中来源改变”。回放遵循规则顺序、全局开关、默认动作和导出时区。</p><p>内容被系统隐藏时，关键词只能匹配实际可见文本。历史上成功移除的处理记录为 {summary['historicalConfirmedRemoved']} 条；该数量不能作为候选策略实际拦截数，也不能解释成独立通知数。</p><p>图表由 space1 环境中的 FigCompose {escape(version('figcompose'))} 生成，使用原生自定义面板与动作计数矩阵。SVG 图表和思源宋体子集均内嵌，离线可查看。</p></section>
{font_license_html()}
<footer class="footer"><span>本地数据 · 独立呈现 · 不联网加载字体或图表</span><div class="actions"><button id="download">下载本次 JSON</button><button id="print" class="primary">打印 / 保存 PDF</button></div></footer></main>'''
    safe_json = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).replace("<", "\\u003c").replace("&", "\\u0026")
    # Current report glyphs are bundled. Regenerating from another JSON rebuilds
    # the subset, so no system font or network request is required for this file.
    font_text = body + safe_json + JS + "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz○●—…→：；（）"
    embedded_font = webfont(font_text)
    styles = CSS.replace("__FONT__", embedded_font)
    return '<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' + \
        '<title>通知过滤 · 批量效果对比</title><style>' + styles + '</style></head><body>' + body + \
        '<script type="application/json" id="report-data">' + safe_json + '</script><script>' + JS + '</script></body></html>'


def demo_payload() -> dict:
    """Construct clearly labelled demo events; never claim measured outcomes."""
    def rule(id, name, action, packages=(), words=(), quiet=None):
        return dict(id=id, name=name, enabled=True, action=action, match=dict(mode="all", packages=list(packages),
            keywordsAny=list(words), quietHours=quiet, channelIds=[], titleRegex=None, textRegex=None, isOngoing=None, isClearable=None))
    urgent = rule("urgent", "重要事务优先保留", "allow", words=["验证码", "会议", "到账", "取件"])
    shop = rule("shop-promo", "商城优惠券过滤", "intercept", ["com.demo.shop"], ["优惠券", "秒杀"])
    news = rule("news-trace", "资讯仅记录", "log_only", ["com.demo.news"])
    work = rule("preset:scene:demo_work:intercept", "工作场景 · 减少打扰", "intercept",
                ["com.demo.social", "com.demo.game", "com.demo.news"], ["直播", "热搜", "开服", "福利"],
                {"from": "09:00", "to": "18:00", "days": [1, 2, 3, 4, 5]})
    conversation = rule("work-chat", "工作场景 · 会话保留", "allow", ["com.demo.social"], ["好友", "群聊"])
    current = dict(schemaVersion=1, globalEnabled=True, defaultAction="allow", rules=[urgent, shop, news])
    candidate = dict(current, rules=[urgent, conversation, work, shop, news])
    apps = [("com.demo.shop", "演示商城", ["领取优惠券", "秒杀活动开始", "账单更新", "限时大促"]),
            ("com.demo.social", "演示聊天", ["好友直播开播", "群聊新消息", "王敏：会议安排", "热搜话题更新"]),
            ("com.demo.game", "演示游戏", ["新赛季开服", "福利礼包更新", "账号安全提醒"]),
            ("com.demo.news", "演示资讯", ["今日热搜", "国际资讯速览", "订阅更新", "直播回顾"]),
            ("com.demo.logistics", "演示物流", ["取件提醒", "配送进度", "促销活动"])]

    def evaluate(rules, record, instant):
        for item in rules["rules"]:
            match = item["match"]
            if match["packages"] and record["packageName"] not in match["packages"]:
                continue
            if match["keywordsAny"] and not any(w.lower() in record["title"].lower() for w in match["keywordsAny"]):
                continue
            if match["quietHours"] and not (instant.weekday() < 5 and 9 <= instant.hour < 18):
                continue
            return dict(action=item["action"], ruleId=item["id"], ruleName=item["name"], reason="rule")
        return dict(action="allow", ruleId=None, ruleName=None, reason="default")

    start = datetime(2026, 11, 2, 8, tzinfo=ZoneInfo("Asia/Shanghai"))
    rows = []
    for index in range(144):
        package, name, titles = apps[index % len(apps)]
        instant = start + timedelta(minutes=15 * index)
        timestamp = int(instant.timestamp() * 1000)
        title = titles[(index // len(apps)) % len(titles)]
        record = dict(key=f"demo:{index}", id=index, packageName=package, appLabel=name, postTime=timestamp,
                      title=title, text="示例通知内容，仅用于图表演示", isGroupSummary=False)
        before, after = evaluate(current, record, instant), evaluate(candidate, record, instant)
        rows.append(dict(entryId=f"demo-{index}", timestamp=timestamp, record=record, before=before, after=after,
                         historicalAction=before["action"], cancelStatus="success" if before["action"] == "intercept" and index % 11 else "not_attempted"))
    return dict(schemaVersion=1, kind="notification_batch_comparison", generatedAt=int(datetime(2026, 11, 4, 10, tzinfo=ZoneInfo("Asia/Shanghai")).timestamp() * 1000),
                zoneId="Asia/Shanghai", target=dict(id="demo_work", name="工作专注（示例）", kind="scene"),
                scope=dict(period="all", limit=300, replayTime="historical", sourceCount=146), sampleCount=len(rows),
                skippedSummaries=2, hiddenContentCount=0, currentRules=current, candidateRules=candidate,
                summary=summarize(rows), rows=rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", nargs="?", type=Path, help="从应用导出的批量对比 JSON")
    parser.add_argument("--demo", action="store_true", help="生成明确标示的示例数据并渲染")
    parser.add_argument("--source", choices=("demo", "export", "device"), default=None)
    parser.add_argument("--label", help="报告中的候选预设显示名")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--artifacts", type=Path, default=ROOT / "build/figcompose-comparison")
    args = parser.parse_args()
    if args.demo or not args.input:
        payload = demo_payload()
        DEMO_PATH.parent.mkdir(parents=True, exist_ok=True)
        DEMO_PATH.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        source = "demo"
    else:
        payload = json.loads(args.input.read_text(encoding="utf-8-sig"))
        source = args.source or "export"
    payload = normalized(payload)
    args.artifacts.mkdir(parents=True, exist_ok=True)
    figures, checks = render_figures(payload, args.artifacts, configure_font())
    html = build_html(payload, figures, source, args.label)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(html, encoding="utf-8")
    manifest = dict(renderer="FigCompose", version=version("figcompose"), source=source,
                    input=str(args.input) if args.input else str(DEMO_PATH), output=str(args.output),
                    sampleCount=payload["sampleCount"], summary=payload["summary"], checks=checks,
                    htmlBytes=args.output.stat().st_size)
    (args.artifacts / "render-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(manifest, ensure_ascii=False))


if __name__ == "__main__":
    main()
