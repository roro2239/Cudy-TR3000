#!/usr/bin/env python3
"""通过软件包 Makefile 的真实安装规则和 OpenWrt ipkg-build 生成脚本插件。"""
import argparse
import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "package/cudy-port-autodetect"


def main():
    parser = argparse.ArgumentParser(description="打包网口自动识别插件；不编译内核或固件")
    parser.add_argument("--ipkg-build", required=True, type=Path, help="OpenWrt 源码中的 scripts/ipkg-build")
    parser.add_argument("--output", required=True, type=Path, help="输出目录")
    args = parser.parse_args()
    builder = args.ipkg_build.resolve()
    if not builder.is_file():
        parser.error("未找到 OpenWrt ipkg-build")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temporary:
        temporary = Path(temporary)
        stage = temporary / "stage"
        (stage / "CONTROL").mkdir(parents=True)
        include = temporary / "include"
        include.mkdir()
        (temporary / "rules.mk").write_text("", encoding="utf-8")
        (include / "package.mk").write_text("BuildPackage=\n", encoding="utf-8")
        shim = temporary / "stage.mk"
        shim.write_text(f"""TOPDIR:={temporary}
INCLUDE_DIR:={include}
STAGE:={stage}
INSTALL_DIR:=install -d -m0755
INSTALL_CONF:=install -m0600
INSTALL_BIN:=install -m0755
INSTALL_DATA:=install -m0644
include Makefile
$(eval $(Package/cudy-port-autodetect))
define Control
Package: $(PKG_NAME)
Version: $(PKG_VERSION)-$(PKG_RELEASE)
Architecture: $(PKGARCH)
Depends: $(subst $(space),$(comma),$(patsubst +%,%,$(filter +%,$(DEPENDS))))
Section: $(SECTION)
Maintainer: Cudy TR3000 项目维护者
Installed-Size: 0
Description: $(TITLE)
endef
empty:=
space:=$(empty) $(empty)
comma:=,$(space)
.PHONY: stage
stage:
\t$(call Package/cudy-port-autodetect/install,$(STAGE))
\t$(file >$(STAGE)/CONTROL/control,$(Control))
\t$(file >$(STAGE)/CONTROL/conffiles,$(Package/cudy-port-autodetect/conffiles))
\t$(file >$(STAGE)/CONTROL/postinst,$(Package/cudy-port-autodetect/postinst))
\tchmod 0755 $(STAGE)/CONTROL/postinst
""", encoding="utf-8")
        subprocess.run(["make", "--no-print-directory", "-f", str(shim), "stage"], cwd=PACKAGE, check=True)
        env = dict(os.environ, SOURCE_DATE_EPOCH="1790899200")
        subprocess.run(["sh", str(builder), str(stage), str(output)], env=env, check=True)
    print("插件打包完成；2.5G PHY 修复需通过固件构建应用。")


if __name__ == "__main__":
    main()
