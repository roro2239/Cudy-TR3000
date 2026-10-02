#!/usr/bin/env python3
import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
COMMON = ROOT / "package/cudy-port-autodetect/files/common.sh"


class PortTests(unittest.TestCase):
    def shell(self, body, success=True):
        with tempfile.TemporaryDirectory() as folder:
            command = (
                f". {shlex.quote(str(COMMON))}\n"
                f"RUN_DIR={shlex.quote(folder)}\n"
                "log() { printf '%s\\n' \"$*\" >&2; }\n" + body
            )
            result = subprocess.run(["sh", "-c", command], text=True, capture_output=True)
            if success:
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            else:
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            return result

    def test_ipv4_rejects_malformed_and_shell_text(self):
        for address in ("", "1.2.3", "256.2.3.4", "1.2.3.4.5", "1.2.3.a", "1.2.3.4;id"):
            with self.subTest(address=address):
                self.shell("ipv4_valid " + shlex.quote(address), success=False)

    def test_lease_validation(self):
        cases = [
            ("192.168.5.26", "255.255.255.0", "192.168.5.1", True),
            ("10.1.2.3", "255.0.0.0", "10.0.0.1", True),
            ("192.168.6.26", "255.255.255.0", "192.168.6.254", False),
            ("192.168.5.26", "255.255.0.0", "192.168.5.1", False),
            ("192.168.5.26", "255.0.255.0", "192.168.5.1", False),
            ("192.168.5.26", "255.255.255.0", "192.168.5.26", False),
            ("192.168.5.0", "255.255.255.0", "192.168.5.1", False),
            ("192.168.5.255", "255.255.255.0", "192.168.5.1", False),
            ("192.168.5.26", "255.255.255.254", "192.168.5.27", True),
            ("192.168.5.26", "255.255.255.255", "192.168.5.1", True),
            ("224.1.2.3", "255.255.255.0", "224.1.2.1", False),
            ("192.168.5.26", "255.255.255.0", "", False),
        ]
        for ip, mask, gateway, expected in cases:
            with self.subTest(ip=ip, mask=mask, gateway=gateway):
                args = (ip, mask, gateway, "192.168.6.1", "255.255.255.0")
                self.shell("lease_safe " + " ".join(map(shlex.quote, args)), success=expected)

    def test_state_round_trip_including_empty_addresses(self):
        self.shell("""
load_port eth0
ROLE=wan HEALTH=down FAILS=3 PASSES=0 GENERATION=17 RETRY_AT=83
save_port eth0
ROLE=lan IPV4=10.0.0.5 FAILS=0
load_port eth0
[ "$ROLE:$HEALTH:$FAILS:$GENERATION:$RETRY_AT:$IPV4" = 'wan:down:3:17:83:' ]
""")

    def test_roles_for_both_ports_and_invalid_probe(self):
        for result, expected in ((0, "wan"), (1, "lan"), (2, "conflict"), (3, "error")):
            for device in ("eth0", "eth1"):
                with self.subTest(result=result, device=device):
                    self.shell(f"""
NOW=100
carrier() {{ echo 1; }}
generation() {{ echo 4; }}
probe_port() {{ return {result}; }}
ifup() {{ echo "ifup:$*" >> "$RUN_DIR/actions"; }}
ip() {{ echo "ip:$*" >> "$RUN_DIR/actions"; }}
classify_port {device}
[ "$ROLE" = {expected} ] || exit 1
case "$ROLE" in
wan) grep -q '^ifup:' "$RUN_DIR/actions"; ! grep -q 'master br-lan' "$RUN_DIR/actions" ;;
lan) grep -q 'master br-lan' "$RUN_DIR/actions"; ! grep -q '^ifup:' "$RUN_DIR/actions" ;;
*) [ ! -e "$RUN_DIR/actions" ] ;;
esac
""")

    def test_cable_change_during_probe_does_not_accept_old_lease(self):
        self.shell("""
NOW=100
echo 1 > "$RUN_DIR/generation"
generation() { cat "$RUN_DIR/generation"; }
carrier() { echo 1; }
probe_port() { echo 3 > "$RUN_DIR/generation"; return 0; }
ifup() { exit 99; }
classify_port eth0
[ "$ROLE:$HEALTH" = unknown:waiting ]
""")

    def test_wan_start_failure_is_observable(self):
        result = self.shell("""
NOW=100
generation() { echo 4; }
carrier() { echo 1; }
probe_port() { return 0; }
ifup() { return 1; }
classify_port eth0
[ "$ROLE" = error ]
""")
        self.assertIn("启动 WAN 失败", result.stderr)

    def test_primary_selection_and_both_unhealthy_retention(self):
        self.shell("""
carrier() { echo 1; }
load_port eth0
ROLE=wan HEALTH=up IPV4=192.168.5.2 GATEWAY=192.168.5.1
save_port eth0
load_port eth1
ROLE=wan HEALTH=up IPV4=192.168.7.2 GATEWAY=192.168.7.1
save_port eth1
[ "$(choose_port)" = eth0 ] || exit 1
load_port eth0; HEALTH=down; save_port eth0
[ "$(choose_port)" = eth1 ] || exit 1
SELECTED=eth1
load_port eth1; HEALTH=down; save_port eth1
[ "$(choose_port)" = eth1 ] || exit 1
load_port eth1; ROLE=lan; IPV4=; GATEWAY=; save_port eth1
[ "$(choose_port)" = eth0 ] || exit 1
load_port eth0; ROLE=lan; IPV4=; GATEWAY=; save_port eth0
[ -z "$(choose_port)" ]
""")

    def test_three_failures_and_two_recoveries(self):
        self.shell("""
ROLE=wan HEALTH=up FAILS=0 PASSES=0 LAST_HEALTH=0 RETRY_AT=999
ubus() { echo '{}'; }
jsonfilter() { case "$4" in '@.up') echo true ;; *mask*) echo 24 ;; *) echo 192.168.5.2 ;; esac; }
uci() { case "$*" in *ipaddr*) echo 192.168.6.1 ;; *netmask*) echo 255.255.255.0 ;; *) return 1 ;; esac; }
ip() { echo 'default via 192.168.5.1 dev eth0 proto static metric 10'; }
ping() { return 1; }
NOW=10; refresh_wan eth0; [ "$HEALTH:$FAILS" = up:1 ] || exit 1
NOW=20; refresh_wan eth0; [ "$HEALTH:$FAILS" = up:2 ] || exit 1
NOW=30; refresh_wan eth0; [ "$HEALTH:$FAILS" = down:3 ] || exit 1
ping() { return 0; }
NOW=40; refresh_wan eth0; [ "$HEALTH:$PASSES" = down:1 ] || exit 1
NOW=50; refresh_wan eth0; [ "$HEALTH:$PASSES" = up:2 ]
""")

    def test_route_failure_does_not_claim_selection(self):
        result = self.shell("""
choose_port() { echo eth0; }
load_port() { IPV4=192.168.5.2 GATEWAY=192.168.5.1; }
ip() { case "$*" in *replace*) return 1 ;; *) return 0 ;; esac; }
if select_route; then exit 99; fi
[ -z "$SELECTED" ]
""")
        self.assertIn("安装首选默认路由失败", result.stderr)

    def test_actual_dhcp_lease_cannot_overlap_lan(self):
        self.shell("""
NOW=100 ROLE=wan HEALTH=up RETRY_AT=999
ubus() { echo '{}'; }
jsonfilter() { case "$4" in '@.up') echo true ;; *mask*) echo 16 ;; *) echo 192.168.5.2 ;; esac; }
uci() { case "$*" in *ipaddr*) echo 192.168.6.1 ;; *netmask*) echo 255.255.255.0 ;; *) return 1 ;; esac; }
ip() { echo 'default via 192.168.5.1 dev eth0 proto static metric 10'; }
stop_wan() { echo stopped > "$RUN_DIR/stopped"; }
refresh_wan eth0
[ "$ROLE:$HEALTH:$IPV4" = conflict:invalid: ] && [ -f "$RUN_DIR/stopped" ]
""")

    def test_unrelated_route_is_not_overwritten(self):
        self.shell("""
choose_port() { echo eth0; }
load_port() { IPV4=192.168.5.2 GATEWAY=192.168.5.1; }
ip() {
 case "$*" in
 *show*) echo 'default via 10.0.0.1 dev unrelated metric 5' ;;
 *replace*) exit 99 ;;
 esac
}
if select_route; then exit 98; fi
[ -z "$SELECTED" ]
""")

    def test_ipv6_failure_keeps_actual_ipv4_selection_visible(self):
        result = self.shell("""
choose_port() { echo eth0; }
load_port() { IPV4=192.168.5.2 GATEWAY=192.168.5.1 HEALTH=up; }
ip() { return 0; }
ifdown() { return 0; }
ifup() { return 1; }
if select_route; then exit 98; fi
[ "$SELECTED" = eth0 ] && [ -z "$SELECTED_KEY" ]
""")
        self.assertIn("启动 IPv6 失败", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
