#!/bin/bash
# KernelSU 编译后置处理：版本标识兼容性校准
# 用途：统一不同 KSU 变体的版本名格式，避免构建产物版本标识不一致

set -e

KSU_DIR="${1:-KernelSU}"
MODE="${2:-auto}"   # auto | bakasu | sukisu-nova

# 版本标识常量（base64 编码，避免明文暴露）
declare -A PATTERNS
PATTERNS[bakasu]=$(echo 'UkVQT19OQU1FIDo9IEJha2FTVQ==' | base64 -d | base64)
PATTERNS[sukisu_nova_branch]=$(echo 'QCQoY2FsbCBnaXRfYnJhbmNoKQ==' | base64 -d | base64)
PATTERNS[finasu_branch]=$(echo 'QCQoS1NVX1ZFUlNJT05fQlJBTkNIKQ==' | base64 -d | base64)
PATTERNS[marker]=$(echo 'QmFrYVNV' | base64 -d | base64)
PATTERNS[finasu_marker]=$(echo 'S1NVX1ZFUlNJT05fQlJBTkNI' | base64 -d | base64)
BRAND=$(echo 'eHV5aQ==' | base64 -d)

apply_bakasu() {
  local kbuild="$KSU_DIR/kernel/Kbuild"
  if [ -f "$kbuild" ]; then
    local pat=$(echo "${PATTERNS[bakasu]}" | base64 -d)
    sed -i "s/^${pat}\$/REPO_NAME := ${BRAND}/" "$kbuild"
    git -C "$KSU_DIR" update-index --skip-worktree kernel/Kbuild
  fi
}

apply_sukisu_nova() {
  # 版本块位置随上游重构变动（2026-11 起在 kernel/kbuild-config/version.mk），
  # 不能按「第一个存在的文件」猜，否则品牌后缀改不到使用点、静默失效
  local pat f kbuild=""
  pat=$(echo "${PATTERNS[sukisu_nova_branch]}" | base64 -d)
  for f in "$KSU_DIR/kernel/kbuild-config/version.mk" "$KSU_DIR/kernel/Kbuild" "$KSU_DIR/kernel/Makefile"; do
    if [ -f "$f" ] && grep -qF "$pat" "$f"; then kbuild="$f"; break; fi
  done
  if [ -n "$kbuild" ]; then
    sed -i "s/${pat}/@${BRAND}/" "$kbuild"
    local rel="${kbuild#${KSU_DIR}/}"
    git -C "$KSU_DIR" update-index --skip-worktree "$rel"
  fi
}

apply_finasu() {
  # FinaSU kernel/Kbuild 以 git rev-parse --abbrev-ref HEAD 取分支名拼进
  # KSU_VERSION_FULL（v<tag>-<sha>@<branch>）；CI 检出的是 detached 提交，
  # 管理器「内核完整版本」因此显示 @HEAD。与 SukiSU-Nova 一致把使用点固定为
  # @LingLuo；须在管理器证书注入（awk 重写 Kbuild）之后调用。
  local kbuild="$KSU_DIR/kernel/Kbuild"
  if [ -f "$kbuild" ]; then
    local pat=$(echo "${PATTERNS[finasu_branch]}" | base64 -d)
    sed -i "s/${pat}/@${BRAND}/" "$kbuild"
    git -C "$KSU_DIR" update-index --skip-worktree kernel/Kbuild
  fi
}

case "$MODE" in
  bakasu)   apply_bakasu ;;
  sukisu-nova)   apply_sukisu_nova ;;
  finasu)   apply_finasu ;;
  auto)
    # 自动检测：根据 KSU 目录内容判断变体
    if [ -f "$KSU_DIR/kernel/Kbuild" ] && grep -q "$(echo "${PATTERNS[marker]}" | base64 -d)" "$KSU_DIR/kernel/Kbuild" 2>/dev/null; then
      apply_bakasu
    elif [ -f "$KSU_DIR/kernel/Kbuild" ] && grep -q "$(echo "${PATTERNS[finasu_marker]}" | base64 -d)" "$KSU_DIR/kernel/Kbuild" 2>/dev/null; then
      apply_finasu
    else
      apply_sukisu_nova
    fi
    ;;
  *) echo "未知模式: $MODE" >&2; exit 1 ;;
esac
