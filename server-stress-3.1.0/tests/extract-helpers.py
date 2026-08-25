#!/usr/bin/env python3
"""把 server-stress.sh 里内嵌的 Python 助手抽出来，供测试单独做语法编译。

主脚本把助手写成 heredoc，运行时才落盘并在结束后删除，因此测试不能等到运行时再检查。
这里直接从源码里提取，配合 py_compile 就能在不施加任何压力的情况下发现语法错误。
"""
import os
import re
import sys

PATTERN = re.compile(r"cat >\"\$HELPERS/([A-Za-z0-9_]+\.py)\" <<'PY'\n(.*?)\nPY\n", re.S)


def main():
    if len(sys.argv) != 3:
        raise SystemExit('usage: extract-helpers.py SCRIPT OUTDIR')
    script, outdir = sys.argv[1], sys.argv[2]
    with open(script, encoding='utf-8') as f:
        text = f.read()

    blocks = PATTERN.findall(text)
    if not blocks:
        raise SystemExit('no embedded helper found')
    os.makedirs(outdir, exist_ok=True)
    for name, body in blocks:
        with open(os.path.join(outdir, name), 'w', encoding='utf-8') as f:
            f.write(body + '\n')
        print(name)


main()
