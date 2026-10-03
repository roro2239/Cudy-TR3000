#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PHY_PATCH="$PROJECT_DIR/patches/001-cudy-tr3000-phy-reset.patch"
DRIVER_PATCH="$PROJECT_DIR/patches/002-cudy-tr3000-realtek-reset.patch"
KERNEL_PATCH_DIR="target/linux/mediatek/patches-6.6"
KERNEL_PATCH="$KERNEL_PATCH_DIR/9999-06-cudy-tr3000-realtek-reset.patch"
NETIFD_IFDOWN="package/network/config/netifd/files/sbin/ifdown"
IFDOWN_FIX=0

[ -d "$KERNEL_PATCH_DIR" ] && [ -f "$DRIVER_PATCH" ] || {
  echo '[错误] 缺少内核补丁目录或 TR3000 驱动补丁。' >&2
  exit 1
}
if [ -e "$KERNEL_PATCH" ] || [ -L "$KERNEL_PATCH" ]; then
  if [ -L "$KERNEL_PATCH" ] || [ ! -f "$KERNEL_PATCH" ] \
    || ! cmp -s "$DRIVER_PATCH" "$KERNEL_PATCH"; then
    echo '[错误] 内核补丁目标已有不同内容，拒绝覆盖。' >&2
    exit 1
  fi
fi

# 此构建分支把 ifdown 符号链接存成了普通文件，不能直接复制进固件。
if [ -L "$NETIFD_IFDOWN" ] && [ "$(readlink "$NETIFD_IFDOWN")" = ifup ]; then
  :
elif [ ! -L "$NETIFD_IFDOWN" ] && [ -f "$NETIFD_IFDOWN" ] \
  && [ "$(cat "$NETIFD_IFDOWN")" = ifup ]; then
  IFDOWN_FIX=1
else
  echo '[错误] 上游 ifdown 内容或链接目标不符合预期，拒绝覆盖。' >&2
  exit 1
fi
[ -f "${NETIFD_IFDOWN%/*}/ifup" ] || {
  echo '[错误] 上游缺少 ifup，无法修复 ifdown。' >&2
  exit 1
}

# 上游变更不匹配时必须中止构建，不能静默跳过 PHY 修复。
if patch --batch --forward --fuzz=0 -p1 --dry-run < "$PHY_PATCH" >/dev/null 2>&1; then
  patch --batch --forward --fuzz=0 -p1 < "$PHY_PATCH"
elif patch --batch --forward --fuzz=0 -R -p1 --dry-run < "$PHY_PATCH" >/dev/null 2>&1; then
  echo '[信息] Cudy TR3000 PHY 补丁已经应用。'
else
  echo '[错误] 上游 PHY 配置与补丁不匹配，请检查源码变化。' >&2
  exit 1
fi

if [ "$IFDOWN_FIX" = 1 ]; then
  rm "$NETIFD_IFDOWN"
  ln -s ifup "$NETIFD_IFDOWN"
fi
[ -L "$NETIFD_IFDOWN" ] && [ "$(readlink "$NETIFD_IFDOWN")" = ifup ] || {
  echo '[错误] ifdown 符号链接校验失败。' >&2
  exit 1
}

if [ ! -f "$KERNEL_PATCH" ]; then
  install -m 0644 "$DRIVER_PATCH" "$KERNEL_PATCH"
fi

echo '[信息] 已应用 ifdown 和 2.5G PHY 修复，保留系统原有网络配置。'
