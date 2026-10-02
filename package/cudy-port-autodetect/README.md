# Cudy TR3000 网口自动识别插件

此 OpenWrt 软件包管理 TR3000 v1 的 `eth0`（2.5G）和 `eth1`（1G），通过物理链路和 DHCP 探测自动分配角色。两个构建配置都预装插件，首次启动会备份并初始化网络和防火墙配置。

| 接线 | 结果 |
| --- | --- |
| 一根上联网线、一台终端，位置任意 | 有有效上级 DHCP 和默认网关的口成为 WAN，另一口成为 LAN |
| 两根上联网线 | 双 WAN 主备，优先 eth0；主出口失效后切换 eth1，恢复后切回 |
| 两台终端 | 两个口均加入 br-lan，终端可以访问现有 WiFi 和管理网络 |
| 没有插线 | 网口退出当前角色，等待重新插线 |

双 LAN 模式本身没有外网上联；只有另外配置了 WiFi 等上联才能上网。插件保持现有 WiFi、LAN 管理地址和防火墙规则，只初始化两个有线 WAN 接口及其 WAN 区域成员。

## 检测规则与范围

- 本版支持 DHCP 上联。PPPoE、静态地址及带 VLAN 的上联不能直接自动识别，也不按此方式自动拨号。
- 检测期间网口暂时隔离；每口 DHCP 探测最多约 8 秒，两个口依次检测。没有收到 DHCP 响应时才作为 LAN。首次接线需要等待检测结束。
- 收到 DHCP 响应但没有有效默认网关，或租约与管理网段重叠，会隔离该口并记录错误。终端如果自身提供 DHCP，可能被识别为上联；只有线路上的报文无法保证识别设备的用途。
- LAN 口在重新插拔后再次识别。上级 DHCP 服务在完全没有链路变化的情况下延迟启动，不会触发 LAN 口自动重识别，需要重新插拔网线。
- 每 10 秒对每个 WAN 绑定接口检测 `223.5.5.5` 和 `119.29.29.29`；连续 3 轮失败标记故障，连续 2 轮成功恢复。所有出口均无法响应 ICMP 时，保留当前有效租约出口，状态中继续显示检测失败。
- 双 WAN 是主备切换。切换 NAT 出口可能中断现有连接。IPv6 只启动当前所选 WAN 的 DHCPv6；切换后地址和前缀需要重新获取。
- 运行状态、租约和日志写入 RAM，不因每次插拔写入闪存。首选 IPv4 默认路由使用协议号 242、metric 5；遇到其他服务占用该优先级会报告冲突并拒绝覆盖。
- 运行期间不要由其他插件同时修改这两个物理口的桥接归属或出口路由。本版没有 LuCI 页面，通过命令和日志查看状态。

## 构建与安装

原有 GitHub Actions 构建流程会通过 `diy-part2.sh` 调用 `scripts/prepare-port-autodetect.sh`，加入软件包并应用 PHY 补丁。补丁与上游不匹配、缺少 BusyBox 功能或存在同名软件包时，构建会明确失败。

也可以在已有 Linux OpenWrt 源码环境中单独打包纯脚本插件：

```sh
python3 scripts/build-port-autodetect-package.py \
  --ipkg-build /path/to/openwrt/scripts/ipkg-build --output /path/to/output
```

生成的 `cudy-port-autodetect_1.0.0-1_all.ipk` 依赖 `ip-full`、`jsonfilter`、`jshn`。在支持的 TR3000 v1 系统上安装会立即初始化配置并启动服务，网口会暂时断开，请通过现有 WiFi 管理连接操作。

```sh
opkg install /tmp/cudy-port-autodetect_1.0.0-1_all.ipk
cudy-port-autodetect status
logread -e cudy-port-autodetect
```

## 2.5G PHY 修复

`patches/001-cudy-tr3000-phy-reset.patch` 将 GPIO 39 的复位配置移到 MDIO 总线，使 PHY 在探测前释放复位，同时启用上游已经回移的 Motorcomm YT8821 驱动。保留 Realtek 驱动以支持不同硬件批次。

**IPK 只包含网口自动识别服务。PHY 修复属于设备树和内核配置，必须重新构建并刷入相应固件才能生效。** 本项目覆盖 256MB 和 U-Boot Mod 两个目标；刷机文件必须匹配设备的实际分区布局。

当前已有路由器日志显示 `eth0` 无法绑定 PHY（`-EINVAL`）。此补丁针对复位时序和驱动缺失这两个有证据支持的原因；仍需刷机后检查 PHY 驱动绑定、链路协商及实际吞吐，不能仅根据源码或 DTB 编译判定硬件故障已修复。

## 停用与恢复

首次初始化的原配置位于 `/etc/cudy-port-autodetect/network.backup` 和 `firewall.backup`，同时加入 sysupgrade 保留列表。自动恢复会校验初始化后的配置摘要；有未保存修改或后续网络、防火墙修改时拒绝覆盖。

```sh
cudy-port-autodetect restore
```

上述命令停止并禁用服务、恢复安装前的网络与防火墙配置。要再次启用：

```sh
uci set cudy-port-autodetect.main.enabled=1
uci commit cudy-port-autodetect
cudy-port-autodetect configure
/etc/init.d/cudy-port-autodetect enable
/etc/init.d/cudy-port-autodetect restart
```

单独停止服务只清理插件首选路由，已识别的接口仍由 netifd 管理；完全恢复原有接口分工应使用 `restore`。卸载软件包前也应先恢复。

## 验证

`tests/test_port_autodetect.py` 检查角色、非法租约、错误路径及切换门限。`tests/network_integration.py` 在独立 Linux 网络、挂载命名空间中，用 BusyBox 1.36.1 的真实 udhcpc、DHCP 报文、桥和内核路由验证四种接线、相同上级网段的双 WAN、主备切换及快速插拔；需要 root 和 Linux 命名空间。测试中的 netifd 地址管理使用第二次真实 DHCP 握手的适配器，未覆盖真实 OpenWrt netifd、防火墙和 IPv6。

`tests/uci_integration.py` 使用原版 UCI CLI 与构建分支的配置函数，在临时目录验证初始化、备份、回滚、重复初始化及拒绝覆盖。完整固件构建、实际路由器运行、IPv6 和 2.5G 硬件验证仍需在相应环境进行。
