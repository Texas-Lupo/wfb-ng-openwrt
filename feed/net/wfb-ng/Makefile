include $(TOPDIR)/rules.mk

PKG_NAME:=wfb-ng

WFB_VERSION?=2025.06.25
WFB_REPO?=https://github.com/gilankpam/wfb-ng.git
WFB_COMMIT?=af6ba85eface27279709477077d3362c69bb2576

PKG_VERSION:=$(WFB_VERSION)
PKG_RELEASE:=1

PKG_SOURCE_PROTO:=git
PKG_SOURCE_URL:=$(WFB_REPO)
PKG_SOURCE_VERSION:=$(WFB_COMMIT)
PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION)-$(PKG_SOURCE_VERSION).tar.gz
# Content is pinned by the full commit SHA above; the fork branch is mutable, so
# we skip the tarball mirror hash. Replace with a real mkhash for a frozen release.
PKG_MIRROR_HASH:=skip

PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE.txt
PKG_MAINTAINER:=gilankpam <gilankpam@gmail.com>

PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

# Build only the two binaries we ship (skip wfb_tun/keygen/cmd and their deps).
MAKE_FLAGS += VERSION=$(PKG_VERSION) COMMIT=$(PKG_SOURCE_VERSION) wfb_rx wfb_tx

define Package/wfb-ng
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Wireless
  TITLE:=wfb-ng minimal RX/TX (CPE510 ground station)
  URL:=https://github.com/gilankpam/wfb-ng
  DEPENDS:=+libpcap +libsodium +libstdcpp
endef

define Package/wfb-ng/description
  Minimal wfb-ng build: wfb_rx and wfb_tx binaries plus a POSIX-sh launcher
  (wfb-ng.sh) and a procd init script (/etc/init.d/wfb-ng) that supervises the
  per-stream forwarders/injectors for a single-card OpenWrt cluster node.
endef

define Package/wfb-ng/conffiles
/etc/wfb-ng.conf
endef

define Package/wfb-ng/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/wfb_rx $(1)/usr/bin/wfb_rx
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/wfb_tx $(1)/usr/bin/wfb_tx
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/wfb-ng.sh $(1)/usr/sbin/wfb-ng.sh
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/wfb-ng.init $(1)/etc/init.d/wfb-ng
	$(INSTALL_DIR) $(1)/etc
	$(INSTALL_CONF) ./files/wfb-ng.conf $(1)/etc/wfb-ng.conf
endef

$(eval $(call BuildPackage,wfb-ng))
