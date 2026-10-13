include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-r76s-status
PKG_VERSION:=2.2.4
PKG_RELEASE:=6
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-r76s-status
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=R76S Device and AdGuard Home Status
  DEPENDS:=+luci-base +luci-lib-jsonc +luci-proto-wireguard +luci-lib-uqr
endef

define Package/luci-app-r76s-status/description
 Lightweight NanoPi R76S / RK3576 status page.
endef

define Build/Compile
endef

define Package/luci-app-r76s-status/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/r76s_status
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/r76s_adguardhome
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/r76s_wireguard
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/r76s
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/r76s_ip_policy
	$(INSTALL_DATA) ./files/controller/r76s_status.lua $(1)/usr/lib/lua/luci/controller/r76s_status.lua
	$(INSTALL_DATA) ./files/controller/r76s_adguardhome.lua $(1)/usr/lib/lua/luci/controller/r76s_adguardhome.lua
	$(INSTALL_DATA) ./files/view/r76s_adguardhome/status.htm $(1)/usr/lib/lua/luci/view/r76s_adguardhome/status.htm
	$(INSTALL_DATA) ./files/controller/r76s_wireguard.lua $(1)/usr/lib/lua/luci/controller/r76s_wireguard.lua
	$(INSTALL_DATA) ./files/view/r76s_wireguard/status.htm $(1)/usr/lib/lua/luci/view/r76s_wireguard/status.htm
	$(INSTALL_DATA) ./files/model/r76s/services.lua $(1)/usr/lib/lua/luci/model/r76s/services.lua
	$(INSTALL_DATA) ./files/controller/r76s_ip_policy.lua $(1)/usr/lib/lua/luci/controller/r76s_ip_policy.lua
	$(INSTALL_DATA) ./files/view/r76s_ip_policy/status.htm $(1)/usr/lib/lua/luci/view/r76s_ip_policy/status.htm
	$(INSTALL_DIR) $(1)/www/luci-static/resources/r76s $(1)/www/luci-static/resources/view/r76s_wireguard $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/htdocs/luci-static/resources/r76s/*.js $(1)/www/luci-static/resources/r76s/
	$(INSTALL_DATA) ./files/htdocs/luci-static/resources/view/r76s_wireguard/client.js $(1)/www/luci-static/resources/view/r76s_wireguard/client.js
	$(INSTALL_DATA) ./files/root/usr/share/luci/menu.d/r76s-wireguard-client.json $(1)/usr/share/luci/menu.d/r76s-wireguard-client.json
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/r76s_diagnostics
	$(INSTALL_DATA) ./files/controller/r76s_diagnostics.lua $(1)/usr/lib/lua/luci/controller/r76s_diagnostics.lua
	$(INSTALL_DATA) ./files/model/r76s/diagnostics.lua $(1)/usr/lib/lua/luci/model/r76s/diagnostics.lua
	$(INSTALL_DATA) ./files/model/r76s/diagnostics_collect.lua $(1)/usr/lib/lua/luci/model/r76s/diagnostics_collect.lua
	$(INSTALL_DATA) ./files/view/r76s_diagnostics/status.htm $(1)/usr/lib/lua/luci/view/r76s_diagnostics/status.htm
	$(CP) ./files/view/r76s_status/* $(1)/usr/lib/lua/luci/view/r76s_status/
endef

$(eval $(call BuildPackage,luci-app-r76s-status))
