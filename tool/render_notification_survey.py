"""Read the survey DOCX and render a shareable FigCompose report.

Run with the existing environment (no installation needed):
  D:\\Anaconda\\envs\\space1\\python.exe tool/render_notification_survey.py

The source contains marginal counts, not respondent records. Each question is
therefore an independent 100% stacked bar, never an aligned participant track.
"""
from __future__ import annotations

import argparse
import base64
import csv
import hashlib
from html import escape
from io import StringIO
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET
import zipfile
from importlib.metadata import version

import matplotlib

matplotlib.use("Agg")
from matplotlib.patches import Rectangle
from data_visuals import FigureConfig
from data_visuals.core import Figure, PanelResult

from render_batch_comparison import (
    configure_font, font_license_html, svg_contents, webfont,
)


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = ROOT / "手机通知管理与专注状态调研_392334267 (1).docx"
DEFAULT_OUTPUT = ROOT / "docs/visualizations/notification-survey.html"
DEFAULT_ARTIFACTS = ROOT / "docs/visualizations/notification-survey"
DATA_PATH = ROOT / "docs/visualizations/data/notification-survey.json"
COLORS = ("#255D78", "#77ABB2", "#DCC18E", "#BFC8D1")
INK = "#172D39"
MUTED = "#62717A"
NS = {"w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main"}

# Short display labels; the report and extracted JSON retain every full option.
DISPLAY = {
    2: ("工作日平均每天的专注时长", ["少于1小时", "1–2小时", "2–4小时", "4小时以上"]),
    3: ("每天收到的消息通知量", ["少于20条", "20–50条", "50–100条", "100条以上"]),
    4: ("专注时如何处理手机通知", ["正常响铃和弹窗，响了就看", "震动或静音，保留弹窗",
                                     "免打扰，但偶尔主动看屏幕", "关闭通知，任务结束前不查看"]),
    5: ("哪种不重要通知更干扰专注", ["弹窗更干扰", "提示音更干扰", "两者干扰同样大", "两者干扰都不大"]),
    6: ("是否愿意提前设置筛选规则", ["愿花几分钟设置规则", "不愿设置，宁愿全部静音"]),
    7: ("是否会根据统计关闭无效打扰", ["统计有用，会使用", "偶尔查看，但懒得关闭", "不会查看，帮助不大"]),
    8: ("筛选通知时更看重什么", ["优先不漏重要信息", "接受重要消息偶尔延迟，减少干扰"]),
    9: ("读取通知内容的授权条件", ["好用即可，不介意授权", "仅接受本地处理、不上传云端", "拒绝读取通知内容"]),
}


def paragraph_text(element: ET.Element) -> str:
    return "".join(node.text or "" for node in element.findall(".//w:t", NS)).strip()


def read_survey(path: Path) -> dict:
    with zipfile.ZipFile(path) as archive:
        body = ET.fromstring(archive.read("word/document.xml")).find("w:body", NS)
    if body is None:
        raise ValueError("Word 文档缺少正文")
    questions = []
    current = None
    for element in body:
        if element.tag == f"{{{NS['w']}}}p":
            match = re.fullmatch(r"第(\d+)题\s+(.+?)\s+\[单选题\]", paragraph_text(element))
            if match:
                if current is not None:
                    raise ValueError("题目缺少紧随其后的统计表")
                current = {"number": int(match[1]), "question": match[2], "type": "single_choice"}
        elif element.tag == f"{{{NS['w']}}}tbl" and current is not None:
            rows = [[paragraph_text(cell) for cell in row.findall("w:tc", NS)]
                    for row in element.findall("w:tr", NS)]
            if not rows or rows[0] != ["选项", "小计", "比例"]:
                raise ValueError("问卷表头不符合“选项 / 小计 / 比例”")
            options = []
            effective = None
            for row in rows[1:]:
                if len(row) != 3:
                    raise ValueError("问卷统计行必须有3列")
                label, count, reported = row
                if label == "本题有效填写人次":
                    if effective is not None:
                        raise ValueError("同题出现多个有效人数")
                    effective = int(count)
                else:
                    options.append({"label": label, "count": int(count), "reportedPercent": reported})
            if not effective or not options or any(o["count"] < 0 for o in options):
                raise ValueError("题目人数或选项无效")
            if sum(o["count"] for o in options) != effective:
                raise ValueError(f"Q{current['number']} 选项合计与有效人数不同")
            for option in options:
                if not option["reportedPercent"].endswith("%"):
                    raise ValueError("源比例缺少百分号")
                percent = option["count"] * 100 / effective
                if abs(float(option["reportedPercent"][:-1]) - percent) > .00501:
                    raise ValueError(f"Q{current['number']} 源比例与人数不符")
                option["percent"] = percent
            current.update(effectiveN=effective, options=options)
            questions.append(current)
            current = None
    if current is not None or [q["number"] for q in questions] != list(range(1, 10)):
        raise ValueError("预期文档包含完整的 Q1–Q9 九道单选题")
    # Display wording is specific to this questionnaire; refuse silently changed options.
    expected_counts = ([55, 0, 0, 0, 0], [7, 24, 19, 5], [7, 18, 7, 23],
                       [4, 22, 27, 2], [11, 21, 16, 5], [38, 12], [25, 10, 15], [26, 24], [21, 27, 2])
    for question, expected in zip(questions, expected_counts):
        if [o["count"] for o in question["options"]] != list(expected):
            raise ValueError("源问卷数据已变更，请先复核展示标签和结论")
    return {
        "schemaVersion": 1,
        "kind": "notification_focus_survey_aggregates",
        "title": "手机通知管理与专注状态调研",
        "source": {"filename": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()},
        "questions": questions,
        "notes": ["按本题有效人数计算百分比；源文件未说明各题有效人数不同的原因。",
                  "仅含各题汇总，不能恢复逐人回答、交叉分组或题间相关性。",
                  "Q1 的55份有效回答均为本科生，不代表全部大学生或其他职业群体。"],
    }


def pct(value: float) -> str:
    return f"{value:.2f}".rstrip("0").rstrip(".") + "%"


def overview_panel(survey: dict):
    def draw(ax, context):
        ax.set_xlim(0, 100)
        ax.set_ylim(0, 142)
        ax.set_axis_off()
        artists = []

        def text(x, y, value, size=10, color=INK, **kwargs):
            artist = ax.text(x, y, value, va="center", **context.text_kwargs(fontsize=size, color=color), **kwargs)
            artists.append(artist)

        text(3, 137, survey["title"], size=22)
        text(3, 131.5, "样本说明：Q1有效回答55人，均为本科生；各题有效回答数见右侧。", color=MUTED, size=10)
        ax.plot([3, 97], [128, 128], color="#D9E0E3", linewidth=.8)
        text(3, 125, "各题独立归一化至100% · 选项依原问卷顺序排列", size=9, color=MUTED)

        for index, question in enumerate(survey["questions"][1:]):
            number = question["number"]
            title, short_labels = DISPLAY[number]
            y = 119 - index * 13
            text(3, y, f"Q{number}   {title}", size=12)
            text(97, y, f"n = {question['effectiveN']}", ha="right", size=10, color=MUTED)
            left = 3.0
            for opt_index, option in enumerate(question["options"]):
                width = option["percent"] * .94
                patch = Rectangle((left, y - 4.3), width, 2.65, facecolor=COLORS[opt_index],
                                  edgecolor="white", linewidth=.6)
                ax.add_patch(patch)
                artists.append(patch)
                if option["percent"] >= 7:
                    text(left + width / 2, y - 2.975, pct(option["percent"]), size=9,
                         color="white" if opt_index == 0 else INK, ha="center")
                left += width
                # Two columns keep counts and complete short labels readable at print size.
                col, row = opt_index % 2, opt_index // 2
                x = 3 + col * 48
                legend_y = y - 6.6 - row * 2.75
                square = Rectangle((x, legend_y - .47), .8, .94, facecolor=COLORS[opt_index], edgecolor="none")
                ax.add_patch(square)
                artists.append(square)
                text(x + 1.5, legend_y, short_labels[opt_index], size=8.7)
                text(x + 45.5, legend_y, f"{option['count']}人 / {pct(option['percent'])}",
                     size=8.7, ha="right", color=MUTED)
            if abs(left - 97) > 1e-8:
                raise ValueError(f"Q{number} 的堆叠长度未达到100%")
            if index < 7:
                ax.plot([3, 97], [y - 11.25, y - 11.25], color="#E9EDEF", linewidth=.5)

        ax.plot([3, 97], [14, 14], color="#D9E0E3", linewidth=.8)
        text(3, 10.4, "读图：颜色仅区分本题选项；不同题的同色不代表同一人群。小比例请看行下标注。", size=8.5, color=MUTED)
        text(3, 7, "比例按人数重算，显示值四舍五入后合计可能略偏离100%。完整题目与选项见配套报告。", size=8.5, color=MUTED)
        text(3, 3.6, "来源：手机通知管理与专注状态调研（Word汇总）；无逐人数据，不作题间关联或因果推断。", size=8.5, color=MUTED)
        return PanelResult(artists=artists)

    return draw


def render_overview(survey: dict, target: Path) -> dict:
    config = FigureConfig(theme="general", font_family=configure_font(), background="#FFFFFF")
    figure = Figure(rows=1, cols=1, config=config, canvas={"width": 270, "height": 378}, legend=False)
    figure[0, 0].custom(overview_panel(survey), min_size=(700, 980), preferred_aspect=100 / 142)
    for suffix in ("svg", "png", "pdf"):
        figure.render(str(target / f"survey-overview.{suffix}"), dpi=200)
    svg_path = target / "survey-overview.svg"
    svg_path.write_text(
        "\n".join(line.rstrip() for line in svg_path.read_text(encoding="utf-8").splitlines()) + "\n",
        encoding="utf-8",
    )
    check = figure.check()
    if not check.ok:
        raise ValueError(f"FigCompose 布局检查未通过：{check.summary()}")
    return {"ok": check.ok, "summary": check.summary()}


def data_url(content: bytes, mime: str) -> str:
    return f"data:{mime};base64," + base64.b64encode(content).decode("ascii")


def csv_data(survey: dict) -> str:
    output = StringIO(newline="")
    writer = csv.writer(output)
    writer.writerow(["题号", "题目", "本题有效人数", "选项", "人数", "比例", "源文档比例"])
    for q in survey["questions"]:
        for o in q["options"]:
            writer.writerow([q["number"], q["question"], q["effectiveN"], o["label"],
                             o["count"], pct(o["percent"]), o["reportedPercent"]])
    return output.getvalue()


def findings(survey: dict) -> list[tuple[str, str, str]]:
    def option(question, index):
        q = survey["questions"][question - 1]
        o = q["options"][index]
        return pct(o["percent"]), f"Q{question} · {o['count']}/{q['effectiveN']}人"

    a, an = option(3, 3)
    b, bn = option(6, 0)
    c, cn = option(8, 0)
    c_other, _ = option(8, 1)
    d, dn = option(9, 1)
    return [(a, "每天收到100条以上通知", an), (b, "愿提前花几分钟设置规则", bn),
            (c, "优先不漏重要信息", cn + f"；另{c_other}接受重要消息偶尔延迟"),
            (d, "要求本地处理、不上传", dn)]


CSS = """
@font-face{font-family:SurveySerif;src:url(data:font/woff2;base64,__FONT__) format('woff2');font-display:swap}
:root{color-scheme:light;--ink:#172d39;--muted:#62717a;--line:#dce3e6}
*{box-sizing:border-box}body{margin:0;background:#f3f5f5;color:var(--ink);font:16px/1.8 SurveySerif,SimSun,serif}
main{max-width:1160px;margin:0 auto;padding:45px 38px}header{padding-bottom:24px;border-bottom:1px solid var(--line)}
.kicker{font-size:12px;letter-spacing:.14em;color:var(--muted);margin:0 0 10px}h1{font-size:36px;font-weight:500;line-height:1.4;margin:0 0 15px}
.intro{margin:0;max-width:900px;color:var(--muted)}.actions{display:flex;flex-wrap:wrap;gap:9px;margin-top:20px}
.actions a,button{font:inherit;font-size:13px;color:var(--ink);background:#fff;border:1px solid #c7d2d8;border-radius:5px;padding:7px 13px;text-decoration:none;cursor:pointer}
.actions a:hover,button:hover{background:#e9eff1}a:focus-visible,button:focus-visible,summary:focus-visible{outline:2px solid #255d78;outline-offset:3px}
.metrics{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin:26px 0}.metric{border-top:2px solid #255d78;background:#fff;padding:17px 15px}
.metric strong{display:block;font-size:34px;font-weight:500;line-height:1.3}.metric span{display:block;margin:9px 0 5px;font-size:13px}.metric small{color:var(--muted);font-size:11px}
.chart{margin:0;background:#fff;border:1px solid var(--line);border-radius:6px;padding:15px}.chart svg{display:block;width:100%;height:auto}
figcaption{color:var(--muted);font-size:12px;border-top:1px solid var(--line);margin:12px 8px 0;padding-top:10px}
h2{font-size:22px;font-weight:500;margin:30px 0 12px}details{border-top:1px solid var(--line);padding:12px 0;font-size:14px}summary{cursor:pointer;line-height:1.7}summary small{color:var(--muted);margin-left:10px}
.table-wrap{overflow:auto}table{border-collapse:collapse;width:100%;min-width:440px;background:#fff;margin:12px 0;font-size:13px}th,td{padding:10px 13px;text-align:left;border-bottom:1px solid #e8edef}th{font-weight:500;background:#edf1f2}th:nth-child(n+2),td:nth-child(n+2){text-align:right;white-space:nowrap}
.method{margin-top:25px;padding:20px 22px;background:#fff;border:1px solid var(--line);font-size:13px;color:var(--muted)}.method h2{font-size:18px;margin:0 0 10px;color:var(--ink)}.method p{margin:8px 0}.provenance{overflow-wrap:anywhere}code{font-size:11px}
.font-license{margin-top:15px;font-size:12px;color:var(--muted)}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:11px/1.7 monospace;max-height:320px;overflow:auto}footer{font-size:11px;color:var(--muted);margin-top:22px}
@media(max-width:760px){main{padding:24px 14px}h1{font-size:27px}.metrics{grid-template-columns:repeat(2,1fr);gap:10px}.metric strong{font-size:28px}.chart{padding:4px}figcaption{margin:6px;padding-top:8px}}
@media print{body{background:#fff}main{padding:0;max-width:none}.actions,.metrics,.details-section,.font-license,footer{display:none}header{border:0;padding:0}h1{font-size:23px}.intro{font-size:10px}.chart{padding:0;border:0;break-inside:avoid;margin-top:12px}.chart svg{max-height:235mm;width:100%}figcaption{font-size:9px}.method{font-size:10px;break-before:page}}
"""


def report_html(survey: dict, target: Path, json_bytes: bytes, csv_bytes: bytes) -> str:
    links = []
    for extension, mime, label in (("png", "image/png", "下载PNG图片"), ("svg", "image/svg+xml", "下载SVG矢量图"),
                                    ("pdf", "application/pdf", "下载PDF图表")):
        filename = f"survey-overview.{extension}"
        links.append(f'<a download="{filename}" href="{data_url((target / filename).read_bytes(), mime)}">{label}</a>')
    links.append(f'<a download="notification-survey.csv" href="{data_url(csv_bytes, "text/csv;charset=utf-8")}">下载CSV数据</a>')
    links.append(f'<a download="notification-survey.json" href="{data_url(json_bytes, "application/json")}">下载JSON数据</a>')
    metrics = "".join(f'<article class="metric"><strong>{value}</strong><span>{label}</span><small>{note}</small></article>'
                      for value, label, note in findings(survey))
    tables = []
    for q in survey["questions"]:
        rows = "".join(f'<tr><td>{escape(o["label"])}</td><td>{o["count"]}</td><td>{pct(o["percent"])}</td></tr>'
                       for o in q["options"])
        tables.append(f'<details><summary>Q{q["number"]}　{escape(q["question"])}'
                      f'<small>n={q["effectiveN"]}</small></summary><div class="table-wrap"><table>'
                      '<thead><tr><th scope="col">原始选项</th><th scope="col">人数</th><th scope="col">占本题比例</th></tr></thead>'
                      f'<tbody>{rows}</tbody></table></div></details>')
    document = f'''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{survey['title']} · 问卷结果</title><style>{CSS}</style></head>
<body><main><header><p class="kicker">NOTIFICATION &amp; FOCUS · 调研结果</p><h1>{survey['title']}</h1>
<p class="intro">Q1的55份有效回答均为本科生。以下按题展示回答分布，每题以本题有效人数为分母；不同题的回答不能视为同一人群的逐人对应记录。</p>
<nav class="actions" aria-label="导出报告">{''.join(links)}<button type="button" onclick="window.print()">打印报告</button></nav></header>
<section class="metrics" aria-label="主要发现">{metrics}</section>
<figure class="chart" aria-label="Q2至Q9的100%堆叠条形图">{svg_contents(target / 'survey-overview.svg')}
<figcaption>每行总长均为100%。颜色在每道题内区分选项，原始人数和比例见行下标注；较小的区段省略内部文字。</figcaption></figure>
<section class="details-section"><h2>完整题目与原始选项</h2><p class="intro">展开可查原文，包含Q1的零人数选项。图内长选项为忠实缩写。</p>{''.join(tables)}</section>
<section class="method"><h2>数据口径与解读</h2>
<p>Q1–Q4各55份有效回答，Q5为53份，Q6–Q9各50份。文档未说明人数差异的原因；各题的未计入回答不分摊进任何选项。</p>
<p>图形按“选项人数 ÷ 本题有效人数”绘制，比例显示至最多两位小数。Q2、Q3的显示比例合计100.01%，Q5为99.99%，属于四舍五入；几何长度使用未舍入值。</p>
<p>这份文档只有各题汇总频数，无法恢复逐人记录，也不能计算题间相关性或跨题人群交集。这里按题展示独立的100%堆叠条形图。</p>
<p>这些结果描述本份样本的自报情况，不能推广至全部大学生或其他职业群体，也不能作为本项目筛选通知实际效果的证据。Q5的“同样大”没有并入“提示音更干扰”；Q7的“偶尔查看”没有并入“认为统计有用且会使用”。</p>
<details class="provenance"><summary>源文件与生成信息</summary><p>来源：{escape(survey['source']['filename'])}</p>
<p>SHA-256：<code>{survey['source']['sha256']}</code></p><p>图表由FigCompose {version('figcompose')} 的原生自定义面板绘制、检查并导出；SVG、字体与下载文件均内嵌，可离线使用。</p></details></section>
{font_license_html()}<footer>手机通知管理与专注状态调研 · 按原始Word统计表生成</footer></main></body></html>'''
    return document.replace("__FONT__", webfont(document))


def main() -> None:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", nargs="?", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--artifacts", type=Path, default=DEFAULT_ARTIFACTS)
    parser.add_argument("--data-output", type=Path, default=DATA_PATH)
    args = parser.parse_args()
    survey = read_survey(args.source)
    for folder in (args.output.parent, args.artifacts, args.data_output.parent):
        folder.mkdir(parents=True, exist_ok=True)
    check = render_overview(survey, args.artifacts)
    json_bytes = (json.dumps(survey, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode("utf-8")
    csv_bytes = csv_data(survey).encode("utf-8-sig")
    args.data_output.write_bytes(json_bytes)
    (args.artifacts / "notification-survey.csv").write_bytes(csv_bytes)
    args.output.write_text(report_html(survey, args.artifacts, json_bytes, csv_bytes), encoding="utf-8")
    manifest = {"renderer": "FigCompose", "version": version("figcompose"), "chart": "100% stacked bars (custom panel)",
                "source": survey["source"], "effectiveN": {f"Q{q['number']}": q["effectiveN"] for q in survey["questions"]},
                "checks": {"countSums": True, "sourcePercentages": True, "stackLengths": True, "layout": check},
                "outputs": [str(args.output), str(args.data_output), *[str(p) for p in sorted(args.artifacts.glob("survey-overview.*"))]]}
    (args.artifacts / "render-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"report": str(args.output), "artifacts": str(args.artifacts), "checks": manifest["checks"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
