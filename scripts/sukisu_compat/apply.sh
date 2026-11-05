#!/usr/bin/env bash
# SukiSU 内核源码 API 兼容补丁（SukiSU-Ultra builtin / main 分支均适用）
#
# 背景：
#   1) builtin 分支 kernel/hook/lsm_hook.c 仍以旧签名
#      security_add_hooks(hooks, count, "ksu") 注册 LSM 钩子，
#      6.8+ 内核要求 (hooks, count, const struct lsm_id *)，
#      android16-6.12 GKI 编译报 -Wincompatible-pointer-types（-Werror）；
#   2) <kpm>/super_access.c 引用 netlink_kernel_cfg.cb_mutex，
#      该成员在 Linux 6.11 被上游移除，KPM 开启时 6.11+ 内核编译失败
#      （上游 2026-10-19 重构后该文件由 kernel/kpm/ 迁至
#        kernel/extension/kpm/，本脚本按实际路径定位，不再写死）；
#   3) builtin 在 app 启动路径对管理器/授权应用 disable_seccomp()，
#      管理器首页 "Seccomp 状态" 显示"未启用"；改为对齐 main 分支/BakaSU
#      的过滤模式（保留 seccomp 过滤器 + action cache 放行 reboot）。
#
# 已由上游修复、本仓库随之移除的适配（核对 builtin 5ef32ad / main 31255c4）：
#   - arch.h 缺失：builtin 已自带 kernel/arch.h（与本仓库旧副本逐字节一致）
#   - EVENT_SERVICES 缺失 / rules.c 重复声明：builtin 已随 UAPI 6 同步修复
#   - pkg_observer 的 track_throne(TRACK_THRONE_FORCE_SYNCHRONOUS)：已改回 false
#   - supercall.h 的 KSU_IOCTL_KPM 笔误 / KSU_IOCTL_MANAGER 缺声明：
#     上游已把 KPM / MANAGER 等并入统一的 KSU_IOCTL_EXTENSION，旧常量不复存在
#   - throne_tracker 的 crown_manager 裸 return / pkg 作用域：上游已修正
#
# 修复均以内容检测守卫，上游自行修复后自动跳过，重复执行幂等。
#
# 用法: apply.sh [KernelSU 目录]（调用方工作目录需为 $KERNEL_ROOT）

set -eo pipefail

KSU_DIR="${1:-KernelSU}"

fail() {
  if [ "$SKIP_INCOMPATIBLE" = "true" ]; then
    echo "::warning title=SukiSU 兼容补丁已跳过::$1"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
      echo "" >> "$GITHUB_STEP_SUMMARY"
      echo "> ⏭️ **SukiSU API 兼容补丁** 已自动跳过：$1（构建未中断）" >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 0
  fi
  echo "::error::$1"
  exit 1
}

[ -d "$KSU_DIR" ] || fail "未找到 KernelSU 目录: $KSU_DIR"

COMPAT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LSM_FILE="$KSU_DIR/kernel/hook/lsm_hook.c"
if [ -f "$LSM_FILE" ] && grep -q 'security_add_hooks(ksu_hooks, ARRAY_SIZE(ksu_hooks), "ksu");' "$LSM_FILE"; then
  if grep -q 'ksu_lsm_id' "$LSM_FILE"; then
    echo "lsm_hook.c 已包含 lsm_id 兼容代码，跳过"
  else
    echo "应用 lsm_id 兼容补丁 (6.8+ security_add_hooks 新签名)..."
    patch -p1 --forward -d "$KSU_DIR" < "$COMPAT_DIR/sukisu-lsm-id-6.8.patch" \
      || fail "lsm_id 兼容补丁应用失败（SukiSU 上游代码可能已变化）"
    grep -q 'struct lsm_id ksu_lsm_id' "$LSM_FILE" \
      || fail "lsm_id 兼容补丁应用后校验失败"
    echo "lsm_hook.c: 6.8+ 已切换为 struct lsm_id 注册"
  fi
else
  echo "lsm_hook.c 不存在或无需 lsm_id 兼容补丁，跳过"
fi

# ---- cb_mutex（6.11+ 移除 netlink_kernel_cfg.cb_mutex）----
# 判据只看产物本身：DEFINE_MEMBER(netlink_kernel_cfg, cb_mutex) 这一行是否已经被
# 任意条件编译包住 —— 按 DYNAMIC_STRUCT_BEGIN/END(netlink_kernel_cfg) 块里的
# #if / #ifdef / #ifndef 与 #endif 深度判定，而不是认某个具体字符串。
#
# 为什么必须这么判：上游 SukiSU 自己治了这个问题，形态和我们旧补丁不同 ——
#   #ifdef KSU_NETLINK_CFG_HAS_CB_MUTEX
#   DEFINE_MEMBER(netlink_kernel_cfg, cb_mutex)
#   #endif
# 该宏由 kernel/Kbuild（main 分支）/ kernel/Makefile（builtin 分支）用 sed 直接
# 探测目标内核 include/linux/netlink.h 里有没有 cb_mutex 来决定，比按
# LINUX_VERSION_CODE 判更准（厂商 backport 时版本号会骗人）。
# 旧判据只认文件里有没有 "KERNEL_VERSION(6, 11, 0)" 这个串，于是把上游已经修好的
# 文件判成"还没守卫"，而旧补丁那 7 行连续 DEFINE_MEMBER 的上下文已被上游插进的
# #ifdef/#endif 打散 ⇒ patch 必然 Hunk #1 FAILED ⇒ fail ⇒ 整场内核构建中断
# （2026-11-05 CI 实测）。
#
# 注入同样只锚这一行本身，前后长什么样都不影响；产物与旧补丁逐字节相同。
# 重复执行幂等，上游自行修复后自动跳过。
sukisu_cb_mutex_guard_state() {
  # $1 = 目标文件；返回 0=已被条件编译守卫 1=裸露未守卫
  #             2=找不到 netlink_kernel_cfg 结构块 3=没有 cb_mutex 成员
  perl -e '
    open(my $fh, "<", $ARGV[0]) or exit 3;
    binmode $fh;
    my $t = do { local $/; <$fh> };
    close $fh;
    unless ($t =~ /DYNAMIC_STRUCT_BEGIN\(\s*netlink_kernel_cfg\s*\)(.*?)DYNAMIC_STRUCT_END\(\s*netlink_kernel_cfg\s*\)/s) {
      exit 2;
    }
    my ($depth, $found, $guarded) = (0, 0, 0);
    for my $line (split /\n/, $1) {
      $depth++   if $line =~ /^\s*#\s*(?:if|ifdef|ifndef)\b/;
      if ($line =~ /^\s*DEFINE_MEMBER\s*\(\s*netlink_kernel_cfg\s*,\s*cb_mutex\s*\)/) {
        $found = 1;
        $guarded = ($depth > 0);
      }
      $depth-- if $depth > 0 && $line =~ /^\s*#\s*endif\b/;
    }
    exit 3 unless $found;
    exit($guarded ? 0 : 1);
  ' "$1"
}

sukisu_cb_mutex_guard_inject() {
  # $1 = 目标文件；只在 cb_mutex 那一行前后加守卫，保留原行尾风格
  perl -e '
    open(my $fh, "<", $ARGV[0]) or exit 4;
    binmode $fh;
    my $t = do { local $/; <$fh> };
    close $fh;
    my @L = $t =~ /[^\r\n]*(?:\r?\n|\z)/gs;
    my $nl = (grep { /\r\n\z/ } @L) ? "\r\n" : "\n";
    my $i = -1;
    for my $k (0 .. $#L) {
      if ($L[$k] =~ /^[ \t]*DEFINE_MEMBER[ \t]*\([ \t]*netlink_kernel_cfg[ \t]*,[ \t]*cb_mutex[ \t]*\)[ \t]*(?:\r?\n)?\z/) {
        $i = $k;
        last;
      }
    }
    exit 4 if $i < 0;
    splice @L, $i + 1, 0, "#endif$nl";
    splice @L, $i,     0,
      "/* netlink_kernel_cfg.cb_mutex was removed in Linux 6.11 */$nl",
      "#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 11, 0)$nl";
    open(my $out, ">", $ARGV[0]) or exit 4;
    binmode $out;
    print $out join "", @L;
    close $out;
  ' "$1"
}

sukisu_cb_mutex_compat() {
  local ksu="$1" rel="" cand f st=0
  # 位置随上游重构迁移过（kernel/kpm/ -> kernel/extension/kpm/），按实际路径定位，
  # 避免守卫路径写死导致静默跳过（6.12 会因此直接编译失败）
  for cand in kernel/extension/kpm/super_access.c kernel/kpm/super_access.c; do
    if [ -f "$ksu/$cand" ]; then
      rel="$cand"
      break
    fi
  done
  if [ -z "$rel" ] && [ -d "$ksu/kernel" ]; then
    rel="$(cd "$ksu" && find kernel -type f -name super_access.c -path '*kpm*' 2>/dev/null | head -n 1)"
  fi
  if [ -z "$rel" ]; then
    echo "未找到 kpm/super_access.c，cb_mutex 兼容步骤跳过"
    return 0
  fi
  f="$ksu/$rel"

  sukisu_cb_mutex_guard_state "$f" || st=$?
  case "$st" in
    0)
      echo "$rel: cb_mutex 成员已被条件编译守卫（上游自行处理），跳过"
      # 上游这套守卫靠构建系统探测目标内核头文件来定义宏；探测一旦没了，
      # 6.11 以前的内核会静默丢掉 cb_mutex（能编过，只是 KPM 少一个成员）。
      if grep -q 'KSU_NETLINK_CFG_HAS_CB_MUTEX' "$f" \
        && ! grep -Rqs -- '-DKSU_NETLINK_CFG_HAS_CB_MUTEX' "$ksu/kernel/Kbuild" "$ksu/kernel/Makefile" 2>/dev/null; then
        echo "::warning title=cb_mutex 守卫宏无人定义::$rel 用 KSU_NETLINK_CFG_HAS_CB_MUTEX 守卫，但 kernel/Kbuild 与 kernel/Makefile 里都没有 -D 该宏，特性会被静默编掉（构建不中断）"
      fi
      return 0
      ;;
    3)
      echo "$rel 不含 netlink_kernel_cfg.cb_mutex 成员，无需兼容，跳过"
      return 0
      ;;
    2)
      echo "::warning title=cb_mutex 结构块未识别::$rel 里找不到 DYNAMIC_STRUCT_BEGIN/END(netlink_kernel_cfg)，不改文件、不中断构建"
      return 0
      ;;
    1) ;;
    *)
      echo "::warning title=cb_mutex 守卫状态未知::判据返回 $st，不改文件、不中断构建"
      return 0
      ;;
  esac

  echo "给 $rel 的 cb_mutex 成员加 6.11 版本守卫（按行锚定，不依赖上下文）..."
  sukisu_cb_mutex_guard_inject "$f" \
    || fail "cb_mutex 守卫注入失败（$rel 里那一行的形态不认识，SukiSU 上游代码可能又变了）"

  st=0
  sukisu_cb_mutex_guard_state "$f" || st=$?
  [ "$st" = 0 ] || fail "cb_mutex 守卫注入后校验失败（状态 $st）"
  grep -q 'KERNEL_VERSION(6, 11, 0)' "$f" \
    || fail "cb_mutex 注入后缺少 6.11 版本判据"
  echo "$rel: 6.11+ 已跳过 cb_mutex 成员"
}

sukisu_cb_mutex_compat "$KSU_DIR"

# ---- Seccomp 过滤模式（builtin 分支）----
# 背景：builtin 分支在 app 启动路径（zygote setresuid 钩子）对管理器与授权
# 应用直接调用 disable_seccomp()，管理器进程自身的 seccomp 过滤器被清除，
# 管理器首页 "Seccomp 状态" 显示"未启用"。main 分支 / BakaSU 的对应实现是
# 保留过滤器（"过滤模式"），仅通过 seccomp action cache（GKI 5.10+ backport）
# 放行 reboot。
# 处理：改写 lsm_hook.c 的 6 处 disable_seccomp() 调用点为 cache-allow 形式，
# 分发 infra/seccomp_cache.c/h 并在 ksu.c（上游重构后为 ksu_main.c）聚合编译；>=5.10 保留过滤器，
# <5.10 维持 disable_seccomp() 原行为（action cache 不存在）。
# 守卫：仅命中 builtin 的 handle_zygote_setresuid 时执行，main 分支自动跳过；
# 上游自行修复后幂等跳过。
if [ -f "$LSM_FILE" ] && grep -q 'handle_zygote_setresuid' "$LSM_FILE"; then
  if grep -q 'ksu_seccomp_allow_cache' "$LSM_FILE"; then
    echo "lsm_hook.c 已包含 seccomp 过滤模式逻辑，跳过"
  else
    echo "应用 seccomp 过滤模式补丁 (对齐 main 分支/BakaSU：管理器与授权应用保留 seccomp 过滤器)..."
    [ -d "$KSU_DIR/kernel/infra" ] || fail "未找到 $KSU_DIR/kernel/infra 目录，SukiSU builtin 结构可能已变化"
    cp "$COMPAT_DIR/seccomp_cache.h" "$KSU_DIR/kernel/infra/seccomp_cache.h" \
      || fail "seccomp_cache.h 分发失败"
    cp "$COMPAT_DIR/seccomp_cache.c" "$KSU_DIR/kernel/infra/seccomp_cache.c" \
      || fail "seccomp_cache.c 分发失败"
    python3 "$COMPAT_DIR/seccomp_filter_mode.py" "$KSU_DIR" \
      || fail "seccomp 过滤模式补丁应用失败（SukiSU builtin 上游代码可能已变化）"
    grep -q 'ksu_seccomp_allow_cache' "$LSM_FILE" \
      || fail "seccomp 过滤模式补丁应用后校验失败 (lsm_hook.c)"
    # 聚合编译文件随上游重构更名（kernel/ksu.c -> kernel/ksu_main.c），按实际路径校验
    KSU_AGG=""
    for cand in kernel/ksu.c kernel/ksu_main.c; do
      if [ -f "$KSU_DIR/$cand" ]; then
        KSU_AGG="$KSU_DIR/$cand"
        break
      fi
    done
    if [ -z "$KSU_AGG" ] || ! grep -q '#include "infra/seccomp_cache.c"' "$KSU_AGG"; then
      fail "seccomp 过滤模式补丁应用后校验失败 (聚合编译文件 ksu.c/ksu_main.c)"
    fi
    grep -q '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)' "$KSU_DIR/kernel/infra/seccomp_cache.c" \
      || fail "seccomp_cache.c 版本守卫校验失败"
    echo "seccomp 过滤模式已启用：管理器首页 Seccomp 状态将显示\"过滤模式\""
  fi
else
  echo "lsm_hook.c 无 builtin setresuid 路径（main 分支已内置过滤模式），跳过 seccomp 过滤模式补丁"
fi

echo "SukiSU API 兼容补丁处理完成"
