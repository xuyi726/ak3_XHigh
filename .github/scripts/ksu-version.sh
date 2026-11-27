#!/usr/bin/env bash
# 计算 KernelSU 指定提交的版本号（与内核 Kbuild/Makefile 的算法一致）。
#
# 上游的版本公式并不固定：VERSION_BASE、VERSION_OFFSET 与加减号会随发布调整
#（例如 30000+count+996、30000+count-4001、40000+count-2815），因此这里直接读
# 源码里的公式求值，而不是在工作流里写死常量；否则内核实际版本与管理器
# versionCode、产物命名会对不上。
#
# 用法：ksu-version.sh <KernelSU 目录> <提交/分支> [版本文件]
#   版本文件默认 kernel/Kbuild；builtin 分支的公式在 kernel/Makefile，需要显式传入
# 输出：版本号（纯数字）
set -euo pipefail

KSU_DIR="${1:?需要 KernelSU 目录}"
REF="${2:?需要提交或分支}"
VERSION_FILE="${3:-kernel/Kbuild}"

COUNT=$(git -C "$KSU_DIR" rev-list --count "$REF" 2>/dev/null) || {
  echo "无法统计 $REF 的提交数" >&2
  exit 1
}

SOURCE=$(git -C "$KSU_DIR" show "$REF:$VERSION_FILE" 2>/dev/null) || SOURCE=""
BASE=$(printf '%s\n' "$SOURCE" | sed -n 's/^VERSION_BASE[[:space:]]*:=[[:space:]]*\([0-9]\+\).*/\1/p' | head -n1)
OFFSET=$(printf '%s\n' "$SOURCE" | sed -n 's/^VERSION_OFFSET[[:space:]]*:=[[:space:]]*\([0-9]\+\).*/\1/p' | head -n1)

if [ -z "$SOURCE" ] || [ -z "$BASE" ] || [ -z "$OFFSET" ]; then
  # 上游结构变化时退回历史默认值，避免构建中断；日志里留痕便于排查。
  echo "::warning::$REF 的 $VERSION_FILE 缺少 VERSION_BASE/VERSION_OFFSET，回退 30000+提交数+996" >&2
  echo $((30000 + COUNT + 996))
  exit 0
fi

FORMULA=$(printf '%s\n' "$SOURCE" | grep -m1 '^KSU_VERSION[[:space:]]*:=' || true)
if printf '%s' "$FORMULA" | grep -qF '$(LOCAL_COUNT) - $(VERSION_OFFSET)'; then
  echo $((BASE + COUNT - OFFSET))
elif printf '%s' "$FORMULA" | grep -qF '$(LOCAL_COUNT) + $(VERSION_OFFSET)'; then
  echo $((BASE + COUNT + OFFSET))
else
  echo "::warning::$REF 的 $VERSION_FILE 公式未识别（$(printf '%s' "$FORMULA" | head -c 120)），按加法处理" >&2
  echo $((BASE + COUNT + OFFSET))
fi