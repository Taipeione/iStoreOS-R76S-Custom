include $(TOPDIR)/rules.mk
PKG_NAME:=r76s-core
PKG_VERSION:=1.4.1
PKG_RELEASE:=1
PKGARCH:=all
include $(INCLUDE_DIR)/package.mk
define Package/r76s-core
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=R76S service, DNS and OTA coordination
  DEPENDS:=+lua +libuci-lua +luci-lib-jsonc +lyaml +curl +flock +resolveip +bind-dig +openssl-util
endef
define Build/Compile
endef
define Package/r76s-core/conffiles
/etc/config/r76s
endef
define Package/r76s-core/install
	$(CP) ./files/* $(1)/
	chmod 0755 $(1)/usr/libexec/r76s/* $(1)/usr/bin/r76s-health $(1)/etc/init.d/*
	$(INSTALL_DIR) $(1)/etc/rc.d
	$(LN) ../init.d/r76s-reconcile $(1)/etc/rc.d/S97r76s-reconcile
endef
$(eval $(call BuildPackage,r76s-core))
