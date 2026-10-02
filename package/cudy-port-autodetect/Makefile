include $(TOPDIR)/rules.mk

PKG_NAME:=cudy-port-autodetect
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/cudy-port-autodetect
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Cudy TR3000 网口自动识别
  DEPENDS:=@TARGET_mediatek_filogic +ip-full +jsonfilter +jshn
endef

define Package/cudy-port-autodetect/description
  自动识别两个网口，支持 WAN 与 LAN、双 WAN 主备和双 LAN。
endef

define Package/cudy-port-autodetect/conffiles
/etc/config/cudy-port-autodetect
endef

define Build/Compile
endef

define Package/cudy-port-autodetect/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d $(1)/etc/uci-defaults
	$(INSTALL_CONF) ./files/config $(1)/etc/config/cudy-port-autodetect
	$(INSTALL_BIN) ./files/init $(1)/etc/init.d/cudy-port-autodetect
	$(INSTALL_BIN) ./files/defaults $(1)/etc/uci-defaults/90-cudy-port-autodetect
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/keep $(1)/lib/upgrade/keep.d/cudy-port-autodetect
	$(INSTALL_DIR) $(1)/usr/sbin $(1)/usr/libexec/cudy-port-autodetect
	$(INSTALL_BIN) ./files/command $(1)/usr/sbin/cudy-port-autodetect
	$(INSTALL_DATA) ./files/common.sh $(1)/usr/libexec/cudy-port-autodetect/common.sh
	$(INSTALL_BIN) ./files/lease $(1)/usr/libexec/cudy-port-autodetect/lease
endef

define Package/cudy-port-autodetect/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/usr/sbin/cudy-port-autodetect configure || exit 1
/etc/init.d/cudy-port-autodetect enable || exit 1
/etc/init.d/cudy-port-autodetect restart
endef

$(eval $(call BuildPackage,cudy-port-autodetect))
