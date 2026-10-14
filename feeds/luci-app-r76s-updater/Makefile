include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-r76s-updater
PKG_VERSION:=1.4.1
PKG_RELEASE:=6
PKGARCH:=all

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-r76s-updater
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=R76S Firmware and Component Online Updater
  DEPENDS:=+luci-base +luci-lib-jsonc +lua +curl +ca-bundle +ca-certificates +opkg +r76s-core
endef

define Package/luci-app-r76s-updater/description
 Safe online updater for R76S firmware plus PassWall, SmartDNS, AdGuard Home.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	cp -r ./files/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
endef

define Package/luci-app-r76s-updater/conffiles
/etc/config/r76s_ip_policy
endef

define Package/luci-app-r76s-updater/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/r76s_updater
	$(INSTALL_DIR) $(1)/usr/libexec/r76s
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/etc/rc.d
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/usr/share/r76s

	$(INSTALL_DATA) $(PKG_BUILD_DIR)/controller/r76s_updater.lua $(1)/usr/lib/lua/luci/controller/r76s_updater.lua
	$(CP) $(PKG_BUILD_DIR)/view/r76s_updater/* $(1)/usr/lib/lua/luci/view/r76s_updater/

	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/usr/libexec/r76s/r76s-component-updater $(1)/usr/libexec/r76s/r76s-component-updater
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/usr/libexec/r76s/r76s-ip-family-policy $(1)/usr/libexec/r76s/r76s-ip-family-policy
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/usr/libexec/r76s/r76s-ip6-guard $(1)/usr/libexec/r76s/r76s-ip6-guard
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/root/usr/share/r76s/tencent-direct.list $(1)/usr/share/r76s/tencent-direct.list
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/root/etc/config/r76s_ip_policy $(1)/etc/config/r76s_ip_policy
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/etc/firewall.r76s-ip6-guard $(1)/etc/firewall.r76s-ip6-guard
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/etc/init.d/r76s-ip6-guard $(1)/etc/init.d/r76s-ip6-guard
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/usr/libexec/r76s/smartdns-wrapper $(1)/usr/libexec/r76s/smartdns-wrapper
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/usr/libexec/r76s/smartdns.bin $(1)/usr/libexec/r76s/smartdns.bin

	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/usr/bin/r76s-update-passwall $(1)/usr/bin/r76s-update-passwall
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/usr/bin/r76s-update-smartdns $(1)/usr/bin/r76s-update-smartdns
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/root/usr/bin/r76s-update-adguardhome $(1)/usr/bin/r76s-update-adguardhome


endef

$(eval $(call BuildPackage,luci-app-r76s-updater))
