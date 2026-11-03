#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ساخت خروجی ایستا از فایل Claude Design.

خروجی: dist/index.html به‌همراه assets/ و fonts/ — آمادهٔ آپلود روی سرور.

    python3 build.py

کارهایی که انجام می‌دهد:
  • محتوای <helmet> را به <head> منتقل می‌کند
  • <x-dc> و ران‌تایم support.js را حذف می‌کند
  • ویژگی‌های style-hover / style-focus را به CSS واقعی تبدیل می‌کند
  • کلاس DCLogic را به یک اسکریپت ساده با مقادیر پیش‌فرض props تبدیل می‌کند
"""

import html
import io
import json
import os
import re
import shutil
import sys

SRC = sys.argv[1] if len(sys.argv) > 1 else "Darineh Landing.dc.html"
OUT = sys.argv[2] if len(sys.argv) > 2 else "dist"
HERE = os.path.dirname(os.path.abspath(__file__))
COPY_DIRS = ["assets", "fonts"]

# تگ‌ها را با احترام به مقادیر داخل گیومه پیدا می‌کند (تا > داخل مقدار تگ را نشکند)
TAG_RE = re.compile(r'<[a-zA-Z][^>"\']*(?:(?:"[^"]*"|\'[^\']*\')[^>"\']*)*>')
PSEUDO_ATTR_RE = re.compile(r'\sstyle-([a-zA-Z-]+)="([^"]*)"')
CLASS_ATTR_RE = re.compile(r'\sclass="([^"]*)"')


def importantify(css):
    """هر اعلان را !important می‌کند — مطابق رفتار ران‌تایم Claude Design."""
    decls, depth, start = [], 0, 0
    for i, ch in enumerate(css):
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        elif ch == ";" and depth == 0:
            decls.append(css[start:i])
            start = i + 1
    decls.append(css[start:])
    out = []
    for d in (d.strip() for d in decls):
        if not d:
            continue
        out.append(d if re.search(r"!\s*important$", d, re.I) else d + " !important")
    return ";".join(out)


def convert_pseudo_styles(markup):
    """style-hover="..." → کلاس + قاعدهٔ :hover. برمی‌گرداند (markup, css)."""
    cache, rules = {}, []

    def on_tag(m):
        tag = m.group(0)
        found = PSEUDO_ATTR_RE.findall(tag)
        if not found:
            return tag
        tag = PSEUDO_ATTR_RE.sub("", tag)
        classes = []
        for pseudo, raw in found:
            css = html.unescape(raw)
            key = (pseudo, css)
            cls = cache.get(key)
            if not cls:
                cls = "scp" + format(len(cache), "x")
                cache[key] = cls
                is_element = pseudo in ("before", "after")
                sel = ".%s::%s" % (cls, pseudo) if is_element else ".%s:%s" % (cls, pseudo)
                rules.append("%s{%s}" % (sel, css if is_element else importantify(css)))
            classes.append(cls)
        joined = " ".join(classes)
        existing = CLASS_ATTR_RE.search(tag)
        if existing:
            return tag.replace(
                existing.group(0), ' class="%s %s"' % (existing.group(1), joined), 1
            )
        head, rest = re.match(r"<([a-zA-Z0-9-]+)(.*)", tag, re.S).groups()
        return "<%s class=\"%s\"%s" % (head, joined, rest)

    return TAG_RE.sub(on_tag, markup), "\n".join(rules)


def main():
    os.chdir(HERE)
    src = io.open(SRC, encoding="utf-8").read()

    helmet = re.search(r"<helmet>(.*?)</helmet>", src, re.S).group(1).strip()

    # charset و viewport در <head> بیرونی هستند، نه داخل <helmet> — باید اضافه شوند
    head_extra = []
    if not re.search(r"<meta\s+charset", helmet, re.I):
        head_extra.append('<meta charset="utf-8">')
    if not re.search(r'name="viewport"', helmet, re.I):
        head_extra.append('<meta name="viewport" content="width=device-width, initial-scale=1">')
    helmet = "\n".join(head_extra + [helmet])

    template = re.search(r"</helmet>(.*?)</x-dc>", src, re.S).group(1).strip()
    script_tag = re.search(
        r'<script type="text/x-dc"[^>]*data-props="([^"]*)"[^>]*>(.*?)</script>', src, re.S
    )
    props_schema = json.loads(html.unescape(script_tag.group(1)))
    logic = script_tag.group(2).strip()

    # مقادیر پیش‌فرض props به‌عنوان پیکربندی ثابت خروجی
    props = {k: v.get("default") for k, v in props_schema.items() if not k.startswith("$")}

    template, pseudo_css = convert_pseudo_styles(template)

    # DCLogic → کلاس ساده با props ثابت
    logic = logic.replace(
        "class Component extends DCLogic {",
        "class Component {\n  constructor(props) { this.props = props || {}; }",
        1,
    )

    script = (
        "(function () {\n"
        "  var PROPS = %s;\n\n"
        "%s\n\n"
        "  function boot() { new Component(PROPS).componentDidMount(); }\n"
        "  if (document.readyState === 'loading') "
        "document.addEventListener('DOMContentLoaded', boot);\n"
        "  else boot();\n"
        "})();"
    ) % (
        json.dumps(props, ensure_ascii=False, indent=2).replace("\n", "\n  "),
        re.sub(r"^", "  ", logic, flags=re.M),
    )

    page = """<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
%s
%s</head>
<body>
%s
<script>
%s
</script>
</body>
</html>
""" % (
        helmet,
        ("<style>\n%s\n</style>\n" % pseudo_css) if pseudo_css else "",
        template,
        script,
    )

    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    io.open(os.path.join(OUT, "index.html"), "w", encoding="utf-8").write(page)
    for d in COPY_DIRS:
        if os.path.isdir(d):
            shutil.copytree(d, os.path.join(OUT, d))

    # تا وقتی <meta name="robots" content="noindex"> در صفحه هست، خزنده‌ها را هم اینجا ببندیم
    noindex = bool(re.search(r'<meta\s+name="robots"[^>]*noindex', page, re.I))
    robots = "User-agent: *\nDisallow: /\n" if noindex else "User-agent: *\nAllow: /\n"
    io.open(os.path.join(OUT, "robots.txt"), "w", encoding="utf-8").write(robots)

    print("✓ %s/index.html (%.1f KB)" % (OUT, len(page.encode("utf-8")) / 1024))
    print("  robots.txt — %s" % ("noindex (بسته)" if noindex else "قابل ایندکس"))
    print("  قواعد شبه‌کلاس: %d" % len(pseudo_css.splitlines()))
    for d in COPY_DIRS:
        if os.path.isdir(os.path.join(OUT, d)):
            n = sum(len(f) for _, _, f in os.walk(os.path.join(OUT, d)))
            print("  %s/ — %d فایل" % (d, n))


if __name__ == "__main__":
    main()
