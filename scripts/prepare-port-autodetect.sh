#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PHY_PATCH="$PROJECT_DIR/patches/001-cudy-tr3000-phy-reset.patch"
PACKAGE_SOURCE="$PROJECT_DIR/package/cudy-port-autodetect"
PACKAGE_TARGET="package/cudy-port-autodetect"

if [ -e "$PACKAGE_TARGET" ]; then
  echo '[错误] 构建源码已有同名网口插件，拒绝覆盖。' >&2
  exit 1
fi
grep -q '^CONFIG_PACKAGE_cudy-port-autodetect=y' .config || {
  echo '[错误] 构建配置没有启用网口自动识别插件。' >&2
  exit 1
}
for option in UDHCPC FLOCK; do
  grep -q "^CONFIG_BUSYBOX_CONFIG_${option}=y" .config || {
    echo "[错误] BusyBox 未启用必要功能：$option" >&2
    exit 1
  }
done

# 上游变更不匹配时必须中止构建，不能静默跳过 PHY 修复。
if patch --batch --fuzz=0 -p1 --dry-run < "$PHY_PATCH" >/dev/null 2>&1; then
  patch --batch --fuzz=0 -p1 < "$PHY_PATCH"
elif patch --batch --fuzz=0 -R -p1 --dry-run < "$PHY_PATCH" >/dev/null 2>&1; then
  echo '[信息] Cudy TR3000 PHY 补丁已经应用。'
else
  echo '[错误] 上游 PHY 配置与补丁不匹配，请检查源码变化。' >&2
  exit 1
fi

cp -a "$PACKAGE_SOURCE" "$PACKAGE_TARGET"
echo '[信息] 已加入网口自动识别插件和 2.5G PHY 修复。'
