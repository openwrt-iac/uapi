include $(TOPDIR)/rules.mk

PKG_NAME:=uapi
PKG_VERSION:=$(shell sed 's/-/_/g' $(CURDIR)/files/VERSION)
PKG_RELEASE:=3

PKG_LICENSE:=MIT
PKG_MAINTAINER:=Guy Godfroy <guy.godfroy@gugod.fr>

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/uapi
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Native HTTP REST API for OpenWrt
  URL:=https://github.com/raspbeguy/uapi
  PKGARCH:=all
  DEPENDS:=+uhttpd +uhttpd-mod-ucode +ucode +ucode-mod-ubus +ucode-mod-uci \
           +ucode-mod-fs +ucode-mod-digest +ucode-mod-log +rpcd-mod-iwinfo
endef

define Package/uapi/description
  uapi translates standard HTTP REST verbs into OpenWrt ubus/uci operations,
  designed as a backend for Infrastructure-as-Code workflows such as Terraform.
  Curated endpoints under /api/v2/<domain>/... plus a generic /api/v2/raw/...
  passthrough for the long tail.
endef

define Package/uapi/conffiles
/etc/config/uapi
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/uapi/install
	$(INSTALL_DIR) $(1)/usr/share/uapi/lib
	$(INSTALL_DIR) $(1)/usr/share/uapi/resources
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/uci-defaults

	$(INSTALL_DATA) ./files/usr/share/uapi/main.uc      $(1)/usr/share/uapi/main.uc
	$(INSTALL_DATA) ./files/usr/share/uapi/raw.uc       $(1)/usr/share/uapi/raw.uc
	$(INSTALL_DATA) ./files/usr/share/uapi/openapi.json $(1)/usr/share/uapi/openapi.json
	$(INSTALL_DATA) ./files/usr/share/uapi/VERSION      $(1)/usr/share/uapi/VERSION
	$(INSTALL_DATA) ./files/usr/share/uapi/lib/*.uc       $(1)/usr/share/uapi/lib/
	$(INSTALL_DATA) ./files/usr/share/uapi/resources/*.uc $(1)/usr/share/uapi/resources/

	$(INSTALL_BIN) ./files/usr/bin/uapi-token $(1)/usr/bin/uapi-token

	$(INSTALL_CONF) ./files/etc/config/uapi $(1)/etc/config/uapi
	$(INSTALL_BIN)  ./files/etc/uci-defaults/99-uapi $(1)/etc/uci-defaults/99-uapi
endef

define Package/uapi/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
[ -x /etc/uci-defaults/99-uapi ] && /etc/uci-defaults/99-uapi && rm -f /etc/uci-defaults/99-uapi
# uhttpd-mod-ucode compiles main.uc at parent startup and caches the VM. A
# plain "reload" does not re-read the script, so upgrades that overwrite
# /usr/share/uapi/*.uc would otherwise keep serving the previous version's
# code until something else restarted uhttpd. Force a restart so new code is
# in effect immediately after `apk add` / `apk upgrade uapi`.
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
# Only show the bootstrap message when no token exists yet. The token store
# survives upgrades and remove/reinstall (conffile), so on second-and-later
# installs the operator already knows the drill.
if ! uci -q show uapi 2>/dev/null | grep -q '=token$$'; then
cat <<EOF

uapi installed. Bootstrap:
  1. Create a token:    uapi-token create --name <label> --scope '*:rw'
  2. Verify reachable:  curl -H "Authorization: Bearer <token>" https://<router>/api/v2/system
  3. OpenAPI spec at:   /usr/share/uapi/openapi.json (also GET /api/v2/openapi.json)

Future upgrades from the project feed:
  curl -fsSL https://raspbeguy.github.io/uapi/uapi-feed.pub.pem > /etc/apk/keys/uapi-feed.pub.pem
  echo 'https://raspbeguy.github.io/uapi/packages/all/uapi/packages.adb' > /etc/apk/repositories.d/uapi.list
  apk update && apk upgrade uapi

EOF
fi
exit 0
endef

define Package/uapi/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
uci -q del_list uhttpd.main.ucode_prefix='/api/v2=/usr/share/uapi/main.uc' || true
# Belt-and-suspenders: also strip the v1 entry if a previous 2.0.0-broken
# install accidentally added it.
uci -q del_list uhttpd.main.ucode_prefix='/api/v1=/usr/share/uapi/main.uc' || true
uci -q commit uhttpd || true
/etc/init.d/uhttpd reload || true
exit 0
endef

$(eval $(call BuildPackage,uapi))
