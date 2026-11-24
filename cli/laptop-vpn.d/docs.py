"""`vpn docs`: docs/LAPTOP-VPN.md as a right-to-left page, opened in the browser.

A small Markdown subset (what the guide uses: headings, paragraphs, lists,
tables, fenced code, `code`, **bold**, [links](…)) turned into HTML with no
dependencies, so it works with the VPN off too. Commands and code stay
left-to-right inside the Persian text. Writes ~/.config/laptop-vpn/guide.html.
"""

from __future__ import annotations

import html
import re
import sys
from pathlib import Path

FONT_DIRS = [Path.home() / ".claude/skills/persian-writing/assets/fonts", Path("/Library/Fonts"), Path.home() / "Library/Fonts"]

CSS = """
:root { color-scheme: light dark; --fg: #1d1d1f; --muted: #6e6e73; --line: #d2d2d7; --code: #f5f5f7; --bg: #ffffff; }
@media (prefers-color-scheme: dark) { :root { --fg: #f5f5f7; --muted: #a1a1a6; --line: #3a3a3c; --code: #2c2c2e; --bg: #1c1c1e; } }
body { background: var(--bg); color: var(--fg); margin: 0; font: 17px/1.9 Vazirmatn, "Vazirmatn Local", Tahoma, sans-serif; }
main { max-width: 860px; margin: 0 auto; padding: 32px 20px 80px; }
h1 { font-size: 1.9em; line-height: 1.4; margin: 0.2em 0 0.6em; }
h2 { font-size: 1.4em; margin: 2em 0 0.6em; padding-top: 0.6em; border-top: 1px solid var(--line); }
h3 { font-size: 1.15em; margin: 1.6em 0 0.4em; }
p, li { margin: 0.5em 0; }
ul, ol { padding-inline-start: 1.4em; }
ol { list-style-type: persian; }
code { font: 0.86em/1.5 ui-monospace, Menlo, monospace; background: var(--code); padding: 0.1em 0.35em; border-radius: 4px; unicode-bidi: isolate; direction: ltr; }
pre { background: var(--code); padding: 12px 16px; border-radius: 8px; overflow-x: auto; direction: ltr; text-align: left; }
pre code { background: none; padding: 0; font-size: 0.85em; }
table { border-collapse: collapse; width: 100%; margin: 1em 0; font-size: 0.95em; }
th, td { border: 1px solid var(--line); padding: 6px 10px; vertical-align: top; text-align: start; }
th { background: var(--code); }
a { color: inherit; }
nav { font-size: 0.92em; color: var(--muted); border: 1px solid var(--line); border-radius: 8px; padding: 10px 18px; margin: 1em 0 2em; }
nav ol { margin: 0; }
.src { color: var(--muted); font-size: 0.85em; }
"""


def font_face() -> str:
    """Vazirmatn from this machine if it's there (no network needed), else the system fallback."""
    rules = []
    for weight, name in ((400, "Vazirmatn-Regular.ttf"), (700, "Vazirmatn-Bold.ttf")):
        for d in FONT_DIRS:
            if (d / name).exists():
                rules.append(
                    f'@font-face {{ font-family: "Vazirmatn Local"; font-weight: {weight}; '
                    f'src: local("Vazirmatn"), url("{(d / name).as_uri()}"); }}'
                )
                break
    return "\n".join(rules)


def inline(text: str) -> str:
    # Code spans out first (their contents are literal), then **bold** and links
    # over the whole line, so bold can wrap code: **با `vpn set`**.
    codes: list[str] = []

    def keep(m: re.Match) -> str:
        codes.append(f'<code dir="ltr">{html.escape(m.group(1))}</code>')
        return f"\x02{len(codes) - 1}\x03"

    t = re.sub(r"`([^`]+)`", keep, text)
    t = html.escape(t, quote=False)
    t = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", t)
    t = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', t)
    return re.sub(r"\x02(\d+)\x03", lambda m: codes[int(m.group(1))], t)


def slug(text: str) -> str:
    return re.sub(r"[^\w؀-ۿ]+", "-", text).strip("-").lower()


def render(md: str) -> tuple[str, str, list[tuple[str, str]]]:
    lines = md.splitlines()
    out: list[str] = []
    toc: list[tuple[str, str]] = []
    title = "VPN"
    i = 0
    para: list[str] = []

    def flush() -> None:
        if para:
            out.append(f"<p>{inline(' '.join(para))}</p>")
            para.clear()

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if stripped.startswith("```"):
            flush()
            i += 1
            code = []
            while i < len(lines) and not lines[i].strip().startswith("```"):
                code.append(lines[i])
                i += 1
            indent = min((len(c) - len(c.lstrip()) for c in code if c.strip()), default=0)
            out.append("<pre><code>" + html.escape("\n".join(c[indent:] for c in code)) + "</code></pre>")
            i += 1
            continue
        m = re.match(r"^(#{1,4})\s+(.*)$", stripped)
        if m:
            flush()
            level, text = len(m.group(1)), m.group(2)
            if level == 1:
                title = re.sub(r"[`*]", "", text)
                out.append(f"<h1>{inline(text)}</h1>")
            else:
                anchor = slug(text)
                if level == 2:
                    toc.append((anchor, re.sub(r"[`*]", "", text)))
                out.append(f'<h{level} id="{anchor}">{inline(text)}</h{level}>')
            i += 1
            continue
        if stripped.startswith("|"):
            flush()
            rows = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                rows.append(lines[i].strip())
                i += 1
            cells = [re.split(r"(?<!\\)\|", r.strip("|")) for r in rows]
            cells = [[c.strip().replace("\\|", "|") for c in r] for r in cells]
            body = [r for r in cells[1:] if not all(re.fullmatch(r":?-{2,}:?", c) for c in r)]
            t = ["<table><thead><tr>" + "".join(f"<th>{inline(c)}</th>" for c in cells[0]) + "</tr></thead><tbody>"]
            t += ["<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>" for r in body]
            out.append("".join(t) + "</tbody></table>")
            continue
        lm = re.match(r"^(\s*)([-*]|\d+\.|[۰-۹]+\.)\s+(.*)$", line)
        if lm:
            flush()
            ordered = not lm.group(2) in ("-", "*")
            tag = "ol" if ordered else "ul"
            items = []
            while i < len(lines):
                mm = re.match(r"^(\s*)([-*]|\d+\.|[۰-۹]+\.)\s+(.*)$", lines[i])
                if mm and len(mm.group(1)) == len(lm.group(1)):
                    items.append([mm.group(3)])
                    i += 1
                elif lines[i].strip() and lines[i].startswith(" ") and items:
                    # continuation or nested content: keep code fences as their own block
                    if lines[i].strip().startswith("```"):
                        i += 1
                        code = []
                        while i < len(lines) and not lines[i].strip().startswith("```"):
                            code.append(lines[i])
                            i += 1
                        i += 1
                        indent = min((len(c) - len(c.lstrip()) for c in code if c.strip()), default=0)
                        items[-1].append("\x00" + "\n".join(c[indent:] for c in code))
                    else:
                        sub = re.match(r"^\s+([-*])\s+(.*)$", lines[i])
                        items[-1].append(("\x01" + sub.group(2)) if sub else lines[i].strip())
                        i += 1
                elif not lines[i].strip() and i + 1 < len(lines) and lines[i + 1].startswith("  ") and items:
                    i += 1
                else:
                    break
            html_items = []
            for it in items:
                text, extra, subs = [it[0]], [], []
                for piece in it[1:]:
                    if piece.startswith("\x00"):
                        extra.append("<pre><code>" + html.escape(piece[1:]) + "</code></pre>")
                    elif piece.startswith("\x01"):
                        subs.append(f"<li>{inline(piece[1:])}</li>")
                    elif extra or subs:
                        extra.append(f"<p>{inline(piece)}</p>")
                    else:
                        text.append(piece)
                sub_html = f"<ul>{''.join(subs)}</ul>" if subs else ""
                html_items.append(f"<li>{inline(' '.join(text))}{sub_html}{''.join(extra)}</li>")
            out.append(f"<{tag}>{''.join(html_items)}</{tag}>")
            continue
        if not stripped:
            flush()
        else:
            para.append(stripped)
        i += 1
    flush()
    return title, "\n".join(out), toc


def build(md_path: Path, out_path: Path) -> None:
    title, body, toc = render(md_path.read_text())
    nav = ""
    if toc:
        nav = "<nav><strong>فهرست</strong><ol>" + "".join(f'<li><a href="#{a}">{inline(t)}</a></li>' for a, t in toc) + "</ol></nav>"
    first_h1_end = body.find("</h1>") + len("</h1>") if "</h1>" in body else 0
    body = body[:first_h1_end] + nav + body[first_h1_end:]
    page = f"""<!doctype html>
<html lang="fa" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<style>{font_face()}{CSS}</style>
</head>
<body><main>
{body}
<p class="src">ساخته‌شده از <code dir="ltr">{html.escape(str(md_path))}</code></p>
</main></body>
</html>
"""
    out_path.write_text(page)


if __name__ == "__main__":
    build(Path(sys.argv[1]), Path(sys.argv[2]))
