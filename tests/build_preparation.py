#!/usr/bin/env python3
"""在临时源码目录运行真实构建准备脚本，验证 ifdown 修复和失败路径。"""
import argparse
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/prepare-network-fixes.sh"
IFDOWN = "package/network/config/netifd/files/sbin/ifdown"
KERNEL_PATCH = "target/linux/mediatek/patches-6.6/9999-06-cudy-tr3000-realtek-reset.patch"
DRIVER_PATCH = ROOT / "patches/002-cudy-tr3000-realtek-reset.patch"
SOURCES = ("package/network/config/netifd/files/sbin/ifup",
           "target/linux/mediatek/dts/mt7981b-cudy-tr3000-v1.dtsi",
           "target/linux/mediatek/filogic/config-6.6")


def check_case(upstream, profile, case):
    with tempfile.TemporaryDirectory() as temporary:
        tree = Path(temporary)
        for relative in SOURCES:
            target = tree / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(subprocess.check_output(
                ["git", "-C", str(upstream), "show", "HEAD:" + relative]))
        shutil.copyfile(ROOT / profile, tree / ".config")
        kernel_patch = tree / KERNEL_PATCH
        kernel_patch.parent.mkdir(parents=True)
        ifdown = tree / IFDOWN
        if case in ("legacy", "driver-present", "driver-conflict", "driver-link", "missing-patch-dir"):
            ifdown.write_bytes(subprocess.check_output(
                ["git", "-C", str(upstream), "show", "HEAD:" + IFDOWN]))
        elif case == "symlink":
            ifdown.symlink_to("ifup")
        elif case == "foreign-link":
            ifdown.symlink_to("/bin/sh")
        elif case == "unknown":
            ifdown.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        elif case == "missing-ifup":
            ifdown.write_text("ifup", encoding="utf-8")
            (ifdown.parent / "ifup").unlink()
        elif case == "phy-mismatch":
            ifdown.write_text("ifup", encoding="utf-8")
            (tree / SOURCES[1]).write_text("/* 上游结构不匹配 */\n", encoding="utf-8")
        if case == "driver-present":
            kernel_patch.write_bytes(DRIVER_PATCH.read_bytes())
        elif case == "driver-conflict":
            kernel_patch.write_text("已有不同补丁\n", encoding="utf-8")
        elif case == "driver-link":
            kernel_patch.symlink_to(DRIVER_PATCH)
        elif case == "missing-patch-dir":
            kernel_patch.parent.rmdir()
        before = ifdown.read_bytes() if ifdown.is_file() and not ifdown.is_symlink() else None
        before_phy = (tree / SOURCES[1]).read_bytes()
        result = subprocess.run(["bash", str(SCRIPT)], cwd=tree, text=True, capture_output=True)
        expected = case in ("legacy", "symlink", "driver-present")
        assert (result.returncode == 0) == expected, result.stdout + result.stderr
        if expected:
            assert ifdown.is_symlink() and os.readlink(ifdown) == "ifup"
            assert {p.name for p in (tree / "package").iterdir()} == {"network"}
            assert not kernel_patch.is_symlink() and kernel_patch.read_bytes() == DRIVER_PATCH.read_bytes()
            with (ROOT / "patches/001-cudy-tr3000-phy-reset.patch").open("rb") as patch:
                subprocess.run(["patch", "--batch", "--fuzz=0", "-R", "-p1", "--dry-run"],
                               cwd=tree, stdin=patch, check=True, stdout=subprocess.DEVNULL)
            before_repeat = (tree / SOURCES[1]).read_bytes()
            repeated = subprocess.run(["bash", str(SCRIPT)], cwd=tree, text=True, capture_output=True)
            assert repeated.returncode == 0, repeated.stdout + repeated.stderr
            assert "补丁已经应用" in repeated.stdout, repeated.stdout + repeated.stderr
            assert (tree / SOURCES[1]).read_bytes() == before_repeat
            assert ifdown.is_symlink() and os.readlink(ifdown) == "ifup"
            assert kernel_patch.read_bytes() == DRIVER_PATCH.read_bytes()
        else:
            assert "[错误]" in result.stderr
            if before is not None:
                assert not ifdown.is_symlink() and ifdown.read_bytes() == before
            if case == "foreign-link":
                assert os.readlink(ifdown) == "/bin/sh"
            assert (tree / SOURCES[1]).read_bytes() == before_phy
            if case == "driver-conflict":
                assert kernel_patch.read_text(encoding="utf-8") == "已有不同补丁\n"
            elif case == "driver-link":
                assert kernel_patch.is_symlink()
        print(f"通过：{profile} 构建准备 {case}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--upstream", required=True, type=Path)
    args = parser.parse_args()
    for profile in ("TR3000V1_256M.config", "TR3000V1_MOD.config"):
        for case in ("legacy", "symlink", "unknown", "foreign-link", "missing-ifup", "phy-mismatch",
                     "driver-present", "driver-conflict", "driver-link", "missing-patch-dir"):
            check_case(args.upstream.resolve(), profile, case)


if __name__ == "__main__":
    main()
