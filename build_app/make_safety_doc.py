#!/usr/bin/env python3
"""Regenerate docs/safe-to-delete.md from the safety knowledge base."""

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DB = ROOT / "Sources/DiskCleaner/Resources/safety_db.json"
OUT = ROOT / "docs/safe-to-delete.md"

AI_RE = re.compile(r"codex|claude|qoder|ollama|chatgpt|copilot|cursor|gemini", re.I)

GROUPS = [
    ("dev", "开发工具"),
    ("general", "应用缓存与系统日志"),
    ("cn_app", "国产 App"),
]

COST = {
    ("safe", None): "安全",
    ("warn", "redo"): "重下",
    ("warn", "data"): "不可恢复",
}


def cost_of(e):
    return COST.get((e.get("level"), e.get("cost")), e.get("level", ""))


def cell(text):
    return (text or "").replace("|", "\\|").replace("\n", " ").strip()


def name_cell(e):
    name = cell(e.get("name"))
    docs = e.get("docs")
    return f"[{name}]({docs})" if docs else name


def table(entries):
    rows = [
        "| 名称 | 路径 | 这是什么 | 删了会怎样 | 代价 |",
        "| --- | --- | --- | --- | --- |",
    ]
    for e in entries:
        whatif = cell(e.get("whatif"))
        rec = cell(e.get("rec"))
        consequence = f"{whatif}<br>恢复：{rec}" if rec and rec != whatif else whatif
        rows.append(
            "| {name} | `{path}` | {what} | {cons} | **{cost}** |".format(
                name=name_cell(e),
                path=cell(e.get("path")),
                what=cell(e.get("what")),
                cons=consequence,
                cost=cost_of(e),
            )
        )
    return "\n".join(rows)


def main():
    db = json.loads(DB.read_text(encoding="utf-8"))
    entries = db["entries"]
    ai = [e for e in entries if AI_RE.search(f"{e.get('name','')} {e.get('path','')}")]
    ai_names = {id(e) for e in ai}

    out = [
        "# 这些占空间的东西，删了会怎样",
        "",
        "macOS 上 {n} 个常见的占空间位置，每一条都写清楚三件事：它是什么、删掉会怎样、删错的代价。"
        "这就是 DiskWise 扫描时读的那份数据，不是宣传文案——App 里每一行旁边显示的就是这里的原文。".format(n=len(entries)),
        "",
        "*What follows is the safety knowledge base DiskWise reads at scan time: {n} locations that eat "
        "disk space on macOS, each with what it is, what deleting it does, and what it costs if you "
        "were wrong. The table is in Chinese because that is the language of the source data; "
        "`Sources/DiskCleaner/Resources/safety_db.json` is the machine-readable original.*".format(n=len(entries)),
        "",
        "代价分三级：",
        "",
        "- **安全** — 删掉不影响任何功能，程序会自己重新生成。",
        "- **重下** — 删掉要重新下载或重装才能回来，数据本身不丢。",
        "- **不可恢复** — 删掉就真没了，重下也回不来。会话记录、历史对话属于这一级。",
        "",
        "路径不存在时不会出现在扫描结果里，所以下面的条数不等于你机器上的条数。",
        "",
    ]

    if ai:
        out += [
            "## AI 编程工具留下的东西",
            "",
            "Codex、Claude Code、Qoder、Ollama 这类工具会把缓存、运行日志和会话记录混在同一棵目录树下。"
            "日志删了没事，会话记录往往是历史对话仅存的一份——下面按这个区别列出来。",
            "",
            table(ai),
            "",
        ]

    for grp, title in GROUPS:
        rows = [e for e in entries if e.get("grp") == grp and id(e) not in ai_names]
        if not rows:
            continue
        out += [f"## {title}", "", table(rows), ""]

    out += [
        "---",
        "",
        "这份文档由 `build_app/make_safety_doc.py` 从 `safety_db.json` 生成，别直接改它。"
        "要补条目或改说法，改 JSON 然后重新生成：",
        "",
        "```sh",
        "python3 build_app/make_safety_doc.py",
        "```",
        "",
        "知识库版本 {v}，更新于 {u}。缺了你常用工具的缓存路径？提个 PR 把它加进 JSON 就行。".format(
            v=db.get("version"), u=db.get("updated")
        ),
        "",
    ]

    OUT.write_text("\n".join(out), encoding="utf-8")
    print(f"{OUT.relative_to(ROOT)}: {len(entries)} entries, {len(ai)} in the AI section")


if __name__ == "__main__":
    main()
