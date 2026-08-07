#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#
# Copyright (c) 2019-2024 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

# Modify default LAN IP
sed -i 's/192.168.1.1/192.168.6.1/g' package/base-files/files/bin/config_generate

mkdir -p files/etc/uci-defaults

# 默认登录密码
ROOT_PASSWORD_HASH="$(openssl passwd -1 -salt cudyroot root)"
cat > files/etc/uci-defaults/01-set-root-password <<EOF
#!/bin/sh

sed -i 's#^root:[^:]*:#root:${ROOT_PASSWORD_HASH}:#' /etc/shadow
exit 0
EOF
chmod 0755 files/etc/uci-defaults/01-set-root-password

# Modify default theme
#sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile

# Remove missing luci-app-radicale3 dependency warning
RADICALE3_MAKEFILE="feeds/luci/applications/luci-app-radicale3/Makefile"
if [ -f "$RADICALE3_MAKEFILE" ]; then
  sed -i 's/ +rpcd-mod-rad3-enc//' "$RADICALE3_MAKEFILE"
fi

# Preinstall OpenClash Meta core
OPENCLASH_CORE_DIR="files/etc/openclash/core"
OPENCLASH_CORE_TMP="$(mktemp /tmp/clash-linux-arm64.XXXXXX.tar.gz)"
OPENCLASH_CORE_BIN="$(mktemp /tmp/clash_meta.XXXXXX)"
OPENCLASH_CORE_URLS="
https://fastly.jsdelivr.net/gh/vernesong/OpenClash@core/master/meta/clash-linux-arm64.tar.gz
https://testingcf.jsdelivr.net/gh/vernesong/OpenClash@core/master/meta/clash-linux-arm64.tar.gz
https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz
"
OPENCLASH_CORE_OK=0
mkdir -p "$OPENCLASH_CORE_DIR"
for OPENCLASH_CORE_URL in $OPENCLASH_CORE_URLS; do
  echo "[INFO] 下载 OpenClash Meta 核心：$OPENCLASH_CORE_URL"
  rm -f "$OPENCLASH_CORE_TMP" "$OPENCLASH_CORE_BIN"
  if wget -T 30 -O "$OPENCLASH_CORE_TMP" "$OPENCLASH_CORE_URL" \
    && [ "$(wc -c < "$OPENCLASH_CORE_TMP")" -gt 1048576 ] \
    && tar -tzf "$OPENCLASH_CORE_TMP" clash >/dev/null 2>&1 \
    && tar -zxOf "$OPENCLASH_CORE_TMP" clash > "$OPENCLASH_CORE_BIN" \
    && [ "$(wc -c < "$OPENCLASH_CORE_BIN")" -gt 1048576 ] \
    && readelf -h "$OPENCLASH_CORE_BIN" | grep -q 'AArch64'; then
    install -m 4755 "$OPENCLASH_CORE_BIN" "$OPENCLASH_CORE_DIR/clash_meta"
    OPENCLASH_CORE_OK=1
    break
  fi
done
rm -f "$OPENCLASH_CORE_TMP" "$OPENCLASH_CORE_BIN"
if [ "$OPENCLASH_CORE_OK" != "1" ]; then
  echo "[ERROR] OpenClash Meta 核心下载或校验失败"
  exit 1
fi

# Optimize OpenClash Meta runtime defaults without changing proxy groups.
OPENCLASH_CUSTOM_DIR="files/etc/openclash/custom"
mkdir -p "$OPENCLASH_CUSTOM_DIR"
cat > "$OPENCLASH_CUSTOM_DIR/openclash_custom_overwrite.sh" <<'EOF'
#!/bin/sh
. /usr/share/openclash/ruby.sh
. /usr/share/openclash/log.sh

CONFIG_FILE="$1"
LOG_FILE="/tmp/openclash.log"

ruby -ryaml -e '
config = ARGV[0]
value = YAML.load_file(config) || {}
value["tcp-concurrent"] = true
value["unified-delay"] = true
value["profile"] ||= {}
value["profile"]["store-fake-ip"] = true
value["dns"] ||= {}
value["dns"]["cache-algorithm"] = "arc"
File.open(config, "w") { |file| YAML.dump(value, file) }
' "$CONFIG_FILE" 2>>"$LOG_FILE"

exit 0
EOF
chmod 0755 "$OPENCLASH_CUSTOM_DIR/openclash_custom_overwrite.sh"

# Modify default WiFi
MTWIFI_SCRIPT="package/mtk/applications/mtwifi-cfg/files/mtwifi.sh"
if [ -f "$MTWIFI_SCRIPT" ]; then
  sed -i 's/ssid="ImmortalWrt-2.4G"/ssid="Cudy-TR3000"/' "$MTWIFI_SCRIPT"
  sed -i 's/ssid="ImmortalWrt-5G"/ssid="Cudy-TR3000"/' "$MTWIFI_SCRIPT"
  sed -i '/set wireless.${dev}.wapp=0/s/=0/=1/' "$MTWIFI_SCRIPT"
  sed -i '/set wireless.default_${dev}.encryption=none/a\					set wireless.default_${dev}.key=1234567890' "$MTWIFI_SCRIPT"
  sed -i 's/set wireless.default_${dev}.encryption=none/set wireless.default_${dev}.encryption=psk2+ccmp/' "$MTWIFI_SCRIPT"
fi

# Modify hostname
sed -i "s/hostname='ImmortalWrt'/hostname='Cudy-TR3000'/" package/base-files/files/bin/config_generate

# 修复 Rust 编译失败：强制关闭 download-ci-llvm
sed -i 's/$(TARGET_CONFIGURE_ARGS)/--set llvm.download-ci-llvm=false \\\n\t$(TARGET_CONFIGURE_ARGS)/' feeds/packages/lang/rust/Makefile
