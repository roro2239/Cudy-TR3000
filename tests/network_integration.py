#!/usr/bin/env python3
"""在独立 Linux 网络命名空间中，用真实 DHCP 报文和路由验证网口行为。"""
import argparse
import errno
import ipaddress
import os
import shlex
import socket
import struct
import subprocess
import tempfile
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = ROOT / "package/cudy-port-autodetect/files"


def run(*args):
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL)


def checksum(data):
    total = sum(struct.unpack("!%dH" % (len(data) // 2), data))
    total = (total & 0xFFFF) + (total >> 16)
    total = (total & 0xFFFF) + (total >> 16)
    return (~total) & 0xFFFF


class DhcpServer(threading.Thread):
    def __init__(self, device, network, host=26):
        super().__init__(daemon=True)
        self.device = device
        self.gateway = socket.inet_aton(f"192.168.{network}.1")
        self.address = socket.inet_aton(f"192.168.{network}.{host}")
        self.socket = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0800))
        self.socket.bind((device, 0))
        self.socket.settimeout(0.2)
        self.mac = bytes.fromhex(Path(f"/sys/class/net/{device}/address").read_text().strip().replace(":", ""))
        self.stop = threading.Event()
        self.acks = 0
        self.error = None

    def run(self):
        try:
            while not self.stop.is_set():
                try:
                    frame = self.socket.recv(4096)
                except socket.timeout:
                    continue
                except OSError as error:
                    if error.errno == errno.ENETDOWN:
                        self.stop.wait(0.05)
                        continue
                    raise
                if len(frame) < 282 or frame[23] != 17:
                    continue
                offset = 14 + (frame[14] & 15) * 4
                sport, dport = struct.unpack("!HH", frame[offset:offset + 4])
                if (sport, dport) != (68, 67):
                    continue
                request = frame[offset + 8:]
                if request[0] != 1 or request[236:240] != b"\x63\x82\x53\x63":
                    continue
                options = {}
                index = 240
                while index < len(request):
                    tag = request[index]
                    index += 1
                    if tag == 255:
                        break
                    if tag == 0:
                        continue
                    if index >= len(request):
                        break
                    length = request[index]
                    index += 1
                    options[tag] = request[index:index + length]
                    index += length
                kind = options.get(53)
                if kind not in (b"\x01", b"\x03"):
                    continue
                if options.get(54, self.gateway) != self.gateway:
                    continue
                reply = bytearray(request[:240])
                reply[0] = 2
                reply[16:20] = self.address
                reply[20:24] = self.gateway
                reply.extend(b"\x35\x01" + (b"\x02" if kind == b"\x01" else b"\x05"))
                reply.extend(b"\x36\x04" + self.gateway)
                reply.extend(b"\x01\x04\xff\xff\xff\x00")
                reply.extend(b"\x03\x04" + self.gateway)
                reply.extend(b"\x06\x04" + self.gateway)
                reply.extend(b"\x33\x04" + struct.pack("!I", 300) + b"\xff")
                length = 20 + 8 + len(reply)
                header = struct.pack("!BBHHHBBH4s4s", 0x45, 0, length, 0, 0, 64, 17, 0,
                                     self.gateway, b"\xff" * 4)
                header = header[:10] + struct.pack("!H", checksum(header)) + header[12:]
                udp = struct.pack("!HHHH", 67, 68, len(reply) + 8, 0)
                self.socket.send(b"\xff" * 6 + self.mac + b"\x08\x00" + header + udp + reply)
                if kind == b"\x03":
                    self.acks += 1
        except Exception as error:
            self.error = error
        finally:
            self.socket.close()


def prepare_network():
    run("ip", "link", "set", "lo", "up")
    run("ip", "link", "add", "br-lan", "type", "bridge")
    run("ip", "link", "set", "br-lan", "up")
    run("ip", "addr", "add", "192.168.6.1/24", "dev", "br-lan")
    for index in (0, 1):
        run("ip", "link", "add", f"eth{index}", "type", "veth", "peer", "name", f"upstream{index}")
        run("ip", "link", "set", f"eth{index}", "up")
        run("ip", "link", "set", f"upstream{index}", "up")


def execute_scenario(tools, kinds, name):
    for namespace in ("net", "mnt"):
        if os.readlink(f"/proc/self/ns/{namespace}") == os.readlink(f"/proc/1/ns/{namespace}"):
            raise RuntimeError("测试必须在独立网络和挂载命名空间中运行，拒绝操作宿主机网络")
    run("mount", "-t", "sysfs", "sysfs", "/sys")
    prepare_network()
    servers = []
    for index, kind in enumerate(kinds):
        if kind == "wan":
            same = name == "wan-wan-same"
            server = DhcpServer(f"upstream{index}", 5 if same else 5 + index * 2, 26 + index if same else 26)
            server.start()
            servers.append(server)
    try:
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            hook = folder / "netifd-lease"
            hook.write_text("""#!/bin/sh
case "$1" in bound|renew) ;; *) exit 0 ;; esac
prefix=$(python3 -c 'import ipaddress,os; print(ipaddress.IPv4Network("0.0.0.0/"+os.environ["subnet"]).prefixlen)')
ip addr replace "$ip/$prefix" dev "$interface" || exit 1
gateway=${router%% *}
case "$interface" in eth0) metric=10 ;; eth1) metric=20 ;; esac
ip -4 route replace default via "$gateway" dev "$interface" src "$ip" proto static metric "$metric"
""", encoding="utf-8")
            hook.chmod(0o755)
            body = f"""
. {shlex.quote(str(FILES / 'common.sh'))}
RUN_DIR={shlex.quote(str(folder))}
LIB_DIR={shlex.quote(str(FILES))}
PATH={shlex.quote(str(tools))}:$PATH
export PATH
NOW=100
log() {{ printf '%s\\n' "$*" >&2; }}
uci() {{ case "$*" in *ipaddr*) echo 192.168.6.1 ;; *netmask*) echo 255.255.255.0 ;; *) return 1 ;; esac; }}
ifup() {{
 case "$1" in
 wan) dev=eth0 ;; wan2) dev=eth1 ;; *) return 0 ;;
 esac
 udhcpc -f -n -q -i "$dev" -t 3 -T 1 -s {shlex.quote(str(hook))} >> "$RUN_DIR/netifd.log" 2>&1
}}
ifdown() {{
 case "$1" in wan) dev=eth0 ;; wan2) dev=eth1 ;; *) return 0 ;; esac
 ip -4 addr flush dev "$dev"
}}
for device in eth0 eth1; do
 load_port "$device"
 classify_port "$device"
 save_port "$device"
done
load_port eth0; [ "$ROLE" = {kinds[0]} ] || exit 21
load_port eth1; [ "$ROLE" = {kinds[1]} ] || exit 22
for device in eth0 eth1; do
 load_port "$device"
 if [ "$ROLE" = lan ]; then
  [ "$(master "$device")" = br-lan ] || exit 23
 else
  [ -z "$(master "$device")" ] || exit 24
  IPV4=$(ip -4 -o addr show dev "$device" | awk '{{split($4,a,"/"); print a[1]}}')
  GATEWAY=$(ip -4 route show default dev "$device" proto static | awk '{{print $3}}')
  HEALTH=up
  save_port "$device"
 fi
done
select_route || exit 25
"""
            if kinds == ("wan", "wan"):
                body += """
[ "$SELECTED" = eth0 ] || exit 26
ip -4 route get 1.1.1.1 | grep -q 'dev eth0' || exit 27
load_port eth0; HEALTH=down; save_port eth0
select_route || exit 28
[ "$SELECTED" = eth1 ] || exit 29
ip -4 route get 1.1.1.1 | grep -q 'dev eth1' || exit 30
load_port eth0; HEALTH=up; save_port eth0
select_route || exit 31
[ "$SELECTED" = eth0 ] || exit 32
ip link set upstream0 down
NOW=120
port_tick eth0 || exit 33
select_route || exit 34
[ "$SELECTED" = eth1 ] || exit 35
ip -4 route get 1.1.1.1 | grep -q 'dev eth1' || exit 36
ip link set upstream0 up
NOW=121; port_tick eth0 || exit 39
NOW=122; port_tick eth0 || exit 40
load_port eth0; [ "$ROLE" = wan ] || exit 41
# 在刚完成识别的缓冲期内迅速重新插拔，也必须重新识别。
ip link set upstream0 down
ip link set upstream0 up
NOW=123; port_tick eth0 || exit 42
load_port eth0; [ "$ROLE" = unknown ] || exit 43
NOW=130; port_tick eth0 || exit 44
load_port eth0; [ "$ROLE" = wan ] || exit 45
"""
            elif kinds == ("lan", "lan"):
                body += '[ -z "$SELECTED" ] || exit 37\n'
            else:
                expected = "eth0" if kinds[0] == "wan" else "eth1"
                body += f'[ "$SELECTED" = {expected} ] || exit 38\n'
            result = subprocess.run(["sh", "-c", body], text=True, capture_output=True, timeout=80)
            if result.returncode:
                logs = "\n".join(p.read_text(errors="replace") for p in folder.glob("*.log"))
                raise RuntimeError(f"{name} 失败，退出码 {result.returncode}\n{result.stdout}\n{result.stderr}\n{logs}")
            for server in servers:
                if server.error:
                    raise server.error
                if server.acks < 2:
                    raise RuntimeError("未完成探测和地址管理阶段的两次真实 DHCP 握手")
            print(f"通过：{name}；真实 DHCP 握手次数=" + str(sum(s.acks for s in servers)))
    finally:
        for server in servers:
            server.stop.set()
            server.join(timeout=1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tools", required=True, type=Path)
    parser.add_argument("--scenario", choices=("wan-lan", "lan-wan", "wan-wan", "lan-lan", "wan-wan-same"))
    args = parser.parse_args()
    scenarios = {"wan-lan": ("wan", "lan"), "lan-wan": ("lan", "wan"),
                 "wan-wan": ("wan", "wan"), "lan-lan": ("lan", "lan"), "wan-wan-same": ("wan", "wan")}
    if args.scenario:
        execute_scenario(args.tools.resolve(), scenarios[args.scenario], args.scenario)
    else:
        for scenario in scenarios:
            subprocess.run(["unshare", "--net", "--mount", "--propagation", "private", "python3", str(Path(__file__).resolve()),
                            "--tools", str(args.tools.resolve()), "--scenario", scenario], check=True)


if __name__ == "__main__":
    main()
