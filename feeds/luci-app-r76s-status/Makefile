include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-r76s-status
PKG_VERSION:=2.2.4
PKG_RELEASE:=1
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-r76s-status
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=R76S Device Status
  DEPENDS:=+luci-base
endef

define Package/luci-app-r76s-status/description
 Lightweight NanoPi R76S / RK3576 status page.
endef

define Build/Compile
endef

define Package/luci-app-r76s-status/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/r76s_status
	$(INSTALL_DATA) ./files/controller/r76s_status.lua $(1)/usr/lib/lua/luci/controller/r76s_status.lua
	$(CP) ./files/view/r76s_status/* $(1)/usr/lib/lua/luci/view/r76s_status/
endef

$(eval $(call BuildPackage,luci-app-r76s-status))
