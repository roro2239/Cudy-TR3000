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

# 默认启用 IPv6
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-enable-ipv6 <<'EOF'
#!/bin/sh

if uci -q get network.wan >/dev/null; then
  uci set network.wan.ipv6='1'
fi

uci -q get network.wan6 >/dev/null || uci set network.wan6='interface'
uci set network.wan6.proto='dhcpv6'
uci set network.wan6.device='@wan'
uci set network.wan6.reqaddress='try'
uci set network.wan6.reqprefix='auto'

if uci -q get network.lan >/dev/null; then
  uci set network.lan.ip6assign='60'
fi

if uci -q get dhcp.lan >/dev/null; then
  uci set dhcp.lan.ra='server'
  uci set dhcp.lan.dhcpv6='server'
  uci set dhcp.lan.ra_slaac='1'
  uci set dhcp.lan.ra_default='2'
  uci -q delete dhcp.lan.ndp
  uci -q delete dhcp.lan.ra_flags
  uci add_list dhcp.lan.ra_flags='managed-config'
  uci add_list dhcp.lan.ra_flags='other-config'
fi

uci -q delete dhcp.wan6

uci -q get dhcp.odhcpd >/dev/null || uci set dhcp.odhcpd='odhcpd'
uci set dhcp.odhcpd.maindhcp='0'
uci set dhcp.odhcpd.leasefile='/tmp/hosts/odhcpd'
uci set dhcp.odhcpd.leasetrigger='/usr/sbin/odhcpd-update'
uci set dhcp.odhcpd.loglevel='4'

WAN_ZONE="$(uci show firewall | sed -n "s/^\(firewall\.[^=]*\)\.name='wan'$/\1/p" | head -n 1)"
[ -n "$WAN_ZONE" ] && uci set "$WAN_ZONE.masq6=1"

uci commit network
uci commit dhcp
uci commit firewall
exit 0
EOF
chmod 0755 files/etc/uci-defaults/99-enable-ipv6

# 修正无前缀委派场景下的 IPv6 NAT6 出口
mkdir -p files/etc/hotplug.d/iface
cat > files/etc/hotplug.d/iface/99-fix-ipv6-default-route <<'EOF'
#!/bin/sh

[ "$INTERFACE" = "wan6" ] || exit 0
case "$ACTION" in
  ifup|ifupdate) ;;
  *) exit 0 ;;
esac

WAN6_DEV="$(ubus call network.interface.wan6 status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)"
[ -n "$WAN6_DEV" ] || WAN6_DEV="$(uci -q get network.wan6.device)"
[ "$WAN6_DEV" = "@wan" ] && WAN6_DEV="$(uci -q get network.wan.device)"
[ -n "$WAN6_DEV" ] || WAN6_DEV="eth0"
TEST_ADDR="2400:3200::1"

find_gateway() {
  for gw in $(ip -6 neigh show dev "$WAN6_DEV" | awk '/ router / {print $1}') fe80::5 fe80::1; do
    [ -n "$gw" ] || continue
    ping -6 -c 1 -W 1 -I "$WAN6_DEV" "$gw" >/dev/null 2>&1 && echo "$gw" && return 0
  done
  return 1
}

find_source() {
  gw="$1"
  ip -6 addr show dev "$WAN6_DEV" scope global | awk '/inet6/ { split($2, addr, "/"); if (addr[1] !~ /^f/) print addr[1] }' | while read addr; do
    [ -n "$addr" ] || continue
    ip -6 route replace default from "$addr/128" via "$gw" dev "$WAN6_DEV" metric 100
    ping -6 -c 1 -W 2 -I "$addr" "$TEST_ADDR" >/dev/null 2>&1 && echo "$addr" && return 0
  done
}

setup_nat6() {
  gw="$1"
  src="$2"
  ip -6 route replace default via "$gw" dev "$WAN6_DEV" metric 100
  ip -6 addr show dev "$WAN6_DEV" scope global | awk '/inet6/ {
    split($2, addr, "/");
    split(addr[1], part, ":");
    if (part[1] != "" && part[1] !~ /^f/) {
      printf "%s:%s:%s:%s::/64\n", part[1], part[2], part[3], part[4];
    }
  }' | sort -u | while read prefix; do
    [ -n "$prefix" ] && ip -6 route replace default from "$prefix" via "$gw" dev "$WAN6_DEV" metric 100
  done

  nft delete table inet codex_nat6 2>/dev/null
  nft add table inet codex_nat6
  nft 'add chain inet codex_nat6 postrouting { type nat hook postrouting priority 90; policy accept; }'
  nft add rule inet codex_nat6 postrouting iifname br-lan oifname "$WAN6_DEV" ip6 saddr fd00::/8 snat ip6 to "$src"
  nft add rule inet codex_nat6 postrouting iifname br-lan oifname "$WAN6_DEV" ip6 saddr 2000::/3 snat ip6 to "$src"

  mkdir -p /etc/nftables.d
  cat > /etc/nftables.d/99-codex-nat6.nft <<EONFT
chain codex_nat6_postrouting {
  type nat hook postrouting priority srcnat - 10; policy accept;
  iifname "br-lan" oifname "$WAN6_DEV" ip6 saddr fd00::/8 snat ip6 to $src
  iifname "br-lan" oifname "$WAN6_DEV" ip6 saddr 2000::/3 snat ip6 to $src
}
EONFT

  logger -t ipv6-route "nat6 fixed via $gw on $WAN6_DEV source $src"
}

for i in 1 2 3 4 5; do
  GW="$(find_gateway)"
  if [ -n "$GW" ]; then
    SRC="$(find_source "$GW" | tail -n 1)"
    if [ -n "$SRC" ]; then
      setup_nat6 "$GW" "$SRC"
      exit 0
    fi
  fi
  sleep 2
done

logger -t ipv6-route "no reachable IPv6 NAT6 source found on $WAN6_DEV"
exit 0
EOF
chmod 0755 files/etc/hotplug.d/iface/99-fix-ipv6-default-route

# Modify default theme
#sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile

# Remove missing luci-app-radicale3 dependency warning
RADICALE3_MAKEFILE="feeds/luci/applications/luci-app-radicale3/Makefile"
if [ -f "$RADICALE3_MAKEFILE" ]; then
  sed -i 's/ +rpcd-mod-rad3-enc//' "$RADICALE3_MAKEFILE"
fi

# Preinstall OpenClash Meta core
OPENCLASH_CORE_DIR="files/etc/openclash/core"
OPENCLASH_CORE_TMP="/tmp/clash-linux-arm64.tar.gz"
OPENCLASH_CORE_URL="https://raw.githubusercontent.com/vernesong/OpenClash/core/master/meta/clash-linux-arm64.tar.gz"
mkdir -p "$OPENCLASH_CORE_DIR"
wget -O "$OPENCLASH_CORE_TMP" "$OPENCLASH_CORE_URL"
tar -zxOf "$OPENCLASH_CORE_TMP" clash > "$OPENCLASH_CORE_DIR/clash_meta"
chmod 0755 "$OPENCLASH_CORE_DIR/clash_meta"
rm -f "$OPENCLASH_CORE_TMP"

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
