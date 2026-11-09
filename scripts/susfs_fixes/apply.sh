#!/usr/bin/env bash
# 应用 SUSFS 补丁及各内核版本所需的上下文修复
#
# 依赖环境变量：
#   ANDROID_VERSION KERNEL_VERSION KSU_VARIANT OS_PATCH_LEVEL SUB_LEVEL
#   KERNEL_ROOT SUSFS4KSU KERNEL_PATCHES LEGACY_SUKISU_CONFIG
# 调用前必须将工作目录设为 $KERNEL_ROOT
set -eo pipefail

echo "应用 SUSFS 补丁..."

SUSFS_PATCH="50_add_susfs_in_gki-$ANDROID_VERSION-$KERNEL_VERSION.patch"
cp "$SUSFS4KSU/kernel_patches/$SUSFS_PATCH" ./common/
cp "$SUSFS4KSU"/kernel_patches/fs/* ./common/fs/
cp "$SUSFS4KSU"/kernel_patches/include/linux/* ./common/include/linux/

case "$KSU_VARIANT" in
  "SukiSU"|"BakaSU"|"ReSukiSU")
    echo "SukiSU/BakaSU 使用内置 SUSFS 支持"
    ;;
esac

cd "$KERNEL_ROOT/common"
CURRENT_SUB="$SUB_LEVEL"
if [[ ! "$CURRENT_SUB" =~ ^[0-9]+$ ]]; then
  CURRENT_SUB=99999
fi

# ---- susfs4ksu R28 getpriority/priority uid filter 开关归一化 ----
# 该特性整套代码（含 susfs_switch_to_ksu_domain / susfs_restore_creds 两个辅助
# 函数）以 CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER 为开关，但 SukiSU(builtin)、
# BakaSU、FinaSU 的原生驱动 Kconfig 均未定义该选项，同时 SukiSU 驱动的
# supercall 分发（CMD_SUSFS_SET_PRIORITY_UID_FILTER）与 pkg_observer 无条件调用
# susfs_set_priority_uid_filter / susfs_parse_priority_app_strings，于是：
#   - susfs.c 的两个辅助函数失去唯一调用方，clang -Werror,-Wunused-function
#     直接中断编译（FinaSU/BakaSU/SukiSU 三个变体均复现）；
#   - susfs.h 中的声明被裁掉，SukiSU 驱动侧报 -Wimplicit-function-declaration。
# 把开关上提到 CONFIG_KSU_SUSFS（启用 SUSFS 时恒为 y）使特性完整可用。
# 仅改写预处理指令行：susfs.c 里 copy_config_to_buf() 的
# "CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER\n" 字符串字面量保持原样，管理器
# 仍能按原名识别该特性。
normalize_priority_uid_filter_guard() {
  local f
  # 主补丁中的 +#ifdef/+#endif 行（不触碰上下文行，hunk 行数不变，可正常应用）
  [[ -f "$SUSFS_PATCH" ]] \
    && sed -i -E '/^[+ ]*#[[:space:]]*(ifdef|ifndef|endif).*CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER/ s/CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER/CONFIG_KSU_SUSFS/' "$SUSFS_PATCH"
  # 已拷贝进内核树的源码与头文件
  for f in fs/susfs.c include/linux/susfs.h; do
    [[ -f "$f" ]] || continue
    sed -i -E '/^#[[:space:]]*(ifdef|ifndef|endif).*CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER/ s/CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER/CONFIG_KSU_SUSFS/' "$f"
  done
}

normalize_priority_uid_filter_guard
echo "已把 PRIORITY_UID_FILTER 开关归一化为 CONFIG_KSU_SUSFS"

# 兼容缺少 VMA padding 接口的 5.10.66～209、5.15.74～144 和 6.1.25～68
if grep -qF 'VMA_PAD_START(vma)' "$SUSFS_PATCH" \
  && ! grep -Rqs 'VMA_PAD_START' ./include/linux; then
  echo "目标内核未提供 VMA_PAD_START，使用 vma->vm_end 兼容 SUSFS OPEN_REDIRECT"
  sed -i 's/VMA_PAD_START(vma)/vma->vm_end/g' "$SUSFS_PATCH"
fi

# ---- 补丁的 fs/namespace.c 第一个 hunk 要求一行目标内核没有的 include ----
# 2026-10-19 起 SUSFS 把 `#include <trace/hooks/blk.h>` 当 fs/namespace.c 第一个
# hunk 的上下文行（要求存在）。6.1.157 的源里有这一行、树里也有该头文件；而
# 6.1.57 这类旧子版本**连 include/trace/hooks/blk.h 这个文件都没有**（已实测
# android14-6.1-2024-01_r24 为 404）—— 没法"给内核补上 include"，只能让它别要求。
# 不做的话该 hunk 整个被拒：susfs_def.h、CL_COPY_MNT_NS 和那几个 extern 全丢，
# 编译报一堆 use of undeclared identifier，而报错点还落在 namespace.c 的**使用处**，
# 看着像 namespace.c 坏了（真因在补丁与内核的头文件差）。
# 只按内容判断：补丁里有这行、且目标树没有该头文件，才动手；目标树有该头文件
# （＝那行本来就在）时补丁一个字不动，幂等。
susfs_patch_drop_blk_h_context() {
  if ! grep -qF ' #include <trace/hooks/blk.h>' "$SUSFS_PATCH"; then
    echo "SUSFS 补丁不含 trace/hooks/blk.h 上下文行，跳过"
    return 0
  fi
  if [ -f ./include/trace/hooks/blk.h ]; then
    echo "目标内核已有 include/trace/hooks/blk.h，补丁上下文可用，保留不动"
    return 0
  fi
  echo "目标内核无 include/trace/hooks/blk.h：从 SUSFS 补丁去掉该上下文行并修正 hunk 行数"
  # 删掉那行上下文后，该 hunk 头部的两侧行数要各减 1，否则 patch 认为补丁畸形。
  # 只改「包含该行的那一个 hunk」，其余 hunk 不动。
  perl -0777 -i -pe '
    my @L = split /(?<=\n)/, $_;
    my ($hdr, @n);
    for my $i (0 .. $#L) {
      if ($L[$i] =~ /^\@\@ /) {
        if ($L[$i] =~ /^\@\@ -(\d+),(\d+) \+(\d+),(\d+) \@\@/) { $hdr = $i; @n = ($1, $2, $3, $4); }
        else { $hdr = undef; }
        next;
      }
      next unless $L[$i] eq " #include <trace/hooks/blk.h>\n";
      die "blk.h 上下文行不在任何 hunk 内\n" unless defined $hdr;
      (my $tail = $L[$hdr]) =~ s/^\@\@ -\d+,\d+ \+\d+,\d+ \@\@//;
      $L[$hdr] = sprintf("\@\@ -%d,%d +%d,%d \@\@%s", $n[0], $n[1] - 1, $n[2], $n[3] - 1, $tail);
      splice @L, $i, 1;
      last;
    }
    $_ = join "", @L;
  ' "$SUSFS_PATCH" || { echo "::error::从 SUSFS 补丁去掉 blk.h 上下文行失败" >&2; exit 1; }
  if grep -qF ' #include <trace/hooks/blk.h>' "$SUSFS_PATCH"; then
    echo "::error::SUSFS 补丁里仍残留 blk.h 上下文行" >&2
    exit 1
  fi
  echo "SUSFS 补丁：blk.h 上下文行已去掉（hunk 行数同步修正）"
}
susfs_patch_drop_blk_h_context

adjust_legacy_fdinfo_context() {
  sed -i '/^[[:space:]]*\/\*$/,/^[[:space:]]*u32 mask = mark->mask & IN_ALL_EVENTS;$/d' fs/notify/fdinfo.c
  perl -i -pe 's/\bmask,\s*mark->ignored_mask/inotify_mark_user_mask(mark)/g' fs/notify/fdinfo.c
  perl -i -pe 's/ignored_mask:%x/ignored_mask:0/g' fs/notify/fdinfo.c
}

restore_legacy_fdinfo_context() {
  perl -i -pe 's/^(\s+if \(inode\) \{)/$1\n\t\t\/\*\n\t\t * IN_ALL_EVENTS represents all of the mask bits\n\t\t * that we expose to userspace.  There is at\n\t\t * least one bit (FS_EVENT_ON_CHILD) which is\n\t\t * used only internally to the kernel.\n\t\t *\/\n\t\tu32 mask = mark->mask & IN_ALL_EVENTS;/m' fs/notify/fdinfo.c
  perl -i -pe 's/\binotify_mark_user_mask\(mark\)/mask, mark->ignored_mask/g' fs/notify/fdinfo.c
  perl -i -pe 's/ignored_mask:0/ignored_mask:%x/g' fs/notify/fdinfo.c
}

# 临时调整旧内核源码上下文，使 SUSFS 主补丁可以匹配
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le 43 ]]; then
    echo "临时调整 Android 12 5.10 base.c 上下文"
    perl -i -pe 's/(int|size_t)\s+this_len\s*=\s*min_t\s*\(\s*\1\s*,/size_t this_len = min_t(size_t,/;' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 117 ]]; then
    echo "临时调整 Android 12 5.10 fdinfo.c 上下文"
    adjust_legacy_fdinfo_context
  fi
fi

if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  if [[ "$CURRENT_SUB" -le 41 ]]; then
    echo "临时调整 Android 13 5.15 namespace.c/open.c/fdinfo.c 上下文"
    if ! grep -qF '#include <linux/mnt_idmapping.h>' fs/namespace.c; then
      sed -i '/^#include <linux\/shmem_fs.h>$/a #include <linux/mnt_idmapping.h>' fs/namespace.c
    fi
    if ! grep -qF '#include <linux/mnt_idmapping.h>' fs/open.c; then
      sed -i '/^#include <linux\/compat.h>$/a #include <linux/mnt_idmapping.h>' fs/open.c
    fi
    adjust_legacy_fdinfo_context
  fi
  if [[ "$OS_PATCH_LEVEL" == "lts" ]]; then
    echo "临时调整 Android 13 5.15 LTS 头文件上下文"
    # 只有当补丁不要求这行时才删：2026-10-19 起补丁把 `#include <trace/hooks/blk.h>`
    # 当 namespace.c hunk 的上下文行（要求存在），删掉会让 hunk 失配。
    if grep -q '^ #include <trace/hooks/blk\.h>' "$SUSFS_PATCH"; then
      echo "SUSFS 补丁要求保留 namespace.c 的 trace/hooks/blk.h，跳过该临时调整"
    else
      sed -i '/^#include <trace\/hooks\/blk.h>$/d' fs/namespace.c
      LTS_BLK_H_DELETED=1
    fi
    sed -i '/^#include <trace\/hooks\/mm.h>$/d' fs/proc/task_mmu.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  if [[ "$CURRENT_SUB" -le 25 ]] && ! grep -qF '#include <trace/hooks/sched.h>' fs/proc/base.c; then
    echo "临时调整 Android 14 6.1 sched.h 上下文"
    sed -i '/^#include <trace\/events\/oom.h>$/a #include <trace/hooks/sched.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 141 ]] && ! grep -qF '#include <linux/dma-buf.h>' fs/proc/base.c; then
    echo "临时调整 Android 14 6.1 dma-buf.h 上下文"
    sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -ge 157 ]]; then
    # 只有当补丁不要求这个 include 时才删：2026-10-19 起的 SUSFS 补丁把
    # `#include <trace/hooks/blk.h>` 当作 fs/namespace.c hunk 的上下文行
    # （要求它存在），照旧删掉会让 hunk 失配 → 产生 fs/namespace.c.rej。
    if grep -q '^ #include <trace/hooks/blk\.h>' "$SUSFS_PATCH"; then
      echo "SUSFS 补丁要求保留 namespace.c 的 trace/hooks/blk.h，跳过该临时调整"
    else
      echo "临时调整 Android 14 6.1 namespace.c 上下文"
      sed -i '/^#include <trace\/hooks\/blk.h>$/d' fs/namespace.c
    fi
  fi
fi

if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  if [[ "$CURRENT_SUB" -le 92 ]] && ! grep -qF '#include <linux/dma-buf.h>' fs/proc/base.c; then
    echo "临时调整 Android 15 6.6 base.c 上下文"
    sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 57 ]] && ! grep -qF '#include <linux/zswap.h>' mm/memory.c; then
    echo "临时调整 Android 15 6.6 memory.c 上下文"
    sed -i '/^#include <linux\/sched\/sysctl.h>$/a #include <linux/zswap.h>' mm/memory.c
  fi
fi

# 新版内核在 super.c 的 internal.h 之后新增了 trace/hooks/fs.h，
# 旧版 SUSFS 主补丁以 thaw_super_locked 为上下文插入 extern 声明，会整段被拒绝；
# 上游 2026-09-15 起已把声明挪到 unnamed_dev_ida 之后，不再依赖这段上下文，
# 但 ShirkNeko fork 尚未同步（固定提交的旧版补丁不改 super.c），只对旧版补丁做临时调整
SUPER_FS_H_REMOVED=""
if grep -q '^ static int thaw_super_locked' "$SUSFS_PATCH" \
  && grep -qF '#include <trace/hooks/fs.h>' fs/super.c; then
  echo "临时调整 super.c 上下文"
  sed -i '/^#include <trace\/hooks\/fs.h>$/,+1d' fs/super.c
  SUPER_FS_H_REMOVED=1
fi

patch -p1 < "$SUSFS_PATCH" || true

# ---- 预期冲突处理：上游已包含同款修改的 .rej 剔除，真实缺失的手工补齐 ----

# 1) fs/unicode：ASB 内核已包含上游 "unicode: don't special case ignorable code
#    points" 提交，主补丁删除 ignore_init / 重生成 utf8data 的 hunk 已天然满足
if [[ -f fs/unicode/mkutf8data.c.rej ]] && ! grep -q 'ignore_init' fs/unicode/mkutf8data.c; then
  echo "fs/unicode .rej 为上游已包含同款修改，剔除预期冲突文件"
  rm -f fs/unicode/*.rej
fi

# 2) mm/rmap.c：6.6.127+ 已包含 huge_pmd_unshare 的 tlb 化改造
if [[ -f mm/rmap.c.rej ]] && grep -q 'tlb_gather_mmu_vma' mm/rmap.c; then
  echo "mm/rmap.c .rej 为上游已包含同款修改，剔除预期冲突文件"
  rm -f mm/rmap.c.rej
fi

# 为尚未提供 SU 会话 FD 接口的 SukiSU/BakaSU 恢复旧版 exec hook 行为
EXEC_HELPER=""
if [[ "$KSU_VARIANT" == SukiSU* || "$KSU_VARIANT" == "BakaSU" || "$KSU_VARIANT" == "ReSukiSU" ]]; then
  if grep -qF 'ksu_install_su_fd();' fs/exec.c; then
    EXEC_HELPER="ksu_install_su_fd"
  elif grep -qF 'ksu_handle_post_execveat_sucompat(' fs/exec.c; then
    EXEC_HELPER="ksu_handle_post_execveat_sucompat"
  fi
fi
if [[ -n "$EXEC_HELPER" ]] \
  && ! grep -RqsE --include='*.c' "^[[:space:]]*int[[:space:]]+${EXEC_HELPER}[[:space:]]*\(" "$KERNEL_ROOT/KernelSU/kernel"; then
  echo "$KSU_VARIANT 尚未提供 $EXEC_HELPER，恢复旧版 exec hook"
  sed -i '/^extern int ksu_install_su_fd(void);$/d' fs/exec.c
  sed -i '/^extern int ksu_handle_post_execveat_sucompat(/,+1d' fs/exec.c
  sed -i 's/is_su_session = !\(ksu_handle_execveat[^;]*;\)/\1/' fs/exec.c
  sed -i '/^[[:space:]]*bool is_su_session = false;$/d' fs/exec.c
  sed -i '/^[[:space:]]*if (unlikely(is_su_session && retval >= 0))$/,+1d' fs/exec.c
  sed -i '/^[[:space:]]*if (unlikely(is_su_session))$/,+1d' fs/exec.c
  sed -i '/^#ifdef CONFIG_KSU_SUSFS$/N;/^#ifdef CONFIG_KSU_SUSFS\n#endif \/\/ #ifdef CONFIG_KSU_SUSFS$/d' fs/exec.c
  if grep -qE 'ksu_install_su_fd|ksu_handle_post_execveat_sucompat|is_su_session' fs/exec.c; then
    echo "::error::$KSU_VARIANT exec hook 结构已变化，无法完成兼容修复"
    exit 1
  fi
fi

# 上游 5.10 主补丁把 susfs_sus_kstat_spoof_vfs_statfs 的 extern 声明放在了
# fs/statfs.c 的使用点之后（vfs_statfs 之前），clang -Werror 报隐式声明；
# 声明属于 SUSFS 接口，直接补进公共头 include/linux/susfs_def.h：
# 不依赖 statfs.c 内锚点与行号比较，声明重复合法，上游后续自行修复也不冲突
SUSFS_DEF_H="$KERNEL_ROOT/common/include/linux/susfs_def.h"
if [[ -f fs/statfs.c ]] && grep -qF 'susfs_sus_kstat_spoof_vfs_statfs(' fs/statfs.c \
  && [[ -f "$SUSFS_DEF_H" ]] \
  && ! grep -qF 'susfs_sus_kstat_spoof_vfs_statfs(' "$SUSFS_DEF_H"; then
  echo "将 susfs_sus_kstat_spoof_vfs_statfs 声明补入 include/linux/susfs_def.h"
  sed -i '/^#endif \/\/ #ifndef KSU_SUSFS_DEF_H$/i extern int susfs_sus_kstat_spoof_vfs_statfs(struct inode *inode, struct kstatfs *buf, bool *is_fuse);' "$SUSFS_DEF_H"
fi

# 上游 susfs.c 直接调用 security_sb_statfs 却没有包含 linux/security.h，
# 5.15+ 靠其他头文件间接带入，5.10 没有这条路径，clang -Werror 报隐式声明；缺失时补上
if [[ -f fs/susfs.c ]] && grep -qF 'security_sb_statfs(' fs/susfs.c \
  && ! grep -qF '#include <linux/security.h>' fs/susfs.c; then
  echo "为 susfs.c 补充 linux/security.h 头文件"
  sed -i '0,/^#include <linux\/fs.h>$/s//#include <linux\/fs.h>\n#include <linux\/security.h>/' fs/susfs.c
fi

# 在编译前报告 SUSFS 主补丁产生的冲突文件
SUSFS_REJ_COUNT=$(find . -name '*.rej' | wc -l)
if [ "$SUSFS_REJ_COUNT" -gt 0 ]; then
  echo "::warning title=SUSFS 补丁冲突::SUSFS 主补丁产生了 ${SUSFS_REJ_COUNT} 个 .rej 冲突文件，可能导致后续编译失败（详见 Rejects 产物）"
  find . -name '*.rej' -print
fi

# 还原仅用于补丁匹配的临时源码调整
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le 43 ]]; then
    echo "还原 Android 12 5.10 base.c 临时调整"
    sed -i 's/^size_t this_len = min_t(size_t, count, PAGE_SIZE);$/int this_len = min_t(int, count, PAGE_SIZE);/' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 117 ]]; then
    echo "还原 Android 12 5.10 fdinfo.c 临时调整"
    restore_legacy_fdinfo_context
  fi
fi

if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  if [[ "$CURRENT_SUB" -le 41 ]]; then
    echo "还原 Android 13 5.15 临时调整"
    sed -i '/#include <linux\/mnt_idmapping.h>$/d' fs/namespace.c
    sed -i '/#include <linux\/mnt_idmapping.h>$/d' fs/open.c
    restore_legacy_fdinfo_context
    sed -i 's|i_uid_into_mnt(i_user_ns(&fi->inode), &fi->inode).val|i_uid_into_mnt(\&init_user_ns, \&fi->inode).val|g' fs/susfs.c
    sed -i 's|i_uid_into_mnt(i_user_ns(inode), inode).val|i_uid_into_mnt(\&init_user_ns, inode).val|g' fs/susfs.c
  fi
  if [[ "$OS_PATCH_LEVEL" == "lts" ]]; then
    echo "还原 Android 13 5.15 LTS 头文件上下文"
    if [ "${LTS_BLK_H_DELETED:-0}" = "1" ] && ! grep -qF '#include <trace/hooks/blk.h>' fs/namespace.c; then
      sed -i '/^#include "internal.h"$/a #include <trace/hooks/blk.h>' fs/namespace.c
    fi
    if ! grep -qF '#include <trace/hooks/mm.h>' fs/proc/task_mmu.c; then
      sed -i '/^#include <linux\/pkeys.h>$/a #include <trace/hooks/mm.h>' fs/proc/task_mmu.c
    fi
  fi
fi

if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  if [[ "$CURRENT_SUB" -le 25 ]]; then
    sed -i '/^#include <trace\/hooks\/sched.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 141 ]]; then
    echo "还原 Android 14 6.1 base.c 临时调整"
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -ge 157 ]] && ! grep -qF '#include <trace/hooks/blk.h>' fs/namespace.c; then
    echo "还原 Android 14 6.1 namespace.c 临时调整"
    sed -i '/^#include "internal.h"$/a #include <trace/hooks/blk.h>' fs/namespace.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  if [[ "$CURRENT_SUB" -le 92 ]]; then
    echo "还原 Android 15 6.6 base.c 临时调整"
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 57 ]]; then
    echo "还原 Android 15 6.6 memory.c 临时调整"
    sed -i '/^#include <linux\/zswap.h>$/d' mm/memory.c
  fi
fi

if [[ -n "$SUPER_FS_H_REMOVED" ]] \
  && ! grep -qF '#include <trace/hooks/fs.h>' fs/super.c; then
  echo "还原 super.c 临时调整"
  sed -i '/^#include "internal.h"$/a #include <trace/hooks/fs.h>' fs/super.c
fi

fix_missing_vm_flags_clear() {
  if [[ "$OS_PATCH_LEVEL" == "2024-11" ]] && grep -qF 'vm_flags_clear(new_vma, VM_PAD_MASK);' ./mm/mmap.c; then
    sed -i 's/vm_flags_clear(new_vma, VM_PAD_MASK);/new_vma->vm_flags \&= ~VM_PAD_MASK;/' ./mm/mmap.c
  fi
}

fix_task_mmu_show_pad() {
  local max_sub="$1"
  local excluded_patch_level="${2:-}"

  # 仅固定旧版 SUSFS 补丁会引入 goto show_pad，最新版已不再包含该代码
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le "$max_sub" ]] \
    && { [[ -z "$excluded_patch_level" ]] || [[ "$OS_PATCH_LEVEL" != "$excluded_patch_level" ]]; }; then
    sed -i -e 's/goto show_pad;/return 0;/' ./fs/proc/task_mmu.c
  fi
}

# Android 12 - 5.10 修复
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  # 修复 2024-11 分支: mmap.c 调用了 vm_flags_clear()，但同分支 mm.h 未提供 helper
  fix_missing_vm_flags_clear
  fix_task_mmu_show_pad 209
fi

# Android 13 - 5.15 修复
  if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  # 修复 2024-11 分支: mmap.c 调用了 vm_flags_clear()，但同分支 mm.h 未提供 helper
  fix_missing_vm_flags_clear
  fix_task_mmu_show_pad 148 "2024-05"
fi

# Android 14 - 6.1 修复
if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  fix_task_mmu_show_pad 75 "2024-05"
fi

# Android 15 - 6.6 修复
if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  # 修复老版 SukiSU 6.6.50~6.6.58: task_mmu.c 打入 SUSFS 后使用 vma，但旧源码没有对应声明
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -ge 50 && "$CURRENT_SUB" -le 58 ]] \
    && grep -qF 'vma = find_vma(mm, start_vaddr);' ./fs/proc/task_mmu.c; then
    TASK_MMU_PATCH="$KERNEL_PATCHES/wild/archived/susfs_fix_patches/v2.1.0/a15-6.6/task_mmu.c.patch"
    if [ ! -f "$TASK_MMU_PATCH" ]; then
      echo "::error::补丁不存在: $TASK_MMU_PATCH"
      exit 1
    fi
    cp "$TASK_MMU_PATCH" ./
    if patch -p1 --dry-run < task_mmu.c.patch >/dev/null 2>&1; then
      patch -p1 --no-backup-if-mismatch < task_mmu.c.patch
      echo "已应用 Android 15 6.6.50~6.6.58 task_mmu.c 归档修复补丁"
    else
      echo "Android 15 6.6.50~6.6.58 task_mmu.c 归档修复补丁已应用或当前上下文不匹配，跳过"
    fi
  fi
fi

###############################################################################
# SELinux hide 兼容
#
# 历史：一度认为 SUSFS/KSU 的 selinux_hide 是「backup_sepolicy + 8 参
# *_with_policy + 手动 hook(should_check_current)」的新形态，与旧内核源码组合会
# 编译报错或运行时 panic，于是按内核版本分了两条硬阻断（<6.6 缺
# should_check_current、>=6.6 缺 *_with_policy）。
#
# 这两条的前提已经作废：上游 SUSFS 在 2026-10-19 的 f6c046775「kernel &
# KernelSU: Reuse upstream selinux_hide existing code」（其后 b57ed1998 同步官方
# KernelSU）改成复用上游既有实现 —— 现补丁里 should_check_current 与
# _with_policy 出现次数都是 0，KSU 源码也不再引用它们。再留着就会把 6.1/6.6
# 的构建无理由拦下（症状＝「缺少 should_check_current」/「需要二改的
# *_with_policy」两条 ::error）。
#
# 现在只保留仍然成立的一条：<6.6 时 KSU 侧若「引用了旧版 fake_state 却没有定义」
# （同步上游时被一并删掉），就地补回定义；其余交给编译器判断。
###############################################################################
selinux_hide_compat() {
  local ksu_dirs="$KERNEL_ROOT/common/drivers/kernelsu $KERNEL_ROOT/KernelSU"
  local hide_file ge66=false
  hide_file=$(grep -Rls 'ksu_selinux_hide_running' $ksu_dirs 2>/dev/null | head -n 1 || true)
  if [ -z "$hide_file" ]; then
    echo "SELinux hide 兼容：KSU 侧未启用 selinux_hide，跳过"
    return 0
  fi
  echo "SELinux hide 兼容：KSU 侧实现 = ${hide_file#"$KERNEL_ROOT"/}"

  if [ "$(printf '%s\n6.6\n' "$KERNEL_VERSION" | sort -V | head -n 1)" = "6.6" ]; then
    ge66=true
  fi

  if [ "$ge66" = false ] \
    && grep -q 'fake_state' "$hide_file" \
    && ! grep -qE '^[[:space:]]*(static[[:space:]]+)?struct selinux_state[[:space:]]+fake_state' "$hide_file"; then
    echo "SELinux hide 兼容：<6.6 缺少旧版 fake_state 定义，按上游思路就地补回"
    awk 'NR==FNR { if ($0 ~ /^#include/) last=NR; next }
         { print; if (FNR==last && !done) { print "static struct selinux_state fake_state;"; done=1 } }' \
      "$hide_file" "$hide_file" > "$hide_file.tmp"
    mv "$hide_file.tmp" "$hide_file"
    if ! grep -qE '^static struct selinux_state fake_state;' "$hide_file"; then
      echo "::error::补回 fake_state 定义失败（$hide_file）" >&2
      exit 1
    fi
    echo "SELinux hide 兼容：已补回 static struct selinux_state fake_state;"
  else
    echo "SELinux hide 兼容：无需处理（$KERNEL_VERSION，fake_state 不适用或无需补回）"
  fi
}
selinux_hide_compat

# ---- 上游 BakaSU 的硬失败放行 ----
# kernel/tools/susfs_compat.mk 末尾目前无条件写着
#   $(info -- $(REPO_NAME): susfs has NOT update with latest KernelSU source)
#   $(info -- $(REPO_NAME): Please wait simonpunk update)
#   $(error Please wait susfs update.)
# 于是所有构建都在等 simonpunk 更新 SUSFS 之前无法通过。按上游给出的修复思路自行放行：
# 该文件上面的 KSU_COMPAT_* 宏仍按源码自动探测（不改动其判断），版本相关的兼容规则由
# 上面的 selinux_hide_compat 负责（<6.6 缺 should_check_current 阻断、>=6.6 需二改
# 的 *_with_policy、<6.6 补回旧版 fake_state），所以这里仅摘掉那句无条件硬失败。
susfs_compat_unblock() {
  local mk=""
  local cand
  for cand in "$KERNEL_ROOT/KernelSU/kernel/tools/susfs_compat.mk" \
              "$KERNEL_ROOT/common/drivers/kernelsu/kernel/tools/susfs_compat.mk"; do
    if [ -f "$cand" ]; then mk="$cand"; break; fi
  done
  if [ -z "$mk" ]; then
    echo "SUSFS compat：未找到 susfs_compat.mk（该分支可能不含此检查），跳过"
    return 0
  fi
  if grep -q '^\$(error' "$mk"; then
    echo "SUSFS compat：移除上游硬编码的 \$(error Please wait susfs update.)（按上游修复思路自行放行）"
    sed -i '/^\$(error/d' "$mk"
    if grep -q '^\$(error' "$mk"; then
      echo "::error::移除 $mk 里的硬失败失败" >&2
      exit 1
    fi
    grep -n 'KSU_COMPAT_HAS_SUSFS_FEATURE_SELINUX_HIDE\|KSU_COMPAT_HAS_SUSFS_INSTALL_SU_FD_DIRECT_CALL' "$mk" | head -4
  else
    echo "SUSFS compat：susfs_compat.mk 已无硬失败，跳过"
  fi
}
susfs_compat_unblock

# ---- builtin 的 track_throne 实参错配（新调用方 + 旧 bool 形参）----
# builtin 的 manager/pkg_observer.c（PR #3871 引入，c8959206）两处以
#   track_throne(TRACK_THRONE_FORCE_SYNCHRONOUS)
# 调用，但 TRACK_THRONE_FORCE_SYNCHRONOUS 是 BakaSU 那套
#   void track_throne(unsigned int flags)   （throne_tracker.h 里 #define (1 << 2)）
# 位标志 API 的宏，builtin 从未定义过它；builtin 的 throne_tracker.c/.h 仍是旧 API
#   void track_throne(bool prune_only)
# 且函数一开头就是 `if (prune_only) goto prune;`（只剪 allowlist，不做管理器加冕扫描）。
# 注意：直接用内核的 PROBE_FORCE_SYNCHRONOUS 当替身虽然能编过，但它是
# include/linux/device.h 的驱动 probe 枚举（PROBE_DEFAULT_STRATEGY=0、
# PROBE_PREFER_ASYNCHRONOUS=1、PROBE_FORCE_SYNCHRONOUS=2，非 0）——等于永远传
# prune_only=true，管理器永远不会被加冕，is_manager() 恒 false，管理器拿不到 root
# （表现为「管理器没权限」、修补 boot/LKM 也失败）。main 分支同一调用点写的就是
# track_throne(false)（false = 全量扫描），builtin 的 fsnotify 路径同样需要全量扫描，
# 依此替换；上游若把 flags 版 API 带进 builtin（树内 #define 了该宏）则自动跳过。
ksu_track_throne_compat() {
  local roots=("$KERNEL_ROOT/KernelSU" "$KERNEL_ROOT/common/drivers/kernelsu")
  local pat='track_throne(TRACK_THRONE_FORCE_SYNCHRONOUS)'
  local files n
  files=$(grep -RFl "$pat" "${roots[@]}" 2>/dev/null || true)
  if [ -z "$files" ]; then
    echo "KSU track_throne 兼容：树内无 \"$pat\" 调用，跳过"
    return 0
  fi

  if grep -RqsE '^[[:space:]]*#[[:space:]]*define[[:space:]]+TRACK_THRONE_FORCE_SYNCHRONOUS' \
       "${roots[@]}" 2>/dev/null; then
    echo "KSU track_throne 兼容：树内已定义 TRACK_THRONE_FORCE_SYNCHRONOUS（flags 版 API 已就位），保持原样"
    return 0
  fi

  echo "KSU track_throne 兼容：把 \"$pat\" 换成 track_throne(false)（旧 API 下 false=全量扫描）"
  local f
  for f in $files; do
    sed -i 's/track_throne(TRACK_THRONE_FORCE_SYNCHRONOUS)/track_throne(false)/g' "$f"
  done

  # 写后校验：调用残留必须清零，且替换结果确实存在
  n=$(grep -RFl "$pat" "${roots[@]}" 2>/dev/null | wc -l || true)
  if [ "$n" -ne 0 ]; then
    echo "::error::替换 TRACK_THRONE_FORCE_SYNCHRONOUS 失败（仍有 $n 个文件含该调用）" >&2
    exit 1
  fi
  if ! grep -Rqs 'track_throne(false)' "${roots[@]}" 2>/dev/null; then
    echo "::error::替换后未找到 track_throne(false)，请人工核对 manager/pkg_observer.c" >&2
    exit 1
  fi
  echo "KSU track_throne 兼容：已替换为 track_throne(false)（恢复管理器加冕扫描）"
}
ksu_track_throne_compat

# ---- SukiSU builtin 的 dynamic manager ioctl 标识符合并残留 ----
# 上游 builtin 把 main 的 dynamic manager 移植过来时，uapi/supercall.h 里 106 号
# ioctl 那一行漏改（main 用的是 KSU_IOCTL_MANAGER）：
#   DECLARE(__u32, KSU_IOCTL_KPM, _IOWR('K', 106, ksu_manager_cmd));
# 这一行有两个缺陷：
#   1) 标识符仍叫 KSU_IOCTL_KPM，与同一文件里 200 号的真正 KPM ioctl 重名 ——
#      enum 里出现重复 enumerator，编译必报错；
#   2) 类型漏了 struct 关键字（树里没有 ksu_manager_cmd 的 typedef）——
#      clang 报 error: use of undeclared identifier 'ksu_manager_cmd'。
# 而 kernel/supercall/dispatch.c 的 do_manager 注册用的是 KSU_IOCTL_MANAGER，
# 于是这个被使用的名字在头文件里从未被声明。注意 manager.h / dynamic_manager.c
# 在 builtin 与 main 里逐字节相同（且已由 ksu.c 引入），不需要从 main 搬文件，
# 只要让 KSU_IOCTL_MANAGER 恰好被声明一次。上游对此先后出现过三种状态，都要认：
#   形态 A（a233901 起、c95d6e2 止）：那行还在，但标识符写成 KSU_IOCTL_KPM 且缺
#     struct —— 就地改名并补 struct；
#   形态 B（0af2cf9 起）：上游只把那行删掉（消掉了重名错误），dispatch.c 仍在引用
#     KSU_IOCTL_MANAGER —— 按 main 在 KSU_IOCTL_KPM(200) 之前补回规范声明；
#   形态 C（5ef32ad 起）：整批 per-feature ioctl 合并成单个 KSU_IOCTL_EXTENSION，
#     旧名只剩注释 —— 无需处理（判据只取头文件，全树 grep 会命中注释而误判）。
# 上游修正后本步骤按内容检测自动跳过。
ksu_manager_ioctl_compat() {
  local candidates=(
    "$KERNEL_ROOT/KernelSU/kernel/include/uapi/supercall.h"
    "$KERNEL_ROOT/common/drivers/kernelsu/include/uapi/supercall.h"
    "$KERNEL_ROOT/KernelSU/uapi/supercall.h"
    "$KERNEL_ROOT/common/drivers/kernelsu/uapi/supercall.h"
  )
  local uapi="" cand
  for cand in "${candidates[@]}"; do
    if [ -f "$cand" ]; then uapi="$cand"; break; fi
  done
  if [ -z "$uapi" ]; then
    echo "KSU manager ioctl 兼容：未找到 uapi/supercall.h（该分支布局可能已变化），跳过"
    return 0
  fi

  # DECLARE(__u32, NAME, ...) 与 static const __u32 NAME = ... 两种声明形态都认
  if grep -qE '\bKSU_IOCTL_MANAGER\b[[:space:]]*[=,]' "$uapi"; then
    echo "KSU manager ioctl 兼容：$uapi 已声明 KSU_IOCTL_MANAGER，跳过"
    return 0
  fi

  # 上游 5ef32ad（2026-10-19）起把这批 per-feature ioctl（KPM / MANAGER /
  # ADD_TRY_UMOUNT / LIST_TRY_UMOUNT / SET_SPOOF_CPU / ENABLE_KPM …）合并成单个
  # KSU_IOCTL_EXTENSION（kernel/include/uapi/extension.h，nr 300），旧名只留在
  # 注释里说明历史 —— 既没有 200 号 KPM 行可依，也没有真实引用，直接跳过。
  # 判据只看头文件：不能拿"全树 grep 到 KSU_IOCTL_MANAGER"当引用判据，那会命中注释。
  if ! grep -qE '\bKSU_IOCTL_KPM\b' "$uapi"; then
    echo "KSU manager ioctl 兼容：$uapi 已无 KSU_IOCTL_KPM（上游改用 KSU_IOCTL_EXTENSION），跳过"
    return 0
  fi

  local SHAPE=""
  echo "KSU manager ioctl 兼容：$uapi 缺 KSU_IOCTL_MANAGER 声明，补正"

  if grep -qE '\bKSU_IOCTL_[A-Z0-9_]+\b.*\bksu_manager_cmd\b' "$uapi"; then
    SHAPE=A
    # 形态 A：只动“同一行里既有 KSU_IOCTL_* 标识符、又出现 ksu_manager_cmd”的那一行，
    # 即 106 号 ioctl 的声明行；不锚定行尾，兼容 CRLF 检出。
    perl -i -pe '
      next unless /\bKSU_IOCTL_[A-Z0-9_]+\b/ && /\bksu_manager_cmd\b/;
      s/(?<!struct )\bksu_manager_cmd\b/struct ksu_manager_cmd/g;
      s/\bKSU_IOCTL_[A-Z0-9_]+\b/KSU_IOCTL_MANAGER/;
    ' "$uapi"
  else
    SHAPE=B
    # 形态 B：那行已被上游删掉，在 KSU_IOCTL_KPM 的 200 号声明之前插入规范声明，
    # 顺序与 main 的 uapi/supercall.h 一致（MANAGER 在 KPM 之前）。行尾跟随原文件。
    perl -0777 -i -pe '
      my $q = chr(39);
      my $nl = /\r\n/ ? "\r\n" : "\n";
      my $decl = "DECLARE(__u32, KSU_IOCTL_MANAGER, _IOWR(${q}K${q}, 106, struct ksu_manager_cmd));";
      s{^(.*DECLARE\(__u32, KSU_IOCTL_KPM,.*\b200\b.*)$}{$decl . $nl . $1}me;
    ' "$uapi"
  fi

  # 写后校验：MANAGER/KPM 各自恰好一个定义，且 106 号行带上 struct 关键字
  local mgr_count kpm_count
  mgr_count=$(grep -cE '\bKSU_IOCTL_MANAGER\b[[:space:]]*[=,]' "$uapi" || true)
  kpm_count=$(grep -cE '\bKSU_IOCTL_KPM\b[[:space:]]*[=,]' "$uapi" || true)
  if [ "$mgr_count" != "1" ] || [ "$kpm_count" != "1" ] \
    || ! grep -qE "106[^)]*struct[[:space:]]+ksu_manager_cmd" "$uapi"; then
    echo "::error title=KSU manager ioctl 兼容失败::未能补正 $uapi 的 106 号 ioctl 声明（形态 $SHAPE；KSU_IOCTL_MANAGER 定义数=$mgr_count，KSU_IOCTL_KPM 定义数=$kpm_count）。上游布局可能已变化，请对比 main 分支的 uapi/supercall.h 人工核对" >&2
    exit 1
  fi
  echo "KSU manager ioctl 兼容：已把 106 号 ioctl 补正为 KSU_IOCTL_MANAGER = _IOWR('K', 106, struct ksu_manager_cmd)"
}
ksu_manager_ioctl_compat

# ---- SukiSU builtin 的 throne_tracker 合并残留（与上一处同一批移植）----
# 上游 builtin 移植 dynamic multi-manager（a233901 / PR #987）时还漏改了一处：
# crown_manager() 里 pkg 是 if (sig_fallback) 块内的局部变量，函数末尾那个
# 「跳过内置管理器、只给动态管理器加冕」的循环却在块外引用它：
#   common/drivers/kernelsu/manager/throne_tracker.c:97: error:
#     use of undeclared identifier 'pkg'
# main 分支该行用的是 KSU_PACKAGE_NAME（语义＝跳过内置管理器自己那条记录，
# 见 main 对应循环里的 continue），按 main 换回去即可；块内那处合法用法不动。
#
# 判据读产物本身，不按出现次数猜：只换「pkg 在该调用处不可见」的那几处。
# 只看花括号深度不够 —— 残留那种情形（声明在 if 块里、调用在后面的同级 for
# 块里）两者深度相同；要比的是「声明所在的那个块在调用处是否仍未闭合」。
# 于是上游或其它分支把 pkg 提到函数作用域后（两处调用都合法）本步自动跳过，
# 不再把合法调用改坏：FinaSU 就是这个形态，而且它的内核树没定义
# KSU_PACKAGE_NAME，照 main 换过去会直接编不过（use of undeclared identifier）。
ksu_throne_tracker_pkg_compat() {
  local f="" cand
  for cand in "$KERNEL_ROOT/common/drivers/kernelsu/manager/throne_tracker.c" \
              "$KERNEL_ROOT/KernelSU/kernel/manager/throne_tracker.c"; do
    if [ -f "$cand" ]; then f="$cand"; break; fi
  done
  if [ -z "$f" ]; then
    echo "KSU throne_tracker 兼容：未找到 manager/throne_tracker.c（该分支布局可能已变化），跳过"
    return 0
  fi

  local pat='strncmp(np->package, pkg, KSU_MAX_PACKAGE_NAME)'
  local n
  n=$(grep -oF "$pat" "$f" | wc -l || true)
  if [ "$n" -eq 0 ]; then
    echo "KSU throne_tracker 兼容：未找到 \"$pat\"（上游可能已重构该函数），跳过"
    return 0
  fi

  # 逐处判定作用域，输出需要替换的序号（1 起、空格分隔）；空＝没有块外残留。
  # 扫描时跳过注释与字符串/字符字面量（其中的花括号不作数），并维护「未闭合块
  # 起始偏移」栈：声明记下自己所在的最内层块，调用记下当下打开的全部块，前者
  # 属于后者、且声明在前，才算 pkg 在该处可见。
  local need
  need=$(perl -e '
    my $c = do { local $/; <> };
    defined $c or exit 0;
    my $pat = q{strncmp(np->package, pkg, KSU_MAX_PACKAGE_NAME)};
    my $plen = length $pat;
    my $len = length $c;
    my (@decl, @occ, @open);
    my $i = 0;
    while ($i < $len) {
      my $two = substr($c, $i, 2);
      my $ch  = substr($c, $i, 1);
      if ($two eq q{/*}) { my $e = index($c, q{*/}, $i + 2); $i = $e < 0 ? $len : $e + 2; next; }
      if ($two eq q{//}) { my $e = index($c, "\n", $i + 2); $i = $e < 0 ? $len : $e + 1; next; }
      if ($ch eq q{"} || $ch eq "\x27") {
        my $q = $ch;
        my $j = $i + 1;
        while ($j < $len) {
          my $x = substr($c, $j, 1);
          if ($x eq "\\") { $j += 2; next; }
          if ($x eq $q) { $j++; last; }
          $j++;
        }
        $i = $j; next;
      }
      if ($ch eq chr(123)) { push @open, $i; $i++; next; }
      if ($ch eq chr(125)) { pop @open; $i++; next; }
      if (substr($c, $i, $plen) eq $pat) { push @occ, [$i, [@open]]; $i += $plen; next; }
      if (substr($c, $i, 24) =~ /^char\s+pkg\s*\[/) { push @decl, [$i, @open ? $open[-1] : -1]; }
      $i++;
    }
    my @need;
    for my $k (0 .. $#occ) {
      my ($o, $blocks) = @{$occ[$k]};
      my $in = 0;
      for my $dl (@decl) {
        next unless $dl->[0] < $o;
        next unless grep { $_ == $dl->[1] } @$blocks;
        $in = 1; last;
      }
      push @need, $k + 1 unless $in;
    }
    print join(" ", @need);
  ' "$f")

  if [ -z "$need" ]; then
    if [ "$n" -eq 1 ]; then
      echo "KSU throne_tracker 兼容：pkg 只在 sig_fallback 块内使用（无块外残留），跳过"
    else
      echo "KSU throne_tracker 兼容：$n 处该调用都在 pkg 作用域内（无块外残留），跳过"
    fi
    return 0
  fi

  # 照 main 换回去之前先确认这棵树确实认识 KSU_PACKAGE_NAME —— 否则只是把
  # 「未声明 pkg」换成「未声明 KSU_PACKAGE_NAME」，错误挪个位置而已。
  if ! grep -qF 'KSU_PACKAGE_NAME' "$f"; then
    echo "::error title=KSU throne_tracker 兼容失败::第 $need 处调用在 pkg 作用域外，但 $f 里不存在 KSU_PACKAGE_NAME，照 main 换回会引入未声明标识符，请人工核对" >&2
    exit 1
  fi

  echo "KSU throne_tracker 兼容：块外残留引用了局部变量 pkg（第 $need 处），按 main 换回 KSU_PACKAGE_NAME"
  NEED=$(echo "$need" | tr ' ' ',') perl -0777 -i -pe '
    BEGIN { %need = map { $_ => 1 } split /,/, ($ENV{NEED} // q{}) }
    my $pat = q{strncmp(np->package, pkg, KSU_MAX_PACKAGE_NAME)};
    my $i = 0;
    s{\Q$pat\E}{ ++$i; $need{$i} ? "strncmp(np->package, KSU_PACKAGE_NAME, KSU_MAX_PACKAGE_NAME)" : $& }ge;
  ' "$f"

  # 写后校验：只应少掉 $need 那么多处，且确实出现了 KSU_PACKAGE_NAME 写法
  local left want
  left=$(grep -oF "$pat" "$f" | wc -l || true)
  want=$(( n - $(echo "$need" | wc -w) ))
  if [ "$left" -ne "$want" ] \
    || ! grep -qF 'strncmp(np->package, KSU_PACKAGE_NAME, KSU_MAX_PACKAGE_NAME)' "$f"; then
    echo "::error::throne_tracker.c 补正失败（剩余 \"$pat\" $left 处，期望 $want 处），请对照 main 分支人工核对" >&2
    exit 1
  fi
  echo "KSU throne_tracker 兼容：已把块外的 pkg 换回 KSU_PACKAGE_NAME"
}
ksu_throne_tracker_pkg_compat

# ---- 上游 throne_tracker.c 结构体初始化漏分号（2026-10-21 的新代码）----
# search_manager() 里
#   struct my_dir_context ctx = { .ctx.actor = my_actor,
#                                 ...
#                                 .depth = pos->depth }      ← 少了 ;
# clang 报 `error: expected ';' at end of declaration`。同一批新代码里另外两个
# 错误（throne_tracker.c 的 __attribute__((weak)) extern、以及把函数地址当布尔
# 判断的 -Wpointer-bool-conversion）上游几个小时内已自行改成 static_call 方案，
# 本步骤不处理；上游把这个分号补上后，这里按内容检测自动跳过。
ksu_throne_tracker_semicolon_compat() {
  local f="" cand
  for cand in "$KERNEL_ROOT/common/drivers/kernelsu/manager/throne_tracker.c" \
              "$KERNEL_ROOT/KernelSU/kernel/manager/throne_tracker.c"; do
    if [ -f "$cand" ]; then f="$cand"; break; fi
  done
  if [ -z "$f" ] || ! grep -qE '\.depth = pos->depth[[:space:]]*\}' "$f"; then
    echo "KSU throne_tracker 分号兼容：无需处理（无该结构体初始化行），跳过"
    return 0
  fi
  if grep -qE '\.depth = pos->depth[[:space:]]*\};' "$f"; then
    echo "KSU throne_tracker 分号兼容：分号已在（上游已修），跳过"
    return 0
  fi
  echo "KSU throne_tracker 分号兼容：为 my_dir_context 初始化补上缺失的分号"
  perl -i -pe 's{^(\s*\.depth = pos->depth\s*\})(\s*)$}{$1;$2}' "$f"
  if ! grep -qE '\.depth = pos->depth[[:space:]]*\};' "$f"; then
    echo "::error::补分号失败（$f），请人工核对 manager/throne_tracker.c" >&2
    exit 1
  fi
  echo "KSU throne_tracker 分号兼容：已补上"
}
ksu_throne_tracker_semicolon_compat

# ---- 上游 shell_su_adb_only.c 条件编译未闭合（2026-10-21 的新代码）----
# 上游 6d571adc 给这个文件加 KSU_COMPAT_USE_STATIC_KEY 守卫时，动手改坏了
# ksu_shell_su_allowed_for_current()：本该收尾的 #endif 被写成了 #else，
# 中间还夹着一句加守卫之前的残句（缩进都是 3 格，手工合并的痕迹）：
#
#   #ifdef KSU_COMPAT_USE_STATIC_KEY
#       if (!static_branch_unlikely(&ksu_shell_su_adb_only)) {
#           return true;
#       }
#      if (unlikely(ksu_shell_su_adb_only)) {   ← 残句：static_key 结构体当布尔用
#           return true;
#       }
#   #else                                        ← 这里本该是 #endif
#                                                ← 于是 #else 分支挨到文件尾，空的
#       return has_trusted_ancestor();
#   }                                            ← 函数右花括号被 #else 一起跳过
#
# 两个后果，第二个才是致命的：
#   1) 残句那行 clang 报 invalid argument type 'struct static_key_false' to
#      unary expression；
#   2) 从 #else 到文件尾全被预处理掉 ⇒ 函数没了右花括号、条件编译悬到 EOF
#      （unterminated conditional directive）。而 mount_hide.c、runtime/ksud.c
#      是同一个编译单元里随后 #include 进来的，于是它们的正文全部被解析进这个
#      没闭合的函数体内，报出十几条 "function definition is not allowed here"、
#      "function declared in block scope cannot have 'static' storage class"。
#      ——那一片报错都是级联，真因只有这一处。
#
# KSU_COMPAT_USE_STATIC_KEY 由 kernel_compat.h 里 LINUX_VERSION_CODE >= 4.3
# 定义，本项目所有目标内核都满足 ⇒ 走的一定是 #ifdef 那一支；#else 那支只服务
# 4.3 以前的内核，这里仍按官方 main 的语义（!static_branch_unlikely ↔ !flag）
# 补全，免得日后有人往老内核回移时踩到反了的判据。
#
# 判据看内容不砍版本：文件里出现那句残句才动手（正确写法是 unlikely(!...，
# 不会误命中）；上游自己修好后自动跳过；条件编译不平衡却又没有残句，说明是
# 别的形态的破坏，直接报错不猜。重复执行幂等（重写完就是上面那份规范文本）。
cond_balance() {
  # 打印「#if* 比 #endif 多几个」；先剥注释，避免注释里的示例被当成真指令
  perl -0777 -pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g' "$1" | awk '
    { s=$0; sub(/^[ \t]+/,"",s)
      if (s ~ /^#[ \t]*endif/) d--
      else if (s ~ /^#[ \t]*if/) d++ }
    END { print d+0 }'
}

ksu_shell_su_adb_only_compat() {
  local f="" cand
  for cand in "$KERNEL_ROOT/common/drivers/kernelsu/feature/shell_su_adb_only.c" \
              "$KERNEL_ROOT/KernelSU/kernel/feature/shell_su_adb_only.c"; do
    if [ -f "$cand" ]; then f="$cand"; break; fi
  done
  if [ -z "$f" ]; then
    echo "KSU shell_su_adb_only 兼容：未找到 feature/shell_su_adb_only.c（该分支无此文件），跳过"
    return 0
  fi

  local broken='unlikely(ksu_shell_su_adb_only)'
  local sig='bool ksu_shell_su_allowed_for_current(void)'
  if ! grep -qF "$broken" "$f"; then
    local bal; bal=$(cond_balance "$f")
    if [ "$bal" -ne 0 ]; then
      echo "::error title=KSU shell_su_adb_only 兼容失败::$f 条件编译不平衡（#if 比 #endif 多 $bal）但未见已知残句，上游改动形态不认识，请人工核对" >&2
      exit 1
    fi
    echo "KSU shell_su_adb_only 兼容：无需处理（无残句且条件编译平衡），跳过"
    return 0
  fi

  echo "KSU shell_su_adb_only 兼容：ksu_shell_su_allowed_for_current() 的 #endif 被写成 #else，整段重写为规范形态"
  # 从函数签名重写到该函数第一个顶格 } 为止（残句把右花括号吞了，所以“第一个顶格 }”
  # 就是本函数真正的收尾）；不依赖残句那几行的缩进/换行，CRLF 检出也照改。
  perl -0777 -i -pe '
    my $nl = /\r\n/ ? "\r\n" : "\n";
    my $sig = "bool ksu_shell_su_allowed_for_current(void)";
    my $canon = join($nl,
      $sig,
      "{",
      "#ifdef KSU_COMPAT_USE_STATIC_KEY",
      "    if (!static_branch_unlikely(&ksu_shell_su_adb_only)) {",
      "        return true;",
      "    }",
      "#else",
      "    if (unlikely(!ksu_shell_su_adb_only)) {",
      "        return true;",
      "    }",
      "#endif",
      "",
      "    return has_trusted_ancestor();",
      "}"
    );
    my $re = qr{\Q$sig\E\r?\n\{\r?\n[\s\S]*?\r?\n\}};
    my $n = s/$re/$canon/;
    if ($n != 1) {
      print STDERR "::error::shell_su_adb_only.c 里 $sig 匹配 $n 次（期望 1 次），请人工核对\n";
      exit 1;
    }
  ' "$f" || exit 1

  # 写后校验：残句没了、规范形态在、条件编译平衡
  local bal; bal=$(cond_balance "$f")
  if grep -qF "$broken" "$f" || [ "$bal" -ne 0 ] \
    || ! grep -qF '#endif' "$f" \
    || ! grep -qF 'unlikely(!ksu_shell_su_adb_only)' "$f"; then
    echo "::error::shell_su_adb_only.c 补正失败（残句残留或条件编译仍不平衡，差值 $bal），请人工核对 $f" >&2
    exit 1
  fi
  echo "KSU shell_su_adb_only 兼容：已闭合条件编译，函数收尾补回（条件编译差值 $bal）"
}
ksu_shell_su_adb_only_compat

# ---- 兜底诊断：KernelSU 树的条件编译平衡 ----
# 上面那个坑的报错形态极难认：真因（少一个 #endif）在 A 文件，clang 的报错却
# 全落在同一个编译单元里随后 #include 进来的 B、C 文件上（"function definition
# is not allowed here"、"function declared in block scope" 之类），看着像 B、C
# 坏了。这一步只诊断、只报 warning，绝不阻断构建：同类破坏再现时，日志里会直接
# 点名是哪个文件，省掉一轮 CI。
# 先剥注释再数，免得注释里的示例指令被当成真指令；#endif 必须先判，
# 因为它也以 "#if" 开头。
ksu_cond_balance_scan() {
  local kroot="" cand
  for cand in "$KERNEL_ROOT/KernelSU/kernel" "$KERNEL_ROOT/common/drivers/kernelsu"; do
    if [ -d "$cand" ]; then kroot="$cand"; break; fi
  done
  if [ -z "$kroot" ]; then
    echo "KSU 条件编译平衡扫描：未找到 KernelSU 源码目录，跳过"
    return 0
  fi

  # 注意：perl 程序里不能出现字面量 "{}"（含 s{...}{} 这种替换定界符），
  # 否则 find -exec ... + 会报 "Only one instance of {} is supported" 而
  # 一个文件都不扫。替换用 "!" 做定界符。
  local hits=""
  hits=$(find "$kroot" -type f \( -name '*.c' -o -name '*.h' -o -name '*.S' \) -exec perl -e '
    for my $f (@ARGV) {
      open(my $fh, "<", $f) or next;
      local $/; my $t = <$fh>; close $fh;
      $t =~ s!/\*.*?\*/!!gs;
      $t =~ s!//[^\n]*!!g;
      my $d = 0;
      for my $l (split /\n/, $t) {
        (my $s = $l) =~ s/^\s+//;
        if    ($s =~ /^#\s*endif/) { $d-- }
        elsif ($s =~ /^#\s*if/)    { $d++ }
      }
      printf "%s  (%s %d 个 #endif)\n", $f, ($d > 0 ? "少" : "多"), abs($d) if $d != 0;
    }' {} +) || hits=""

  if [ -n "$hits" ]; then
    echo "::warning title=KSU 条件编译不平衡（报错会落在别的文件上，真因在这里）::$hits"
  else
    echo "KSU 条件编译平衡扫描：$(find "$kroot" -type f \( -name '*.c' -o -name '*.h' -o -name '*.S' \) | wc -l) 个文件全部平衡"
  fi
}
ksu_cond_balance_scan


# ---- SUSFS 的 susfs_def.h 少了 struct kstatfs 前向声明（2026-10-24 的新代码）----
# 该版 susfs_def.h 里出现
#   extern int susfs_sus_kstat_spoof_vfs_statfs(struct inode *, struct kstatfs *, bool *);
# 但它既没包含 linux/statfs.h、也没前向声明 struct kstatfs ⇒ clang 报
#   error: declaration of 'struct kstatfs' will not be visible outside of this function
#   [-Werror,-Wvisibility]
# 6.6 的 clang 把这个警告当错误，于是 setuid_hook.o 编不过。就地补一行前向声明；
# 已经有声明、或没有该用法时自动跳过，幂等。
susfs_def_kstatfs_fwd_compat() {
  local f="" cand
  for cand in "$KERNEL_ROOT/common/include/linux/susfs_def.h" \
              "$KERNEL_ROOT/KernelSU/kernel/include/linux/susfs_def.h"; do
    if [ -f "$cand" ]; then f="$cand"; break; fi
  done
  if [ -z "$f" ]; then
    echo "SUSFS susfs_def.h 兼容：未找到 susfs_def.h，跳过"
    return 0
  fi
  if ! grep -q 'struct kstatfs \*' "$f"; then
    echo "SUSFS susfs_def.h 兼容：没有 struct kstatfs 用法，跳过"
    return 0
  fi
  if grep -qE '^[[:space:]]*struct kstatfs;' "$f"; then
    echo "SUSFS susfs_def.h 兼容：struct kstatfs 前向声明已在，跳过"
    return 0
  fi
  echo "SUSFS susfs_def.h 兼容：补 struct kstatfs 前向声明"
  perl -i -pe 'if (!$d && /struct kstatfs \*/) { $_ = "struct kstatfs;\n" . $_; $d = 1 }' "$f"
  if ! grep -qE '^struct kstatfs;' "$f"; then
    echo "::error::补 struct kstatfs 前向声明失败（$f）" >&2
    exit 1
  fi
  echo "SUSFS susfs_def.h 兼容：已补上"
}
susfs_def_kstatfs_fwd_compat

# ---- priority uid filter 的两个 helper 只被该特性的守卫块使用（2026-11-01 重构）----
# 2026-11-01 的 SUSFS 重构（268fba59e）把 priority uid filter 变成 config 门控特性：
# 整块代码（含全部调用点）包进 `#ifdef CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER`，但
#   static struct cred *susfs_switch_to_ksu_domain(void)    （约 183 行）
#   static void susfs_restore_creds(struct cred *orig_cred) （约 217 行）
# 两个 helper 的定义留在守卫外。该符号只声明在 SUSFS 自带的 KernelSU 侧补丁
# （kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch，default y）里，而这里用的是
# 各 KSU 变体自带的 Kconfig —— 未声明该符号时守卫恒假、特性块被编掉，两个 helper
# 成为 unused static function，clang 以 -Werror,-Wunused-function 报错、fs/susfs.o 失败
# （android15-6.6-118 + FinaSU，2026-11-02 实测 exit 2）。内核文件侧的调用点
# （block/ioprio.c、kernel/sys.c）都在同一守卫内，包上即与上游不变量一致。
# 判据只看产物本身：① susfs.c 里有该守卫块；② 树里的 KernelSU Kconfig 没有声明该
# 符号；③ 两个 helper 在守卫块外没有任何其他引用 —— 三条同时成立才动手。没有守卫块、
# 已声明符号、定义已在守卫内（幂等）都跳过；块外还有引用或布局不符则告警跳过、不改。
susfs_priority_uid_guard_state() {
  # 守卫块结构判定（只看代码本身，注释不参与），退出码即结论：
  #   0 需要包裹 / 10 布局不符 / 11 定义已在守卫块内 / 12 守卫块外仍有引用
  perl -0777 -ne '
    my @L = split /\n/;
    my ($s, $e, $d) = (-1, -1, 0);
    for my $i (0 .. $#L) {
      (my $l = $L[$i]) =~ s/\r$//;
      if ($s < 0) {
        if ($l =~ /^#\s*ifdef\s+CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER\b/) { $s = $i; $d = 1 }
        next;
      }
      if ($l =~ /^#\s*if/)    { $d++; next }
      if ($l =~ /^#\s*endif/) { $d--; if (!$d) { $e = $i; last } }
    }
    exit 10 if $s < 0 || $e < 0;
    my $t = $_;
    $t =~ s{/\*.*?\*/}{ my $c = $&; $c =~ s/[^\n]//g; $c }ges;  # 块注释只留换行
    $t =~ s{//[^\n]*}{}g;                                        # 行注释整段去掉
    my @C = split /\n/, $t;
    my (@def, @outside);
    for my $j (0 .. $#C) {
      next unless $C[$j] =~ /susfs_switch_to_ksu_domain|susfs_restore_creds/;
      if ($L[$j] =~ /^static\s+struct\s+cred\s*\*\s*susfs_switch_to_ksu_domain\s*\(/) { push @def, $j; next }
      if ($L[$j] =~ /^static\s+void\s+susfs_restore_creds\s*\(/) { push @def, $j; next }
      push @outside, $j if $j < $s || $j > $e;
    }
    exit 10 unless @def == 2;
    exit 11 if grep { $_ > $s && $_ < $e } @def;
    exit 12 if @outside;
    exit 0;
  ' "$1"
}
susfs_priority_uid_filter_guard_compat() {
  local f="$KERNEL_ROOT/common/fs/susfs.c"
  if [ ! -f "$f" ]; then
    echo "SUSFS priority uid filter 守卫步骤：未找到 fs/susfs.c，跳过"
    return 0
  fi
  if ! grep -q '^#ifdef CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER' "$f"; then
    echo "SUSFS priority uid filter 守卫步骤：无该守卫块（重构前版本），跳过"
    return 0
  fi
  local kconf found=""
  for kconf in "$KERNEL_ROOT/KernelSU/kernel/Kconfig" \
              "$KERNEL_ROOT/common/drivers/kernelsu/Kconfig"; do
    if [ -f "$kconf" ] \
      && grep -qE '^[[:space:]]*config[[:space:]]+KSU_SUSFS_PRIORITY_UID_FILTER([[:space:]]|$)' "$kconf"; then
      found="$kconf"
      break
    fi
  done
  if [ -n "$found" ]; then
    echo "SUSFS priority uid filter 守卫步骤：Kconfig 已声明该符号，跳过"
    return 0
  fi
  local st=0
  susfs_priority_uid_guard_state "$f" || st=$?
  case "$st" in
    11) echo "SUSFS priority uid filter 守卫步骤：helper 定义已在守卫块内，跳过"; return 0 ;;
    12) echo "::warning title=priority uid filter 守卫::守卫块外仍有 helper 引用，跳过不改（需人工确认）"; return 0 ;;
    10) echo "::warning title=priority uid filter 守卫::susfs.c 里没找到预期的两个 helper 定义，跳过不改"; return 0 ;;
    0)  : ;;
    *)  echo "::warning title=priority uid filter 守卫::结构判定失败（rc=$st），跳过不改"; return 0 ;;
  esac
  local before_if after_if
  before_if=$(grep -cE '^#ifdef CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER\r?$' "$f" || true)
  echo "SUSFS priority uid filter 守卫步骤：把两个 helper 定义包进同一守卫"
  perl -0777 -i -pe '
    my $nl = /\r\n/ ? "\r\n" : "\n";
    my $n = ($_ =~ s{^(static\s+struct\s+cred\s*\*\s*susfs_switch_to_ksu_domain\s*\(\s*void\s*\)\s*\{.*?^static\s+void\s+susfs_restore_creds\s*\(.*?\n\})}{#ifdef CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER$nl$1$nl#endif // #ifdef CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER}ms);
    die "priority uid filter helper 段落匹配失败（n=$n）\n" unless $n == 1;
  ' "$f" || { echo "::error::包裹 priority uid filter helper 失败" >&2; exit 1; }
  after_if=$(grep -cE '^#ifdef CONFIG_KSU_SUSFS_PRIORITY_UID_FILTER\r?$' "$f" || true)
  if [ "$after_if" -ne $((before_if + 1)) ]; then
    echo "::error::priority uid filter 守卫计数不符（$before_if → $after_if）" >&2
    exit 1
  fi
  st=0
  susfs_priority_uid_guard_state "$f" || st=$?
  if [ "$st" -ne 11 ]; then
    echo "::error::包裹后结构复判未通过（rc=$st）" >&2
    exit 1
  fi
  echo "SUSFS priority uid filter 守卫步骤：已包裹"
}
susfs_priority_uid_filter_guard_compat
