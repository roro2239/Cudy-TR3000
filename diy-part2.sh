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

# Modify default IP
sed -i 's/192.168.1.1/10.0.0.1/g' package/base-files/files/bin/config_generate
sed -i 's/192.168.6.1/10.0.0.1/g' package/base-files/files/bin/config_generate

# Modify default theme
#sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile

# Remove missing luci-app-radicale3 dependency warning
RADICALE3_MAKEFILE="feeds/luci/applications/luci-app-radicale3/Makefile"
if [ -f "$RADICALE3_MAKEFILE" ]; then
  sed -i 's/ +rpcd-mod-rad3-enc//' "$RADICALE3_MAKEFILE"
fi

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
#sed -i 's/OpenWrt/P3TERX-Router/g' package/base-files/files/bin/config_generate

# 修复 Rust 编译失败：强制关闭 download-ci-llvm
sed -i 's/$(TARGET_CONFIGURE_ARGS)/--set llvm.download-ci-llvm=false \\\n\t$(TARGET_CONFIGURE_ARGS)/' feeds/packages/lang/rust/Makefile
