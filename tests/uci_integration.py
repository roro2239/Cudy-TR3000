#!/usr/bin/env python3
"""使用原版 UCI CLI 和 OpenWrt 配置函数验证初始化与恢复，不操作宿主机配置。"""
import argparse
import os
import shlex
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COMMON = ROOT / "package/cudy-port-autodetect/files/common.sh"


def check_case(native, upstream, case):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        config = root / "etc/config"
        config.mkdir(parents=True)
        (root / "delta").mkdir()
        (root / "state").mkdir()
        network = """config device 'bridge'
 option name 'br-lan'
 option type 'bridge'
 list ports 'eth1'
 list ports 'eth2'
config device 'guest'
 option name 'br-guest'
 option type 'bridge'
config interface 'lan'
 option device 'br-lan'
 option proto 'static'
 option ipaddr '192.168.6.1'
 option netmask '255.255.255.0'
config interface 'wan'
 option device 'eth0'
 option proto 'dhcp'
config interface 'wan6'
 option device 'eth0'
 option proto 'dhcpv6'
"""
        firewall = """config zone
 option name 'lan'
 list network 'lan'
config zone
 option name 'wan'
 option masq '1'
 list network 'wan'
 list network 'wan6'
"""
        (config / "network").write_text(network, encoding="utf-8")
        (config / "firewall").write_text(firewall, encoding="utf-8")
        (config / "cudy-port-autodetect").write_text("config main 'main'\n option enabled '1'\n", encoding="utf-8")
        (root / "board").write_text("cudy,tr3000-v1-256mb\n", encoding="utf-8")
        wrapper = root / "uci"
        wrapper.write_text(f"""#!/bin/sh
if [ -f {shlex.quote(str(root / 'fail-commit'))} ] && [ "$*" = 'commit firewall' ]; then exit 1; fi
exec {shlex.quote(str(native / 'bin/uci'))} -c {shlex.quote(str(config))} -C {shlex.quote(str(config))} -t {shlex.quote(str(root / 'delta'))} "$@"
""", encoding="utf-8")
        wrapper.chmod(0o755)
        init = root / "init.d"
        init.mkdir()
        for name in ("network", "firewall", "cudy-port-autodetect"):
            script = init / name
            script.write_text(f'#!/bin/sh\necho "$0:$*" >> {shlex.quote(str(root / "actions"))}\n', encoding="utf-8")
            script.chmod(0o755)
        uci_functions = subprocess.check_output(
            ["git", "-C", str(upstream), "show", "HEAD:package/system/uci/files/lib/config/uci.sh"], text=True)
        (root / "uci.sh").write_text(uci_functions.replace("/sbin/uci", str(wrapper)).replace("/var/state", str(root / "state")), encoding="utf-8")
        functions = (upstream / "package/base-files/files/lib/functions.sh").read_text()
        (root / "functions.sh").write_text(functions.replace("/lib/config/uci.sh", str(root / "uci.sh")), encoding="utf-8")
        common = COMMON.read_text().replace("/lib/functions.sh", str(root / "functions.sh"))
        common = common.replace("/etc/config/", str(config) + "/").replace("/tmp/sysinfo/board_name", str(root / "board"))
        common = common.replace("/etc/init.d/", str(init) + "/")
        (root / "common.sh").write_text(common, encoding="utf-8")
        body = f"""
export PATH={shlex.quote(str(root))}:$PATH
. {shlex.quote(str(root / 'common.sh'))}
BACKUP_DIR={shlex.quote(str(root / 'backup'))}
log() {{ printf '%s\\n' "$*" >&2; }}
ubus() {{ return 1; }}
"""
        if case == "pending":
            body += "uci set network.lan.ipaddr=192.168.8.1\nconfigure_network\n"
        elif case == "occupied":
            body += "uci set network.wan2=interface\nuci commit network\nconfigure_network\n"
        elif case in ("rollback", "rollback-conditional"):
            (root / "fail-commit").touch()
            body += "configure_network || exit 1\n" if case == "rollback-conditional" else "configure_network\n"
        else:
            body += """
configure_network || exit 21
[ "$(uci get network.bridge.ports)" = eth2 ] || exit 22
[ "$(uci get network.bridge.bridge_empty)" = 1 ] || exit 23
[ "$(uci get network.wan.device):$(uci get network.wan2.device)" = eth0:eth1 ] || exit 24
[ "$(uci get network.wan.auto):$(uci get network.wan2.auto)" = 0:0 ] || exit 25
[ "$(uci get network.lan.ipaddr)" = 192.168.6.1 ] || exit 26
[ "$(uci get firewall.@zone[1].network)" = 'wan wan6 wan2 wan2_6' ] || exit 27
configure_network || exit 28
"""
            if case == "changed":
                body += "uci set network.lan.ipaddr=192.168.8.1 || exit 31\nuci commit network || exit 32\n[ \"$(uci get network.lan.ipaddr)\" = 192.168.8.1 ] || exit 33\nrestore_network\n"
            elif case == "restore-pending":
                body += "uci set network.lan.ipaddr=192.168.8.1 || exit 31\nrestore_network\n"
            else:
                body += "restore_network || exit 29\n[ \"$(uci get cudy-port-autodetect.main.enabled)\" = 0 ] || exit 30\n"
        env = dict(os.environ, LD_LIBRARY_PATH=str(native / "lib"))
        result = subprocess.run(["bash", "-c", body], text=True, capture_output=True, env=env)
        expected = case == "restore"
        if result.returncode != (0 if expected else 1):
            raise RuntimeError(f"{case} 返回码错误：{result.returncode}\n{result.stderr}")
        if case in ("restore", "pending", "rollback", "rollback-conditional"):
            assert (config / "network").read_text() == network, result.stderr
            assert (config / "firewall").read_text() == firewall, result.stderr
        if case in ("pending", "occupied"):
            assert not (root / "backup").exists()
        if case in ("changed", "restore-pending"):
            assert not (root / "actions").exists(), "拒绝恢复时不能停用服务"
            assert "拒绝" in result.stderr
        if case in ("rollback", "rollback-conditional"):
            assert "初始化失败，已恢复" in result.stderr
            assert not (root / "backup/configured.sha256").exists()
        print(f"通过：真实 UCI 配置测试 {case}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--native", required=True, type=Path)
    parser.add_argument("--upstream", required=True, type=Path)
    args = parser.parse_args()
    for case in ("restore", "pending", "occupied", "rollback", "rollback-conditional", "changed", "restore-pending"):
        check_case(args.native.resolve(), args.upstream.resolve(), case)


if __name__ == "__main__":
    main()
