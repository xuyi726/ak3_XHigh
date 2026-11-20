#!/usr/bin/env bash
# SukiSU-Nova 最新通道：从 Forgejo manager-ci Release / cnb.cool 镜像获取上游 CI 管理器。
# 由 get-manager.yml 的「添加 KernelSU」步骤调用。独立成文件是因为内联进 run 会超过
# GitHub 单脚本 21000 字符的模板上限，整个 workflow 会被判无效。
# 成功：写入 GITHUB_ENV / GITHUB_OUTPUT 并退出 0；失败：退出 1，由调用方回退
# GitHub Actions 通道查询。上游 GitHub 镜像的 build-manager.yml 已删除，
# manager.yml 在 GitHub 上从未运行，因此不再产出 Actions artifact。
# Release 资产为空时 APK 在 cnb.cool 镜像页分发；Release 的 target_commitish
# 即构建提交，这里按 APK 文件名实测 versionCode，并以该提交的 Forgejo 提交计数
# （30000 + 提交数 + 996）做版本自检。

NOVA_API="https://git.zako.shirkneko.top:20004/api/v1/repos/shirkneko/SukiSU"

NOVA_REL=""
for ATTEMPT in 1 2 3; do
  NOVA_REL=$(curl -s --fail --max-time 30 "$NOVA_API/releases/tags/manager-ci") \
    && [ -n "$NOVA_REL" ] && break
  echo "获取 manager-ci Release 信息失败，重试 ($ATTEMPT/3)..."
  NOVA_REL=""
  sleep 5
done

NOVA_PIN=""
NOVA_ASSET_URL=""
if [ -n "$NOVA_REL" ]; then
  NOVA_REL_NAME=$(printf '%s' "$NOVA_REL" | jq -r '.name // empty' || true)
  NOVA_PIN=$(printf '%s' "$NOVA_REL" | jq -r '.target_commitish // empty' || true)
  echo "manager-ci Release: ${NOVA_REL_NAME:-未知}，构建提交 ${NOVA_PIN:0:8}"
  # target_commitish 可能是分支名，统一解析为提交 SHA
  if [ -n "$NOVA_PIN" ] && ! printf '%s' "$NOVA_PIN" | grep -qE '^[0-9a-f]{40}$'; then
    NOVA_PIN=$(curl -s --fail --max-time 30 "$NOVA_API/branches/$NOVA_PIN" | jq -r '.commit.id // empty' || true)
  fi
  if [ -n "$NOVA_PIN" ]; then
    NOVA_PIN_SHA=$(curl -s --fail --max-time 30 "$NOVA_API/git/commits/$NOVA_PIN" | jq -r '.sha // empty' || true)
    if [ "$NOVA_PIN_SHA" != "$NOVA_PIN" ]; then
      echo "::warning::manager-ci 目标提交 $NOVA_PIN 在 Forgejo 上无法解析，跳过锁定"
      NOVA_PIN=""
    fi
  fi
  # 优先 Release 自带资产（若上游恢复上传），否则翻 cnb.cool 镜像页发现 APK
  NOVA_ASSET=""
  for SEL in arm64-v8a ""; do
    if [ -n "$SEL" ]; then
      NOVA_ASSET=$(printf '%s' "$NOVA_REL" | jq -r '.assets[]? | "\(.name)\t\(.browser_download_url)"' | grep -i '\.apk' | grep "$SEL" | head -n1 || true)
    else
      NOVA_ASSET=$(printf '%s' "$NOVA_REL" | jq -r '.assets[]? | "\(.name)\t\(.browser_download_url)"' | grep -i '\.apk' | head -n1 || true)
    fi
    if [ -n "$NOVA_ASSET" ]; then
      break
    fi
  done
  if [ -n "$NOVA_ASSET" ]; then
    NOVA_ASSET_URL=$(printf '%s' "$NOVA_ASSET" | cut -f2)
  else
    CNB_PAGE=$(curl -sL --fail --max-time 40 "https://cnb.cool/shirkneko/sukisu-result/-/releases/tag/manager-ci" || true)
    NOVA_PATH=""
    for SEL in arm64-v8a ""; do
      if [ -n "$SEL" ]; then
        NOVA_PATH=$(printf '%s' "$CNB_PAGE" | grep -oE 'releases/download/manager-ci/[A-Za-z0-9._-]+\.apk' | sort -u | grep "$SEL" | head -n1 || true)
      else
        NOVA_PATH=$(printf '%s' "$CNB_PAGE" | grep -oE 'releases/download/manager-ci/[A-Za-z0-9._-]+\.apk' | sort -u | head -n1 || true)
      fi
      if [ -n "$NOVA_PATH" ]; then
        break
      fi
    done
    if [ -n "$NOVA_PATH" ]; then
      NOVA_ASSET_URL="https://cnb.cool/shirkneko/sukisu-result/-/$NOVA_PATH"
    fi
  fi
fi

NOVA_APK=""
if [ -n "$NOVA_ASSET_URL" ]; then
  mkdir -p manager-artifacts
  NOVA_APK="manager-artifacts/$(basename "$NOVA_ASSET_URL")"
  if ! curl -sL --fail --retry 3 --max-time 300 -o "$NOVA_APK" "$NOVA_ASSET_URL"; then
    echo "下载 manager-ci 管理器失败: $NOVA_ASSET_URL"
    NOVA_APK=""
  fi
fi

NOVA_VERSION=""
if [ -n "$NOVA_APK" ]; then
  CLEAN_NAME=$(basename "$NOVA_APK" | sed -E 's/-(arm64-v8a|armeabi-v7a|armv7|riscv64|x86_64|x86|universal)-release\.apk$/.apk/')
  NOVA_VERSION=$(echo "$CLEAN_NAME" | grep -oE '_[0-9]+' | tail -n 1 | tr -d '_' || true)
  if ! [[ "$NOVA_VERSION" =~ ^[0-9]+$ ]]; then
    echo "无法从 manager-ci APK 文件名解析版本 ($(basename "$NOVA_APK"))"
    NOVA_VERSION=""
  fi
fi

if [ -n "$NOVA_VERSION" ] && [ -n "$NOVA_PIN" ]; then
  # 版本自检：Forgejo 提交计数与 APK 实测 versionCode 应一致
  NOVA_PIN_COUNT=$(curl -s -D - -o /dev/null --max-time 30 "$NOVA_API/commits?sha=$NOVA_PIN&limit=1" | tr -d '\r' | sed -n 's/^[Xx]-[Tt]otal-[Cc]ount:[[:space:]]*\([0-9]*\).*/\1/p')
  if [ -n "$NOVA_PIN_COUNT" ]; then
    NOVA_PIN_VERSION=$((30000 + NOVA_PIN_COUNT + 996))
    echo "manager-ci 构建提交 ${NOVA_PIN:0:8} 对应 KSU 版本: $NOVA_PIN_VERSION，APK 实测版本: $NOVA_VERSION"
    if [ "$NOVA_VERSION" != "$NOVA_PIN_VERSION" ]; then
      echo "::warning::Manager 实测版本 $NOVA_VERSION 与 manager-ci 构建提交对应的 KSU 版本 $NOVA_PIN_VERSION 不一致（滚动 Release 可能刚更新，重跑即可）"
    fi
  else
    echo "::warning::无法通过 Forgejo API 计算构建提交 $NOVA_PIN 对应的 KSU 版本（APK 实测版本 $NOVA_VERSION）"
  fi
  echo "MANAGER_VERSION=$NOVA_VERSION" >> "$GITHUB_ENV"
  echo "managerVer=$NOVA_VERSION" >> "$GITHUB_OUTPUT"
  echo "ksuCommit=$NOVA_PIN" >> "$GITHUB_OUTPUT"
  echo "SukiSU-Nova 最新通道：管理器 $NOVA_VERSION，内核锁定 ${NOVA_PIN:0:8}"
  exit 0
fi

exit 1
