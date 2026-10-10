# 把 docs 下的素材规范 Markdown 转成 Word（给人看的版本）。
# 用法：<python> .tmp/md2docx_final.py
#
# 设计决定（重要）：
#   Word 版**完全不使用表格**。md 里的表格一律展开成「小标题 + 字段：值」的段落列表。
#   原因：实测渲染器对含中文的表格单元格不做正常断行，长内容会画出单元格甚至出纸面，
#   而且同一份文件在不同参数下越界页数还会变化，靠调列宽无法稳定解决。
#   段落版没有任何宽度计算，永远不会出纸面；Markdown 原件里表格依然保留。
import re
from pathlib import Path

from docx import Document
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml.ns import qn
from docx.shared import Pt, RGBColor, Cm

DOCS = Path(r"E:\godot\模拟经营类\docs")
BODY_FONT = "Microsoft YaHei"
HEAD_FONT = "Microsoft YaHei"
MONO_FONT = "Consolas"
BODY_PT = 9.5


def set_run_font(run, name, size=None, bold=None, color=None):
    run.font.name = name
    rpr = run._element.get_or_add_rPr()
    rfonts = rpr.find(qn("w:rFonts"))
    if rfonts is None:
        rfonts = rpr.makeelement(qn("w:rFonts"), {})
        rpr.append(rfonts)
    rfonts.set(qn("w:eastAsia"), name)
    rfonts.set(qn("w:ascii"), name)
    rfonts.set(qn("w:hAnsi"), name)
    if size is not None:
        run.font.size = Pt(size)
    if bold is not None:
        run.font.bold = bold
    if color is not None:
        run.font.color.rgb = RGBColor.from_string(color)


INLINE = re.compile(r"(\*\*.+?\*\*|`[^`]+`)")
ZWSP = "\u200b"     # 零宽空格：给渲染器一个合法的断行点，不改变显示文本


def breakable(text):
    """中文句子里夹着的 `xxx_yyy` 这类行内代码，会被渲染器当成不可断的长词，
    整段被推到行尾、越出页边距（实测）。在下划线等位置插入零宽空格即可断行。"""
    for ch in ("_", "/", "-", "."):
        text = text.replace(ch, ch + ZWSP)
    return text


def add_inline(paragraph, text, font=BODY_FONT, size=BODY_PT, base_bold=False):
    for part in INLINE.split(text):
        if not part:
            continue
        if part.startswith("**") and part.endswith("**") and len(part) > 4:
            set_run_font(paragraph.add_run(part[2:-2]), font, size, True)
        elif part.startswith("`") and part.endswith("`") and len(part) > 2:
            set_run_font(paragraph.add_run(breakable(part[1:-1])), MONO_FONT, size - 1, base_bold, "B03060")
        else:
            set_run_font(paragraph.add_run(part), font, size, base_bold)
    return paragraph


def strip_md(text):
    return INLINE.sub(lambda m: m.group(0).strip("*`"), text)


def split_row(line):
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|"):
        line = line[:-1]
    return [c.strip() for c in line.split("|")]


def is_sep(line):
    return bool(re.fullmatch(r"\|?[\s:\-|]+\|?", line.strip())) and "-" in line


def emit_table_as_paragraphs(doc, rows):
    """表格 → 段落。每行：第一列当小标题，其余列作为「列名：值」。"""
    header, body = rows[0], rows[1:]
    for r in body:
        title = strip_md(r[0]) if r else ""
        p = doc.add_paragraph()
        p.paragraph_format.space_before = Pt(6)
        p.paragraph_format.left_indent = Cm(0.3)
        set_run_font(p.add_run(title), HEAD_FONT, BODY_PT + 0.5, True, "2E5496")
        # 单列的表（只有编号/名称）就直接把其余内容接在后面
        if len(header) == 1:
            continue
        for i in range(1, len(header)):
            val = r[i] if i < len(r) else ""
            if not val.strip():
                continue
            line = doc.add_paragraph(style="List Bullet")
            line.paragraph_format.left_indent = Cm(0.9)
            line.paragraph_format.space_after = Pt(0)
            label = strip_md(header[i]) if i < len(header) else ""
            if label:
                set_run_font(line.add_run(label + "："), BODY_FONT, BODY_PT, False, "777777")
            add_inline(line, val)
    doc.add_paragraph()


def convert(md_path, docx_path):
    lines = md_path.read_text(encoding="utf-8").splitlines()
    doc = Document()

    sec = doc.sections[0]
    for m in ("left_margin", "right_margin"):
        setattr(sec, m, Cm(1.8))
    for m in ("top_margin", "bottom_margin"):
        setattr(sec, m, Cm(1.8))

    style = doc.styles["Normal"]
    style.font.name = BODY_FONT
    style.font.size = Pt(BODY_PT)
    style.element.rPr.rFonts.set(qn("w:eastAsia"), BODY_FONT)

    i = 0
    while i < len(lines):
        line = lines[i].rstrip()
        stripped = line.strip()

        # 代码块
        if stripped.startswith("```"):
            i += 1
            buf = []
            while i < len(lines) and not lines[i].strip().startswith("```"):
                buf.append(lines[i])
                i += 1
            i += 1
            for src in buf:
                p = doc.add_paragraph()
                p.paragraph_format.left_indent = Cm(0.6)
                p.paragraph_format.space_after = Pt(0)
                set_run_font(p.add_run(src), MONO_FONT, 9, False, "444444")
            continue

        # 表格 → 段落
        if stripped.startswith("|") and i + 1 < len(lines) and is_sep(lines[i + 1]):
            rows = [split_row(lines[i])]
            i += 2
            while i < len(lines) and lines[i].strip().startswith("|"):
                rows.append(split_row(lines[i]))
                i += 1
            emit_table_as_paragraphs(doc, rows)
            continue

        if not stripped:
            i += 1
            continue

        m = re.match(r"^(#{1,6})\s+(.*)$", stripped)
        if m:
            level = len(m.group(1))
            text = m.group(2)
            if level == 1:
                p = doc.add_paragraph()
                p.alignment = WD_ALIGN_PARAGRAPH.CENTER
                set_run_font(p.add_run(strip_md(text)), HEAD_FONT, 19, True, "1F3864")
            else:
                p = doc.add_paragraph()
                p.paragraph_format.space_before = Pt(10 if level == 2 else 6)
                size = {2: 14, 3: 12, 4: 10.5}.get(level, 10)
                color = {2: "2E5496", 3: "2E5496", 4: "404040"}.get(level, "404040")
                add_inline(p, text, HEAD_FONT, size, True)
                for run in p.runs:
                    run.font.color.rgb = RGBColor.from_string(color)
            i += 1
            continue

        if re.fullmatch(r"-{3,}", stripped):
            p = doc.add_paragraph()
            set_run_font(p.add_run("-" * 50), BODY_FONT, 8, False, "AAAAAA")
            i += 1
            continue

        if stripped.startswith(">"):
            p = doc.add_paragraph()
            p.paragraph_format.left_indent = Cm(0.6)
            add_inline(p, stripped.lstrip("> ").strip(), BODY_FONT, BODY_PT)
            for run in p.runs:
                run.font.color.rgb = RGBColor.from_string("555555")
            i += 1
            continue

        m = re.match(r"^\s*-\s+\[[ x]\]\s+(.*)$", line)
        if m:
            p = doc.add_paragraph()
            p.paragraph_format.left_indent = Cm(0.6)
            add_inline(p, "[ ] " + m.group(1))
            i += 1
            continue

        m = re.match(r"^(\s*)([-*]|\d+\.)\s+(.*)$", line)
        if m:
            depth = len(m.group(1)) // 2
            p = doc.add_paragraph(style="List Bullet" if m.group(2) in "-*" else "List Number")
            p.paragraph_format.left_indent = Cm(0.6 + depth * 0.6)
            add_inline(p, m.group(3))
            i += 1
            continue

        add_inline(doc.add_paragraph(), stripped)
        i += 1

    doc.save(str(docx_path))
    print("OK  %s -> %s" % (md_path.name, docx_path.name))


if __name__ == "__main__":
    for src, dst in [("素材制作规范_人工.md", "素材制作规范_人工.docx"),
                     ("素材清单.md", "素材清单.docx")]:
        convert(DOCS / src, DOCS / dst)
