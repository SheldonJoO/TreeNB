#!/usr/bin/env python3
"""Spike 构建时给主 App target 注入 TNB_SPIKE 编译条件（纯文本，保护注释与格式）。

不用 xcodebuild 命令行覆盖 SWIFT_ACTIVE_COMPILATION_CONDITIONS 的原因：
  命令行设置是全局的，会覆盖所有 target 的 target 级设置，$(inherited) 只继承
  project 级——既冲掉 Widget 的 WIDGET_EXTENSION，又让 framework 意外带上
  TNB_SPIKE。改为生成工程前文本注入 project.yml，各 target 互不污染。

不用 PyYAML 重写整份 project.yml 的原因：会丢失注释、改变键顺序、可能误处理
  $(inherited) 等特殊值。这里只对 TreeNB target 的 base 块做精确文本插入。

用法:
  python3 scripts/inject_spike.py           # 注入（幂等）
  python3 scripts/inject_spike.py --remove  # 移除
"""
import sys

PATH = "project.yml"
BEGIN = "        # >>> TNB_SPIKE (injected by inject_spike.py) >>>\n"
END = "        # <<< TNB_SPIKE (injected by inject_spike.py) <<<\n"
BLOCK = (
    BEGIN
    + "        SWIFT_ACTIVE_COMPILATION_CONDITIONS:\n"
    + "          - '$(inherited)'\n"
    + "          - TNB_SPIKE\n"
    + "        GCC_PREPROCESSOR_DEFINITIONS:\n"
    + "          - '$(inherited)'\n"
    + "          - TNB_SPIKE=1\n"
    + END
)
# 锚点：TreeNB target 的 base 块里 PRODUCT_NAME 那一行（全局唯一的精确串）
ANCHOR = "  TreeNB:\n    type: com.apple.product-type.application\n    platform: iOS\n    settings:\n      base:\n        PRODUCT_NAME: TreeNB\n"


def main():
    with open(PATH, encoding="utf-8") as f:
        s = f.read()

    # 幂等移除旧块
    if BEGIN in s:
        i = s.index(BEGIN)
        j = s.index(END, i) + len(END)
        s = s[:i] + s[j:]

    remove = "--remove" in sys.argv
    if not remove:
        if ANCHOR not in s:
            raise SystemExit("[inject_spike] ERROR: TreeNB target 锚点未找到，project.yml 结构可能已变")
        s = s.replace(ANCHOR, ANCHOR + BLOCK, 1)

    with open(PATH, "w", encoding="utf-8") as f:
        f.write(s)
    print("[inject_spike]", "removed" if remove else "injected", "TNB_SPIKE into TreeNB target")


if __name__ == "__main__":
    main()
