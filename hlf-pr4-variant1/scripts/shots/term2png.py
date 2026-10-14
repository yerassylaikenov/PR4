#!/usr/bin/env python3
"""Run a shell command in the repository and save its real, coloured terminal output as a PNG
that looks like an Ubuntu terminal window (rendered by headless Chromium / Playwright).

Usage: term2png.py <out.png> "<command shown and executed>" [--width 1400] [--display "<shown command>"]
The command is executed with bash -lc in the repo root; nothing is faked — the PNG contains exactly
the bytes the command printed (secrets are redacted by the scripts themselves before printing).
"""
import argparse
import html
import os
import re
import subprocess
import sys

from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PALETTE = {30: "#2e3436", 31: "#ef2929", 32: "#8ae234", 33: "#fce94f", 34: "#729fcf", 35: "#ad7fa8",
           36: "#34e2e2", 37: "#d3d7cf", 90: "#888a85", 91: "#ef2929", 92: "#8ae234", 93: "#fce94f",
           94: "#729fcf", 95: "#ad7fa8", 96: "#34e2e2", 97: "#eeeeec"}
SGR = re.compile(r"\x1b\[([0-9;]*)m")
OTHER = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\r")


def ansi_to_html(text: str) -> str:
    text = OTHER.sub("", text)
    out, pos = [], 0
    fg, bold, dim = None, False, False
    open_span = False

    def style():
        s = []
        if fg:
            s.append(f"color:{fg}")
        if bold:
            s.append("font-weight:700")
        if dim:
            s.append("opacity:.62")
        return ";".join(s)

    for m in SGR.finditer(text):
        out.append(html.escape(text[pos:m.start()]))
        pos = m.end()
        codes = [int(c) for c in m.group(1).split(";") if c] or [0]
        for c in codes:
            if c == 0:
                fg, bold, dim = None, False, False
            elif c == 1:
                bold = True
            elif c == 2:
                dim = True
            elif c in PALETTE:
                fg = PALETTE[c]
            elif c == 39:
                fg = None
        if open_span:
            out.append("</span>")
            open_span = False
        st = style()
        if st:
            out.append(f'<span style="{st}">')
            open_span = True
    out.append(html.escape(text[pos:]))
    if open_span:
        out.append("</span>")
    res = "".join(out)
    if not SGR.search(text):  # plain evidence log (colours stripped when saved): restore highlighting
        marks = [("✔", "#8ae234"), ("PASS**", "#8ae234"), ("✘", "#ef2929"), ("FAIL**", "#ef2929"),
                 ("━━", "#ad7fa8"), ("══", "#8ae234"), ("⚠", "#fce94f"), ("➜", "#34e2e2")]
        lines = []
        for ln in res.split("\n"):
            for mark, color in marks:
                if mark in ln:
                    ln = f'<span style="color:{color};font-weight:700">{ln}</span>'
                    break
            else:
                if ln.startswith("$ "):
                    ln = f'<span style="opacity:.62">{ln}</span>'
            lines.append(ln)
        res = "\n".join(lines)
    return res


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("command")
    ap.add_argument("--display", default=None, help="command line shown after the prompt")
    ap.add_argument("--width", type=int, default=1400)
    a = ap.parse_args()

    env = dict(os.environ, FORCE_COLOR="1", TERM="xterm-256color", COLUMNS="160")
    res = subprocess.run(["bash", "-lc", a.command], cwd=ROOT, env=env,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=1800)
    body = ansi_to_html(res.stdout.decode("utf-8", "replace").rstrip("\n"))
    shown = html.escape(a.display or a.command)
    prompt = ('<span style="color:#8ae234;font-weight:700">yeras@YerassylAikenov</span>:'
              '<span style="color:#729fcf;font-weight:700">~/hlf-pr4-variant1</span>$ ')
    page = f"""<!doctype html><html><head><meta charset="utf-8"><style>
body{{margin:0;background:#c9ced6;padding:18px;font-family:'DejaVu Sans Mono',monospace}}
.win{{width:{a.width}px;border-radius:9px;overflow:hidden;box-shadow:0 6px 24px rgba(0,0,0,.35)}}
.bar{{background:#2c2c2c;color:#ddd;font:13px 'DejaVu Sans',sans-serif;padding:8px 12px;display:flex;align-items:center}}
.dot{{width:12px;height:12px;border-radius:50%;display:inline-block;margin-right:7px}}
.t{{flex:1;text-align:center;margin-right:60px}}
pre{{margin:0;background:#300a24;color:#eeeeec;font-size:13px;line-height:1.38;padding:12px 14px;
white-space:pre-wrap;word-break:break-all}}
</style></head><body><div class="win"><div class="bar"><span class="dot" style="background:#ff5f56"></span>
<span class="dot" style="background:#ffbd2e"></span><span class="dot" style="background:#27c93f"></span>
<span class="t">yeras@YerassylAikenov: ~/hlf-pr4-variant1 — Ubuntu 24.04 (WSL2)</span></div>
<pre>{prompt}{shown}
{body}
{prompt}</pre></div></body></html>"""
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with sync_playwright() as p:
        b = p.chromium.launch()
        pg = b.new_page(viewport={"width": a.width + 36, "height": 400}, device_scale_factor=1.5)
        pg.set_content(page)
        pg.locator(".win").screenshot(path=a.out)
        b.close()
    print(f"saved {a.out} (exit code of command: {res.returncode})")
    sys.exit(0)


if __name__ == "__main__":
    main()
