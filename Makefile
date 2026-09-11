# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2022-2023 ImmortalWrt.org
#

include $(TOPDIR)/rules.mk

LUCI_TITLE:=The modern ImmortalWrt proxy platform for ARM64/AMD64 (sing-box 1.14)
# Pure ucode/JS payload with no compiled code, so the package itself is arch
# independent. The real arch constraint comes from the +sing-box dependency,
# which the feed builds for every architecture Go supports (aarch64, arm,
# mipsel, riscv64, x86_64, ...). See the "支持架构" section in README.md.
LUCI_PKGARCH:=all
LUCI_DEPENDS:= \
	+sing-box \
	+firewall4 \
	+kmod-nft-tproxy \
	+ucode-mod-digest

PKG_NAME:=luci-app-homeproxy
PKG_VERSION:=27.905.1.14
PKG_RELEASE:=10

define Package/luci-app-homeproxy/conffiles
/etc/config/homeproxy
/etc/homeproxy/certs/
/etc/homeproxy/ruleset/
/etc/homeproxy/resources/direct_list.txt
/etc/homeproxy/resources/proxy_list.txt
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
