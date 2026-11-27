#!/usr/bin/env bash
# 「添加 KernelSU」步骤的完整逻辑。独立成文件是因为 GitHub 对单个 run 模板的
# 内部计数（UTF-8 膨胀后）上限为 21000，内联到 YAML 后会超限导致 workflow
# 直接判无效（Exceeded max expression length 21000）。
#
# 由 get-manager.yml 调用，环境变量：
#   KSU_VARIANT         = inputs.kernelsu_variant
#   BUILD_CHANNEL_INPUT = inputs.build_channel
#   GH_TOKEN            = secrets.GITHUB_TOKEN
# 输出写入 GITHUB_ENV / GITHUB_OUTPUT，与原先内联时保持一致。
set -e

VARIANT="${KSU_VARIANT:-}"

case "$VARIANT" in
  "SukiSU-Nova") REPO="SukiSU-Nova/SukiSU-Nova"; KSUM="manager"; EXPECTED_BRANCH="main" ;;
  "BakaSU") REPO="Baka-SU/BakaSU";           KSUM="manager"; EXPECTED_BRANCH="main" ;;
  "FinaSU") REPO="LyraVoid/FinaSU";          KSUM="manager"; EXPECTED_BRANCH="master" ;;
  *) echo "::error::未知变体: $VARIANT"; exit 1 ;;
esac

# 通道兜底解析（选择步骤异常时仍能按输入判断）
CHANNEL_KIND="${CHANNEL_KIND:-}"
if [ -z "$CHANNEL_KIND" ]; then
  case "${BUILD_CHANNEL_INPUT:-}" in
    最新*|latest*|HEAD*) CHANNEL_KIND="latest" ;;
    *)                   CHANNEL_KIND="release" ;;
  esac
fi

mkdir -p manager-artifacts

# ==================== A. 正式通道：官方 Release 管理器 ====================
if [ "${MANAGER_SOURCE:-ci}" = "release" ] && [ -n "${REL_APK_URL:-}" ]; then
  echo "正式通道：下载 Release $REL_TAG 的管理器（$REL_APK_NAME）..."
  REL_APK="manager-artifacts/$(basename "$REL_APK_NAME")"
  if curl -sL --fail --retry 3 --max-time 300 -o "$REL_APK" "$REL_APK_URL"; then
    # 先剥离 ABI 段再提取版本，避免 x86_64 的 "_64" 等数字尾巴被误当成 versionCode
    CLEAN_NAME=$(basename "$REL_APK" | sed -E 's/-(arm64-v8a|armeabi-v7a|armv7|riscv64|x86_64|x86|universal)-release\.apk$/.apk/')
    MANAGER_VERSION=$(echo "$CLEAN_NAME" | grep -oE '_[0-9]+' | tail -n 1 | tr -d '_')
    if [[ "${MANAGER_VERSION:-}" =~ ^[0-9]+$ ]]; then
      echo "Release 管理器版本: $MANAGER_VERSION（标签 $REL_TAG，提交 ${REL_COMMIT:0:8}）"
      echo "MANAGER_VERSION=$MANAGER_VERSION" >> $GITHUB_ENV
      {
        echo "managerVer=$MANAGER_VERSION"
        echo "ksuCommit=$REL_COMMIT"
        echo "channelTag=$REL_TAG"
      } >> $GITHUB_OUTPUT

      # 版本一致性自检：Release 标签提交对应的 KSU 版本应与管理器 versionCode 相同
      REL_COUNT=$(git -C KernelSU rev-list --count "$REL_COMMIT" 2>/dev/null || echo "")
      if [ -n "$REL_COUNT" ]; then
        case "$VARIANT" in
          SukiSU-Nova) REL_KSU_VERSION=$((30000 + REL_COUNT + 996)) ;;
          BakaSU) REL_KSU_VERSION=$((30700 + REL_COUNT)) ;;
          FinaSU) REL_KSU_VERSION=$((30000 + REL_COUNT)) ;;
        esac
        if [ "$MANAGER_VERSION" != "$REL_KSU_VERSION" ]; then
          echo "::warning::Release 管理器版本 $MANAGER_VERSION 与标签提交对应的 KSU 版本 $REL_KSU_VERSION 不一致"
        fi
      fi

      if [ "$VARIANT" == "FinaSU" ]; then
        echo "从 Release 管理器 APK 提取签名证书..."
        CERT_INFO=$(python3 "$GITHUB_WORKSPACE/scripts/finasu_compat/extract_manager_cert.py" "$REL_APK" | head -n1)
        if [ -n "$CERT_INFO" ]; then
          CERT_SIZE=$(echo "$CERT_INFO" | awk '{print $1}')
          CERT_HASH=$(echo "$CERT_INFO" | awk '{print $2}')
          echo "managerCertSize=$CERT_SIZE" >> $GITHUB_OUTPUT
          echo "managerCertHash=$CERT_HASH" >> $GITHUB_OUTPUT
          echo "Release 管理器证书 size=$CERT_SIZE sha256=$CERT_HASH"
        else
          echo "::warning title=证书缺失::无法从 Release 管理器 APK 提取签名证书，内核侧将回退提取"
        fi
      fi
      exit 0
    fi
    echo "::warning title=正式通道回退::无法从 Release 管理器文件名解析版本（$(basename "$REL_APK")），回退到最新通道"
  else
    echo "::warning title=正式通道回退::Release 管理器下载失败，回退到最新通道"
  fi
  rm -rf manager-artifacts && mkdir -p manager-artifacts
fi

# ==================== B. FinaSU：正式通道 Release 管理器 ====================
if [ "$VARIANT" == "FinaSU" ] && [ "${PIN_MODE:-pin}" != "head" ]; then
  # 正式通道（含正式 Release 不可用时的回退）：
  #   管理器/证书取最新 Release APK，内核锁定 Release 标签提交
  #   最新通道改走下方 build-manager.yml 的 CI 管理器产物
  echo "FinaSU：管理器取最新 Release APK..."
  REL_JSON=""
  for ATTEMPT in 1 2 3; do
    REL_JSON=$(curl -s --fail --max-time 30 \
      -H "Authorization: token $GH_TOKEN" \
      "https://api.github.com/repos/LyraVoid/FinaSU/releases/latest") \
      && [ -n "$REL_JSON" ] && break
    echo "获取 Release 信息失败，重试 ($ATTEMPT/3)..."
    REL_JSON=""
    sleep 5
  done
  if [ -z "$REL_JSON" ]; then
    echo "::warning::无法获取 FinaSU 最新 Release 信息，本次跳过管理器与证书对齐（内核跟随 master）"
    echo "ksuCommit=" >> $GITHUB_OUTPUT
    exit 0
  fi
  REL_TAG=$(printf '%s' "$REL_JSON" | jq -r '.tag_name')
  REL_APK_URL=$(printf '%s' "$REL_JSON" | jq -r '.assets[] | select(.name | endswith(".apk")) | .browser_download_url' | head -n1)
  if [ -z "$REL_APK_URL" ] || [ "$REL_APK_URL" = "null" ]; then
    echo "::warning::Release $REL_TAG 中没有 APK 资产，本次跳过管理器与证书对齐"
    echo "ksuCommit=" >> $GITHUB_OUTPUT
    exit 0
  fi
  echo "下载 Release 管理器: $REL_TAG"
  REL_APK="manager-artifacts/$(basename "$REL_APK_URL")"
  if ! curl -sL --fail --retry 3 --max-time 300 -o "$REL_APK" "$REL_APK_URL"; then
    echo "::warning::下载 Release 管理器失败，本次跳过管理器与证书对齐"
    echo "ksuCommit=" >> $GITHUB_OUTPUT
    exit 0
  fi
  CLEAN_NAME=$(basename "$REL_APK" | sed -E 's/-(arm64-v8a|armeabi-v7a|armv7|riscv64|x86_64|x86|universal)-release\.apk$/.apk/')
  MANAGER_VERSION=$(echo "$CLEAN_NAME" | grep -oE '_[0-9]+' | tail -n 1 | tr -d '_')
  if ! [[ "${MANAGER_VERSION:-}" =~ ^[0-9]+$ ]]; then
    echo "::warning::无法从 Release APK 文件名解析版本 ($(basename "$REL_APK"))，本次跳过管理器与证书对齐"
    echo "ksuCommit=" >> $GITHUB_OUTPUT
    exit 0
  fi
  echo "从 Release 管理器 APK 提取签名证书..."
  CERT_INFO=$(python3 "$GITHUB_WORKSPACE/scripts/finasu_compat/extract_manager_cert.py" "$REL_APK" | head -n1)
  if [ -z "$CERT_INFO" ]; then
    echo "::warning::未能从 Release 管理器 APK 提取签名证书，内核侧将回退 Release APK 证书提取"
    echo "ksuCommit=" >> $GITHUB_OUTPUT
    exit 0
  fi
  CERT_SIZE=$(echo "$CERT_INFO" | awk '{print $1}')
  CERT_HASH=$(echo "$CERT_INFO" | awk '{print $2}')
  echo "Release: $REL_TAG, 管理器版本 $MANAGER_VERSION, 证书 size=$CERT_SIZE sha256=$CERT_HASH"
  echo "MANAGER_VERSION=$MANAGER_VERSION" >> $GITHUB_ENV
  echo "managerVer=$MANAGER_VERSION" >> $GITHUB_OUTPUT
  echo "managerCertSize=$CERT_SIZE" >> $GITHUB_OUTPUT
  echo "managerCertHash=$CERT_HASH" >> $GITHUB_OUTPUT
  # 正式通道：锁定 Release 标签提交
  FINASU_REF=$(git -C KernelSU rev-parse "${REL_TAG}^{commit}" 2>/dev/null \
    || git ls-remote https://github.com/LyraVoid/FinaSU.git "refs/tags/${REL_TAG}^{}" 2>/dev/null | awk '{print $1}')
  echo "内核锁定提交: ${FINASU_REF:0:8}"
  echo "ksuCommit=$FINASU_REF" >> $GITHUB_OUTPUT
  exit 0
fi

# ---------- SukiSU-Nova：正式通道取稳定 Release、最新通道取 manager-ci ----------
# 具体逻辑与端点见 .github/scripts/sukisu-nova-manager.sh。成功时脚本写入
# GITHUB_ENV/OUTPUT 并退出 0；失败则回退下方的 GitHub Actions 通道查询。
if [ "$VARIANT" = "SukiSU-Nova" ]; then
  echo "SukiSU-Nova：从上游 Release 源获取管理器（通道：${BUILD_CHANNEL_INPUT:-release}）..."
  if bash "$GITHUB_WORKSPACE/.github/scripts/sukisu-nova-manager.sh" "${BUILD_CHANNEL_INPUT:-release}" KernelSU; then
    exit 0
  fi
  echo "::warning title=SukiSU-Nova 最新通道回退::未能从 Forgejo/cnb.cool 获取可用管理器，回退 GitHub Actions 通道查询"
fi

# ---------- 最新通道：官方 CI 构建的管理器（BakaSU / FinaSU；SukiSU-Nova 走上方 Forgejo 路径） ----------
get_manager_artifacts() {
  local artifacts="$1"
  if [ "$VARIANT" == "FinaSU" ]; then
    # build-manager.yml 的正式分发产物固定为 manager；
    # manager-gradle 是未重签的中间产物，证书与内核第二信任槽不一致。
    printf '%s' "$artifacts" | jq -r \
      '.artifacts[] | select(.name == "manager") | "\(.name)\t\(.archive_download_url)"'
  elif [ "$VARIANT" == "BakaSU" ]; then
    printf '%s' "$artifacts" | jq -r \
      '.artifacts[] | select(.name == "Manager-release" or .name == "Spoofed-Manager-release") | "\(.name)\t\(.archive_download_url)"'
  else
    printf '%s' "$artifacts" | jq -r --arg needle "$KSUM" \
      '.artifacts[] | select((.name | ascii_downcase) | contains($needle)) | "\(.name)\t\(.archive_download_url)"'
  fi
}

# 版本号与管理器 versionCode 同源（提交数 + 偏移），用于按版本挑选构建
ksu_version_of() {
  case "$1" in
    SukiSU-Nova) echo $((30000 + $2 + 996)) ;;
    BakaSU) echo $((30700 + $2)) ;;
    FinaSU) echo $((30000 + $2)) ;;
  esac
}

# 最新通道：先锁定默认分支 HEAD，再把管理器限定为「版本与该 HEAD 一致」的构建，
# 避免出现内核 35249 / 管理器 35248 这种版本错位。
# BakaSU/FinaSU 例外：不锁默认分支 HEAD，直接取 build-manager.yml 按创建时间
# 倒序的最新成功构建，内核锁定该构建提交，保证管理器与内核版本严格一致。
LATEST_PICK_BUILD=0
if [ "$VARIANT" = "BakaSU" ] || [ "$VARIANT" = "FinaSU" ]; then
  LATEST_PICK_BUILD=1
fi
HEAD_SHA=""
HEAD_VERSION=""
if [ "${PIN_MODE:-pin}" = "head" ] && [ "$LATEST_PICK_BUILD" = 0 ]; then
  HEAD_SHA=$(git -C KernelSU rev-parse "origin/${EXPECTED_BRANCH}^{commit}" 2>/dev/null || true)
  if [ -z "$HEAD_SHA" ]; then
    HEAD_SHA=$(git ls-remote "https://github.com/$REPO.git" "refs/heads/$EXPECTED_BRANCH" 2>/dev/null | awk '{print $1}')
  fi
  if [ -n "$HEAD_SHA" ]; then
    git -C KernelSU cat-file -e "${HEAD_SHA}^{commit}" 2>/dev/null || git -C KernelSU fetch -q origin "$HEAD_SHA" 2>/dev/null || true
    HEAD_COUNT=$(git -C KernelSU rev-list --count "$HEAD_SHA" 2>/dev/null || echo "")
    if [ -n "$HEAD_COUNT" ]; then
      HEAD_VERSION=$(ksu_version_of "$VARIANT" "$HEAD_COUNT")
    fi
    echo "最新通道：$EXPECTED_BRANCH HEAD ${HEAD_SHA:0:8} 对应 KSU 版本 ${HEAD_VERSION:-未知}"
  else
    echo "::warning::无法解析 $EXPECTED_BRANCH HEAD，管理器按最新构建选择"
  fi
fi

# 仿 BakaSU_CI：只拉取官方默认分支最新上传（push）的 Manager 构建，
# 并以下载到的 APK 文件名实测 versionCode 命名，确保包名与包内容严格一致
# 注意：runs 列表 API 的排序/缓存在部分仓库不可靠（可能漏掉最新构建），
# 而 created 日期过滤参数走可靠查询路径，因此按日期窗口从今天往回推进检索
FILENAME="build-manager.yml"
RUNS_BASE="https://api.github.com/repos/$REPO/actions/workflows/$FILENAME/runs?status=success"
CAND_FILE=$(mktemp)
TODAY=$(date -u +%Y-%m-%d)

for DAYS in 0 7 30 90 365; do
  if [ "$DAYS" -eq 0 ]; then
    FROM="$TODAY"
  else
    FROM=$(date -u -d "today - $DAYS days" +%Y-%m-%d)
  fi
  echo "检索 $FROM ~ $TODAY 期间的 Manager 构建..."
  for PAGE in 1 2 3; do
    RUNS=""
    for ATTEMPT in 1 2 3; do
      RUNS=$(curl -s --fail --max-time 30 -H "Authorization: token $GH_TOKEN" \
        "$RUNS_BASE&created=$FROM..$TODAY&per_page=30&page=$PAGE") && [ -n "$RUNS" ] && break
      echo "查询构建列表失败，重试 ($ATTEMPT/3)..."
      RUNS=""
      sleep 3
    done
    RUN_COUNT=$(printf '%s' "$RUNS" | jq '.workflow_runs | length')
    if [ "$RUN_COUNT" -eq 0 ]; then
      break
    fi
    for INDEX in $(seq 0 $((RUN_COUNT - 1))); do
      BUILD_ID=$(printf '%s' "$RUNS" | jq -r ".workflow_runs[$INDEX].id")
      CAND_SHA=$(printf '%s' "$RUNS" | jq -r ".workflow_runs[$INDEX].head_sha")
      CAND_BRANCH=$(printf '%s' "$RUNS" | jq -r ".workflow_runs[$INDEX].head_branch")
      EVENT=$(printf '%s' "$RUNS" | jq -r ".workflow_runs[$INDEX].event")
      CREATED=$(printf '%s' "$RUNS" | jq -r ".workflow_runs[$INDEX].created_at")
      # 正式通道：只认官方默认分支上传的构建（push 与 workflow_dispatch 均可，
      # 手动触发常用于正式上传前测试），跳过 PR / 其他分支构建
      #（SukiSU-Nova/BakaSU 为 main，FinaSU 为 master）
      # 最新通道：接受任意分支的构建（跳过 PR 构建），再按版本与 HEAD 匹配排序
      if [ "${PIN_MODE:-pin}" = "head" ]; then
        if [ "$EVENT" != "push" ] && [ "$EVENT" != "workflow_dispatch" ]; then
          echo "跳过构建 $BUILD_ID ($CAND_BRANCH/$EVENT): 非 push/手动触发构建"
          continue
        fi
      elif [ "$CAND_BRANCH" != "$EXPECTED_BRANCH" ] || { [ "$EVENT" != "push" ] && [ "$EVENT" != "workflow_dispatch" ]; }; then
        echo "跳过构建 $BUILD_ID ($CAND_BRANCH/$EVENT): 非官方 $EXPECTED_BRANCH 分支构建"
        continue
      fi
      printf '%s\t%s\t%s\t%s\n' "$CREATED" "$BUILD_ID" "$CAND_SHA" "$CAND_BRANCH" >> "$CAND_FILE"
    done
  done
  if [ -s "$CAND_FILE" ]; then
    break
  fi
done

if [ ! -s "$CAND_FILE" ]; then
  rm -f "$CAND_FILE"
  echo "未找到可用的 Manager 构建。"
  echo "ksuCommit=" >> $GITHUB_OUTPUT
  exit 1
fi

# 去重后排序：
#   正式 → 默认分支构建按时间倒序
#   最新 → 优先「版本与 HEAD 一致」的构建，其次默认分支，最后其他分支（同组按时间倒序）
CAND_UNIQ=$(mktemp)
sort -u -t$'\t' -k2,2 "$CAND_FILE" > "$CAND_UNIQ"
rm -f "$CAND_FILE"

PREF_SHA=""
if [ "${PIN_MODE:-pin}" = "head" ] && [ -n "$HEAD_VERSION" ]; then
  while IFS=$'\t' read -r CREATED BUILD_ID CAND_SHA CAND_BRANCH; do
    if [ "$CAND_SHA" = "$HEAD_SHA" ]; then
      PREF_SHA="$CAND_SHA"
      break
    fi
    git -C KernelSU cat-file -e "${CAND_SHA}^{commit}" 2>/dev/null \
      || git -C KernelSU fetch -q origin "$CAND_SHA" 2>/dev/null \
      || continue
    CAND_COUNT=$(git -C KernelSU rev-list --count "$CAND_SHA" 2>/dev/null || echo "")
    [ -n "$CAND_COUNT" ] || continue
    if [ "$(ksu_version_of "$VARIANT" "$CAND_COUNT")" = "$HEAD_VERSION" ]; then
      PREF_SHA="$CAND_SHA"
      break
    fi
  done < <(sort -t$'\t' -k1,1r "$CAND_UNIQ" | head -n 40)
  if [ -n "$PREF_SHA" ]; then
    echo "优先选择与 HEAD 版本 $HEAD_VERSION 一致的构建提交 ${PREF_SHA:0:8}"
  fi
fi

ORDERED_FILE=$(mktemp)
if [ "$LATEST_PICK_BUILD" = 1 ]; then
  # 最新通道：严格按构建时间倒序，取 build-manager.yml 最新成功构建
  sort -t$'\t' -k1,1r "$CAND_UNIQ" \
    | awk -F'\t' '{ print "0\t" $0 }' > "$ORDERED_FILE"
else
  # 候选行格式：创建时间 \t 构建ID \t 提交 \t 分支（优先级在 awk 里补在第 1 列）
  sort -t$'\t' -k1,1r "$CAND_UNIQ" \
    | awk -F'\t' -v pref="$PREF_SHA" -v br="$EXPECTED_BRANCH" \
        '{ p = (pref != "" && $3 == pref) ? 0 : ($4 == br ? 1 : 2); print p "\t" $0 }' \
    | sort -t$'\t' -k1,1n -k2,2r > "$ORDERED_FILE"
fi
rm -f "$CAND_UNIQ"

CAND_COUNT=$(wc -l < "$ORDERED_FILE")
echo "共找到 $CAND_COUNT 个可用构建，按优先级逐个尝试（以 APK 文件名实测版本）..."

MANAGER_VERSION=""
MANAGER_BUILD_ID=""
MANAGER_HEAD_SHA=""
MANAGER_BRANCH=""
MANAGER_APK=""
while IFS=$'\t' read -r PRIO CREATED BUILD_ID CAND_SHA CAND_BRANCH; do
  ARTIFACTS=$(curl -s -H "Authorization: token $GH_TOKEN" \
    "https://api.github.com/repos/$REPO/actions/runs/$BUILD_ID/artifacts")
  CANDIDATE_LIST=$(get_manager_artifacts "$ARTIFACTS")
  if [ -z "$CANDIDATE_LIST" ]; then
    echo "跳过构建 $BUILD_ID ($CAND_BRANCH, $CREATED): 未找到包含 '$KSUM' 的产物"
    continue
  fi

  echo "下载构建 $BUILD_ID ($CAND_BRANCH, $CREATED, ${CAND_SHA:0:8}) 的产物..."
  rm -rf manager-artifacts
  mkdir -p manager-artifacts
  while IFS=$'\t' read -r NAME URL; do
    SAFE_NAME=$(echo "$NAME" | tr '/ ' '__')
    if ! curl -sL --fail -H "Authorization: token $GH_TOKEN" \
      -o "manager-artifacts/$SAFE_NAME.zip" "$URL"; then
      echo "下载 $NAME 失败"
      continue
    fi
    mkdir -p "manager-artifacts/$SAFE_NAME"
    unzip -oq "manager-artifacts/$SAFE_NAME.zip" -d "manager-artifacts/$SAFE_NAME" || echo "解压 $NAME 失败"
    rm -f "manager-artifacts/$SAFE_NAME.zip"
  done <<< "$CANDIDATE_LIST"

  # 从 APK 文件名提取实测 versionCode 作为 artifact 命名
  # 优先 arm64-v8a release（BakaSU 下游只保留这一个 ABI）
  APK_FILE=$(find manager-artifacts -type f -name "*-arm64-v8a-release.apk" | head -n 1)
  if [ -z "$APK_FILE" ]; then
    APK_FILE=$(find manager-artifacts -type f -name "*release.apk" ! -name "*debug*" | head -n 1)
  fi
  if [ -z "$APK_FILE" ]; then
    echo "跳过构建 $BUILD_ID ($CAND_BRANCH, $CREATED): artifact 中无 release APK"
    continue
  fi
  # 先剥离 ABI 段再提取版本，避免 x86_64 的 "_64" 等数字尾巴被误当成 versionCode
  CLEAN_NAME=$(basename "$APK_FILE" | sed -E 's/-(arm64-v8a|armeabi-v7a|armv7|riscv64|x86_64|x86|universal)-release\.apk$/.apk/')
  ACTUAL_VERSION=$(echo "$CLEAN_NAME" | grep -oE '_[0-9]+' | tail -n 1 | tr -d '_')
  if ! [[ "$ACTUAL_VERSION" =~ ^[0-9]+$ ]]; then
    echo "跳过构建 $BUILD_ID ($CAND_BRANCH, $CREATED): 无法从 APK 文件名解析版本 ($(basename "$APK_FILE"))"
    continue
  fi

  MANAGER_VERSION="$ACTUAL_VERSION"
  MANAGER_BUILD_ID="$BUILD_ID"
  MANAGER_HEAD_SHA="$CAND_SHA"
  MANAGER_BRANCH="$CAND_BRANCH"
  MANAGER_APK="$APK_FILE"
  break
done < "$ORDERED_FILE"
rm -f "$ORDERED_FILE"

if [ -z "$MANAGER_VERSION" ]; then
  echo "未获取到可用的 Manager artifact。"
  echo "ksuCommit=" >> $GITHUB_OUTPUT
  exit 1
fi
echo "选择 Manager 构建 $MANAGER_BUILD_ID ($MANAGER_BRANCH, ${MANAGER_HEAD_SHA:0:8}), APK 实测版本 $MANAGER_VERSION"
# 内核提交锁定策略：
#   正式 → 锁定该构建提交（版本与管理器严格一致）
#   最新 → 锁定选择时刻的默认分支 HEAD（管理器已按该版本匹配，二者一致）
PIN_COUNT=$(git -C KernelSU rev-list --count "$MANAGER_HEAD_SHA" 2>/dev/null || echo "")
if [ -n "$PIN_COUNT" ]; then
  case "$VARIANT" in
    BakaSU) PINNED_KSU_VERSION=$((30700 + PIN_COUNT)) ;;
    SukiSU-Nova) PINNED_KSU_VERSION=$((30000 + PIN_COUNT + 996)) ;;
    FinaSU) PINNED_KSU_VERSION=$((30000 + PIN_COUNT)) ;;
    *)      PINNED_KSU_VERSION="" ;;
  esac
  if [ -n "$PINNED_KSU_VERSION" ]; then
    echo "管理器构建提交 ${MANAGER_HEAD_SHA:0:8} 对应 KSU 版本: $PINNED_KSU_VERSION"
    if [ "$MANAGER_VERSION" != "$PINNED_KSU_VERSION" ]; then
      echo "::warning::Manager 实测版本 $MANAGER_VERSION 与构建提交对应的 KSU 版本 $PINNED_KSU_VERSION 不一致"
    fi
  elif [ -n "${KSU_VERSION:-}" ] && [ "$MANAGER_VERSION" != "$KSU_VERSION" ]; then
    echo "::warning::Manager 实测版本 $MANAGER_VERSION 与内核 KSU 版本 ${KSU_VERSION} 不一致"
  fi
elif [ -n "${KSU_VERSION:-}" ] && [ "$MANAGER_VERSION" != "$KSU_VERSION" ]; then
  echo "::warning::Manager 实测版本 $MANAGER_VERSION 与内核 KSU 版本 ${KSU_VERSION} 不一致（无法计算构建提交对应的版本）"
fi
echo "MANAGER_VERSION=$MANAGER_VERSION" >> $GITHUB_ENV
echo "managerVer=$MANAGER_VERSION" >> $GITHUB_OUTPUT

if [ "$VARIANT" == "FinaSU" ]; then
  echo "从 CI 管理器 APK 提取签名证书..."
  CERT_INFO=$(python3 "$GITHUB_WORKSPACE/scripts/finasu_compat/extract_manager_cert.py" "$MANAGER_APK" | head -n1)
  if [ -n "$CERT_INFO" ]; then
    CERT_SIZE=$(echo "$CERT_INFO" | awk '{print $1}')
    CERT_HASH=$(echo "$CERT_INFO" | awk '{print $2}')
    echo "managerCertSize=$CERT_SIZE" >> $GITHUB_OUTPUT
    echo "managerCertHash=$CERT_HASH" >> $GITHUB_OUTPUT
    echo "CI 管理器证书 size=$CERT_SIZE sha256=$CERT_HASH"
  else
    echo "::warning title=证书缺失::无法从 CI 管理器 APK 提取签名证书，内核侧将回退 Release APK 证书提取"
  fi
fi

if [ "${PIN_MODE:-pin}" = "head" ] && [ -n "$HEAD_SHA" ] && [ "$LATEST_PICK_BUILD" = 0 ]; then
  if [ -n "$HEAD_VERSION" ] && [ "$MANAGER_VERSION" != "$HEAD_VERSION" ]; then
    echo "::warning::最新通道：未找到与 $EXPECTED_BRANCH HEAD 版本 $HEAD_VERSION 一致的管理器，回退到 $MANAGER_VERSION"
  fi
  echo "最新通道：内核锁定 $EXPECTED_BRANCH HEAD ${HEAD_SHA:0:8}，管理器版本 $MANAGER_VERSION"
  echo "ksuCommit=$HEAD_SHA" >> $GITHUB_OUTPUT
else
  if [ "${PIN_MODE:-pin}" = "head" ] && [ "$LATEST_PICK_BUILD" = 1 ]; then
    echo "最新通道：内核锁定 build-manager 构建提交 ${MANAGER_HEAD_SHA:0:8}，管理器版本 $MANAGER_VERSION"
  else
    echo "内核锁定构建提交 ${MANAGER_HEAD_SHA:0:8}，管理器版本 $MANAGER_VERSION"
  fi
  echo "ksuCommit=$MANAGER_HEAD_SHA" >> $GITHUB_OUTPUT
fi

if [ "$VARIANT" == "BakaSU" ]; then
  echo "仅保留 BakaSU arm64-v8a release 管理器..."
  find manager-artifacts -type f -name "*.apk" ! -name "*-arm64-v8a-release.apk" -delete
  find manager-artifacts -type f -name "*debug*.apk" -delete
  if ! find manager-artifacts -type f -name "*-arm64-v8a-release.apk" | grep -q .; then
    echo "未找到 BakaSU arm64-v8a release 管理器。"
    exit 1
  fi
  find manager-artifacts -type f -name "*.apk" -print
fi
