#!/usr/bin/env bash
# 计算 KernelSU 指定提交的版本号（与内核 Kbuild 的算法一致）。
#
# 上游的版本公式并不固定：VERSION_BASE、VERSION_OFFSET 与加减号会随发布调整
#（例如 30000+count+996、30000+count-4001、40000+count-2815），因此这里直接读
# 源码里的公式求值，而不是在工作流里写死常量；否则内核实际版本与管理器
# versionCode、产物命名会对不上。
#
# 提交数以「该提交的祖先数量」为准：工作流会把源码里的 REPO_BRANCH 改写成锁定的
# 提交，Kbuild 再对这个分支名做 rev-list --count，得到的正是同一个数。浅克隆数
# 出来会偏小，此时改走上游 API 的 X-Total-Count。
#
# 用法：ksu-version.sh <KernelSU 目录> <提交/分支> [版本文件]
#   版本文件默认 kernel/Kbuild；给定文件里没有 VERSION_BASE 时会自动改试
#   kernel/Kbuild、kernel/Makefile（上游只在其中一个里定义公式）
# 输出：版本号（纯数字）
set -euo pipefail

KSU_DIR="${1:?需要 KernelSU 目录}"
REF="${2:?需要提交或分支}"
VERSION_FILE="${3:-kernel/Kbuild}"

# 取含版本公式的源文件：优先调用方指定的路径，其次已知的版本块位置
# （上游 2026-11 起把 REPO_BRANCH/VERSION_BASE 挪进 kernel/kbuild-config/version.mk，
#  kernel/Kbuild 只 include 它、kernel/Makefile 只剩手动构建目标）
SOURCE=""
for CAND in "$VERSION_FILE" kernel/kbuild-config/version.mk kernel/Kbuild kernel/Makefile; do
  TEXT=$(git -C "$KSU_DIR" show "$REF:$CAND" 2>/dev/null) || continue
  if printf '%s\n' "$TEXT" | grep -q '^VERSION_BASE'; then
    SOURCE="$TEXT"
    VERSION_FILE="$CAND"
    break
  fi
done

meta() {  # 取 Kbuild 里的仓库元信息，用于浅克隆时走 API
  printf '%s\n' "$SOURCE" | sed -n "s/^$1[[:space:]]*:=[[:space:]]*//p" | head -n1 | tr -d ' \r'
}

count_commits() {
  local count
  if [ "$(git -C "$KSU_DIR" rev-parse --is-shallow-repository 2>/dev/null)" != "true" ]; then
    count=$(git -C "$KSU_DIR" rev-list --count "$REF" 2>/dev/null) || count=""
    if [ -n "$count" ] && [ "$count" -ge 2 ] 2>/dev/null; then
      echo "$count"
      return 0
    fi
  fi

  # 浅克隆：按上游 Kbuild 的做法用 API 的总数头
  local owner name api headers total
  owner=$(meta REPO_OWNER)
  name=$(meta REPO_NAME)
  if [ -z "$owner" ] || [ -z "$name" ]; then
    echo "无法统计 $REF 的提交数（浅克隆且缺少 REPO_OWNER/REPO_NAME）" >&2
    return 1
  fi
  case "$owner/$name" in
    shirkneko/SukiSU) api="https://git.zako.shirkneko.top:20004/api/v1/repos/$owner/$name" ;;
    *)                api="https://api.github.com/repos/$owner/$name" ;;
  esac
  headers=$(curl -s -D - -o /dev/null --max-time 20 -H "Accept: application/vnd.github+json" \
    "$api/commits?sha=$REF&limit=1&per_page=1" 2>/dev/null || true)
  total=$(printf '%s\n' "$headers" | tr -d '\r' | sed -n 's/^[Xx]-[Tt]otal-[Cc]ount:[[:space:]]*\([0-9]\+\).*/\1/p' | head -n1)
  if [ -z "$total" ]; then
    # GitHub 不返回该头，从 Link 的 rel="last" 页号推算（per_page=1）
    total=$(printf '%s\n' "$headers" | tr -d '\r' | sed -n 's/.*[?&]page=\([0-9]\+\)>; rel="last".*/\1/p' | head -n1)
  fi
  if [ -z "$total" ]; then
    echo "无法统计 $REF 的提交数（API 未返回总数）" >&2
    return 1
  fi
  echo "$total"
}

COUNT=$(count_commits) || exit 1

BASE=$(printf '%s\n' "$SOURCE" | sed -n 's/^VERSION_BASE[[:space:]]*:=[[:space:]]*\([0-9]\+\).*/\1/p' | head -n1)
OFFSET=$(printf '%s\n' "$SOURCE" | sed -n 's/^VERSION_OFFSET[[:space:]]*:=[[:space:]]*\([0-9]\+\).*/\1/p' | head -n1)

if [ -z "$SOURCE" ] || [ -z "$BASE" ] || [ -z "$OFFSET" ]; then
  # 上游结构变化时退回历史默认值，避免构建中断；日志里留痕便于排查。
  echo "::warning::$REF 的 kernel/Kbuild 与 kernel/Makefile 都缺少 VERSION_BASE/VERSION_OFFSET，回退 30000+提交数+996" >&2
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