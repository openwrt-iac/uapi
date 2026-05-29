include $(TOPDIR)/rules.mk

PKG_NAME:=uapi
PKG_VERSION:=$(shell sed 's/-/_/g' $(CURDIR)/files/VERSION)
PKG_RELEASE:=1

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
           +ucode-mod-fs +ucode-mod-digest +ucode-mod-log
endef

define Package/uapi/description
  uapi translates standard HTTP REST verbs into OpenWrt ubus/uci operations,
  designed as a backend for Infrastructure-as-Code workflows such as Terraform.
  Curated endpoints under /api/v1/<domain>/... plus a generic /api/v1/raw/...
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
cat <<EOF

uapi installed. Bootstrap:
  1. Create a token:    uapi-token create --name <label> --scope '*:rw'
  2. Verify reachable:  curl -H "Authorization: Bearer <token>" https://<router>/api/v1/system
  3. OpenAPI spec at:   /usr/share/uapi/openapi.json (also GET /api/v1/openapi.json)

Future upgrades from the project feed:
  curl -fsSL https://raspbeguy.github.io/uapi/uapi-feed.pub.pem > /etc/apk/keys/uapi-feed.pub.pem
  echo 'https://raspbeguy.github.io/uapi/packages/all/uapi/packages.adb' > /etc/apk/repositories.d/uapi.list
  apk update && apk upgrade uapi

EOF
exit 0
endef

define Package/uapi/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
uci -q del_list uhttpd.main.ucode_prefix='/api/v1=/usr/share/uapi/main.uc' || true
uci -q commit uhttpd || true
/etc/init.d/uhttpd reload || true
exit 0
endef

$(eval $(call BuildPackage,uapi))
