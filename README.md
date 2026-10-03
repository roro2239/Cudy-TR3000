**English** | [中文](https://p3terx.com/archives/build-openwrt-with-github-actions.html)

# Actions-OpenWrt

[![LICENSE](https://img.shields.io/github/license/mashape/apistatus.svg?style=flat-square&label=LICENSE)](https://github.com/P3TERX/Actions-OpenWrt/blob/master/LICENSE)
![GitHub Stars](https://img.shields.io/github/stars/P3TERX/Actions-OpenWrt.svg?style=flat-square&label=Stars&logo=github)
![GitHub Forks](https://img.shields.io/github/forks/P3TERX/Actions-OpenWrt.svg?style=flat-square&label=Forks&logo=github)
![Downloads](https://img.shields.io/github/downloads/clfang666/tr3000-open/total)

A template for building OpenWrt with GitHub Actions

## TR3000 基础网络与网口修复

两个固件目标均使用系统原有的固定网口分工：2.5G 口（`eth0`）为 WAN，1G 口（`eth1`）为 LAN，WAN 使用 DHCP 上网。保留现有 WiFi、管理地址和 OpenClash 配置，IPv6 使用系统默认行为。

`diy-part2.sh` 调用 `scripts/prepare-network-fixes.sh`，修正上游错误的 `ifdown` 文件，并应用两项 PHY 修复：

- `patches/001-cudy-tr3000-phy-reset.patch` 将 GPIO 39 复位移到 MDIO 总线，使复位在扫描前完成，保留 Realtek 驱动并启用 Motorcomm 驱动。
- `patches/002-cudy-tr3000-realtek-reset.patch` 加入 MediaTek 内核补丁队列。仅在这两个 TR3000 型号的外置 Realtek PHY 初始化超时、PHY 节点没有复位资源时，使用总线持有的 GPIO 按设备树延时复位并重试一次，保留超时和复位日志。

上游内容不匹配或内核补丁目标已有不同内容时，构建准备会明确失败。驱动补丁与 GPIO 所有权修复须一起使用，重新构建并刷入对应固件后才能在设备生效。未刷入前，现有固件的 SerDes 超时问题仍可能发生。

`tests/build_preparation.py --upstream /path/to/openwrt` 在临时目录验证两个构建配置的修复、重复执行和拒绝覆盖路径。`tests/realtek_reset.py --upstream /path/to/openwrt` 从上游补丁还原驱动，验证补丁应用与恢复分支。测试需要 Linux、Python 3、GNU patch 和 C 编译器。完整固件编译及网口硬件运行需要单独验证。

## Usage

- Click the [Use this template](https://github.com/P3TERX/Actions-OpenWrt/generate) button to create a new repository.
- Generate `.config` files using [Lean's OpenWrt](https://github.com/coolsnowwolf/lede) source code. ( You can change it through environment variables in the workflow file. )
- Push `.config` file to the GitHub repository.
- Select `Build OpenWrt` on the Actions page.
- Click the `Run workflow` button.
- When the build is complete, click the `Artifacts` button in the upper right corner of the Actions page to download the binaries.

## Tips

- It may take a long time to create a `.config` file and build the OpenWrt firmware. Thus, before create repository to build your own firmware, you may check out if others have already built it which meet your needs by simply [search `Actions-Openwrt` in GitHub](https://github.com/search?q=Actions-openwrt).
- Add some meta info of your built firmware (such as firmware architecture and installed packages) to your repository introduction, this will save others' time.

## Credits

- [Microsoft Azure](https://azure.microsoft.com)
- [GitHub Actions](https://github.com/features/actions)
- [OpenWrt](https://github.com/openwrt/openwrt)
- [coolsnowwolf/lede](https://github.com/coolsnowwolf/lede)
- [Mikubill/transfer](https://github.com/Mikubill/transfer)
- [softprops/action-gh-release](https://github.com/softprops/action-gh-release)
- [Mattraks/delete-workflow-runs](https://github.com/Mattraks/delete-workflow-runs)
- [dev-drprasad/delete-older-releases](https://github.com/dev-drprasad/delete-older-releases)
- [peter-evans/repository-dispatch](https://github.com/peter-evans/repository-dispatch)

## License

[MIT](https://github.com/P3TERX/Actions-OpenWrt/blob/main/LICENSE) © [**P3TERX**](https://p3terx.com)
