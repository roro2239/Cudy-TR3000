#!/usr/bin/env python3
"""用上游 Realtek 补丁还原驱动，验证本地补丁及真实恢复函数的执行路径。"""
import argparse
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DRIVER = "drivers/net/phy/realtek/realtek_main.c"
PATCH = ROOT / "patches/002-cudy-tr3000-realtek-reset.patch"


def driver_sections(content):
    for section in re.split(r"(?=^(?:diff --git |--- (?:a/|/dev/null)))", content, flags=re.M):
        if "+++ b/" + DRIVER + "\n" in section:
            yield section


def restore_driver(upstream, tree):
    groups = ("target/linux/generic/backport-6.6/",
              "target/linux/generic/pending-6.6/",
              "target/linux/generic/hack-6.6/",
              "target/linux/mediatek/patches-6.6/")
    matches = subprocess.check_output(
        ["git", "-C", str(upstream), "grep", "-l", "-F", "+++ b/" + DRIVER,
         "HEAD", "--", *groups], text=True).splitlines()
    paths = [path.removeprefix("HEAD:") for path in matches]
    source = tree / DRIVER
    source.parent.mkdir(parents=True)
    initialized = False
    for group in groups:
        for path in sorted(p for p in paths if p.startswith(group) and p.endswith(".patch")):
            content = subprocess.check_output(
                ["git", "-C", str(upstream), "show", "HEAD:" + path]).decode()
            for section in driver_sections(content):
                result = subprocess.run(["patch", "--batch", "--forward", "-p1"],
                                        input=section, text=True, cwd=tree,
                                        capture_output=True)
                if result.returncode:
                    raise RuntimeError(path + "\n" + result.stdout + result.stderr)
                initialized = True
    assert initialized and source.is_file(), "未找到上游 Realtek 驱动"
    return source


def check_recovery(source, tree):
    function = re.search(r"static int rtl822xb_config_init_war\([^\n]+\)\n\{.*?\n\}",
                         source, re.S)
    assert function, "缺少真实恢复函数"
    harness = r'''
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
struct mii_bus {
    void *reset_gpiod;
    int reset_delay_us, reset_post_delay_us, mdio_lock;
};
struct phy_device {
    struct { struct mii_bus *bus; void *reset_gpio, *reset_ctrl; int addr; } mdio;
};
static const char *board;
static int results[2], calls, warnings, gpio_calls, reset_calls, delays, locks;
static void *expected_gpio;
static int rtl822xb_config_init(struct phy_device *phydev) {
    assert(phydev && calls < 2);
    return results[calls++];
}
static bool of_machine_is_compatible(const char *compatible) {
    return strcmp(board, compatible) == 0;
}
#define phydev_warn(...) (++warnings)
static void mutex_lock(int *lock) { assert(!*lock); *lock = 1; ++locks; }
static void mutex_unlock(int *lock) { assert(*lock); *lock = 0; }
static void gpiod_set_value_cansleep(void *gpio, int value) {
    assert(gpio == expected_gpio && locks == 1 && value == (gpio_calls == 0));
    ++gpio_calls;
}
static void fsleep(unsigned long delay) {
    assert(delay == 100000 && gpio_calls == delays + 1);
    ++delays;
}
static void phy_device_reset(struct phy_device *phydev, int value) {
    assert(phydev && value == (reset_calls == 0));
    ++reset_calls;
}
'''
    harness += function.group(0)
    harness += r'''
static void run_case(const char *name, int first, int second, bool child_gpio,
                     bool child_ctrl, bool bus_gpio, int addr, bool use_bus) {
    struct mii_bus bus = {bus_gpio ? &bus : NULL, 100000, 100000, 0};
    struct phy_device phy = {{&bus, child_gpio ? &bus : NULL,
                            child_ctrl ? &bus : NULL, addr}};
    board = name; results[0] = first; results[1] = second;
    calls = warnings = gpio_calls = reset_calls = delays = locks = 0;
    expected_gpio = bus.reset_gpiod;
    int ret = rtl822xb_config_init_war(&phy);
    bool retry = first == -ETIMEDOUT;
    assert(ret == (retry ? second : first) && calls == (retry ? 2 : 1));
    assert(bus.mdio_lock == 0);
    assert(gpio_calls == (retry && use_bus ? 2 : 0));
    assert(delays == gpio_calls && locks == (retry && use_bus ? 1 : 0));
    assert(reset_calls == (retry && !use_bus ? 2 : 0));
    assert(warnings == (retry ? (use_bus ? 2 : 1) : 0));
}
int main(void) {
    const char *normal = "cudy,tr3000-v1-256mb", *mod = "cudy,tr3000-v1-ubootmod";
    run_case(normal, 0, 0, false, false, true, 1, true);
    run_case(normal, -EIO, 0, false, false, true, 1, true);
    run_case(normal, -ETIMEDOUT, 0, false, false, true, 1, true);
    run_case(mod, -ETIMEDOUT, 0, false, false, true, 1, true);
    run_case(normal, -ETIMEDOUT, -ETIMEDOUT, false, false, true, 1, true);
    run_case(normal, -ETIMEDOUT, -EIO, false, false, true, 1, true);
    run_case("other,board", -ETIMEDOUT, 0, false, false, true, 1, false);
    run_case(normal, -ETIMEDOUT, 0, true, false, true, 1, false);
    run_case(normal, -ETIMEDOUT, 0, false, true, true, 1, false);
    run_case(normal, -ETIMEDOUT, -ETIMEDOUT, false, false, false, 1, false);
    run_case(normal, -ETIMEDOUT, 0, false, false, true, 0, false);
    puts("通过：真实恢复函数的 11 项分支、复位顺序、重试次数和错误传播检查");
    return 0;
}
'''
    test = tree / "recovery.c"
    test.write_text(harness, encoding="utf-8")
    binary = tree / "recovery"
    subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                    str(test), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--upstream", required=True, type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as temporary:
        tree = Path(temporary)
        source = restore_driver(args.upstream.resolve(), tree)
        before = source.read_bytes()
        subprocess.run(["patch", "--batch", "--forward", "--fuzz=0", "-p1"],
                       input=PATCH.read_bytes(), cwd=tree, check=True)
        after = source.read_bytes()
        check_recovery(after.decode(), tree)
        subprocess.run(["patch", "--batch", "--forward", "--fuzz=0", "-R", "-p1", "--dry-run"],
                       input=PATCH.read_bytes(), cwd=tree, check=True)
        repeat = subprocess.run(["patch", "--batch", "--forward", "--fuzz=0", "-p1", "--dry-run"],
                                input=PATCH.read_bytes(), cwd=tree, capture_output=True)
        assert repeat.returncode != 0 and source.read_bytes() == after
        subprocess.run(["patch", "--batch", "--forward", "--fuzz=0", "-R", "-p1"],
                       input=PATCH.read_bytes(), cwd=tree, check=True,
                       stdout=subprocess.DEVNULL)
        assert source.read_bytes() == before
        print("通过：真实上游 Realtek 驱动补丁应用、逆向还原、拒绝重复应用")


if __name__ == "__main__":
    main()
