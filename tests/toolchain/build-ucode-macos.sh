#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Build a self-contained ucode toolchain on macOS so tests/run.sh can execute
# the ucode part locally instead of copying the checkout to an OpenWrt device.
#
# ucode itself has no Homebrew formula, and its uci/ubus modules need the
# OpenWrt libraries (libubox, libuci, libubus), which are not packaged either.
# Everything is therefore built from source into a private prefix, so the host
# stays untouched and removal is a single `rm -rf`.
#
# Usage:
#   sh tests/toolchain/build-ucode-macos.sh [prefix] [build-dir]
#
# Defaults: prefix=~/.local/ucode-testbed  build-dir=/tmp/ucode-build
#
# After a successful build the script prints the PATH/shim setup that
# tests/run.sh expects. See tests/README.md for the runner contract.

set -eu

PREFIX="${1:-$HOME/.local/ucode-testbed}"
BUILD="${2:-/tmp/ucode-build}"

# The package Makefile targets sing-box 1.14; tests/ucode/test_generators.sh
# feeds the generated configs to `sing-box check`, so the version has to match.
SINGBOX_VERSION="1.14.0"

JSONC_PREFIX="$(brew --prefix json-c 2>/dev/null || true)"
[ -n "$JSONC_PREFIX" ] || { echo "ERROR: json-c is required (brew install json-c)"; exit 1; }

# The digest module (ucode-mod-digest in the package Makefile) needs libmd,
# whose pkg-config file only exists once the formula is installed.
LIBMD_PREFIX="$(brew --prefix libmd 2>/dev/null || true)"
[ -n "$LIBMD_PREFIX" ] || { echo "ERROR: libmd is required (brew install libmd)"; exit 1; }

mkdir -p "$PREFIX" "$PREFIX/bin" "$BUILD"
PREFIX="$(cd "$PREFIX" && pwd)"
BUILD="$(cd "$BUILD" && pwd)"

# Teach pkg-config and the linker where the private prefix lives, and make the
# Homebrew json-c visible to libubox's PKG_SEARCH_MODULE(json-c).
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$JSONC_PREFIX/lib/pkgconfig:$LIBMD_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export CPPFLAGS="-I$PREFIX/include -I$JSONC_PREFIX/include ${CPPFLAGS:-}"
export LDFLAGS="-L$PREFIX/lib -L$JSONC_PREFIX/lib ${LDFLAGS:-}"

# BUILD_WITH_INSTALL_RPATH links against the final install location from the
# start, so `cmake --install` never has to rewrite the load commands. Without
# it every re-install over an existing prefix makes install_name_tool fail
# (it tries to delete an RPATH entry that was already dropped last time).
CMAKE_COMMON="-DCMAKE_INSTALL_PREFIX=$PREFIX
	-DCMAKE_INSTALL_LIBDIR=lib
	-DCMAKE_BUILD_TYPE=Release
	-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
	-DCMAKE_PREFIX_PATH=$PREFIX;$JSONC_PREFIX;$LIBMD_PREFIX
	-DCMAKE_IGNORE_PATH=/opt/homebrew;/usr/local"

clone() {
	repo="$1"
	dir="$BUILD/$(basename "$repo")"
	if [ -d "$dir/.git" ]; then
		git -C "$dir" fetch --depth 1 origin >/dev/null 2>&1 || true
	else
		git clone --depth 1 "https://github.com/$repo.git" "$dir"
	fi
	echo "$dir"
}

# The full luci tree is large and only two directories are needed; fetch it in
# partial/sparse mode so the toolchain build stays quick.
clone_sparse() {
	repo="$1"
	path="$2"
	dir="$BUILD/$(basename "$repo")"
	if [ ! -d "$dir/.git" ]; then
		git clone --depth 1 --filter=blob:none --sparse \
			"https://github.com/$repo.git" "$dir" >/dev/null
	fi
	git -C "$dir" sparse-checkout set "$path" >/dev/null
	echo "$dir"
}

build() {
	dir="$1"
	shift
	echo "==> building $(basename "$dir")"
	# shellcheck disable=SC2086
	cmake -S "$dir" -B "$dir/build" $CMAKE_COMMON "$@" >/dev/null
	cmake --build "$dir/build" -j"$(sysctl -n hw.ncpu)" >/dev/null
	cmake --install "$dir/build" >/dev/null
}

# libubox first: it provides ubox, blobmsg_json and the headers that both the
# uci and ubus modules (and ucode's own ubus/uci plugins) link against.
build "$(clone openwrt/libubox)" -DBUILD_LUA=OFF -DBUILD_EXAMPLES=OFF

# libuci: the cursor() implementation used by every generator and the RPC daemon.
build "$(clone openwrt/uci)" -DBUILD_LUA=OFF

# libubus: ubus.connect() is used by generate_client.uc and the RPC daemon.
build "$(clone openwrt/ubus)" -DBUILD_LUA=OFF

# ucode last, so its CMake detects all three libraries and enables the
# uci/ubus/uloop plugins. ffi and nl80211 are left off: not needed by the
# tests and their headers are not present on macOS.
#
# Two macOS-specific compile adjustments:
#   -Wunguarded-availability-new  macOS 26's SDK annotates pipe2() as available
#     in 27.0 while libSystem only weakly imports it before that. ucode ships
#     its own pipe2() fallback in platform.c, but the SDK declaration makes
#     every call site a -Werror failure. The symbol is provided by ucode
#     itself, so silencing the availability diagnostic is safe.
#   -Wno-error=unused-command-line-argument, -Wno-deprecated-declarations
#     keep unrelated SDK drift from failing a Release build.
build "$(clone jow-/ucode)" \
	-DUBUS_SUPPORT=ON -DUCI_SUPPORT=ON -DULOOP_SUPPORT=ON \
	-DFFI_SUPPORT=OFF -DNL80211_SUPPORT=OFF -DRTNL_SUPPORT=OFF \
	-DDEBUG_SUPPORT=ON -DZLIB_SUPPORT=ON \
	-DCMAKE_C_FLAGS="-Wno-error -Wno-unguarded-availability-new -Wno-deprecated-declarations"

# liblucihttp: homeproxy.uc, parse_uri.uc and the RPC daemon import
# luci.http for urldecode_params()/urlencode()/urldecode(). luci.http is a
# thin ucode wrapper around this C module, so it has to exist for the
# generators to even load. Built after ucode, whose headers it needs.
#
# Upstream is Linux-only in three ways, so the install is done by hand instead
# of `cmake --install`:
#   -Wl,-L$PREFIX/lib       upstream links `-lucode` by bare name without a
#     find_library() call, relying on libucode being in a default search path.
#   .so module suffix       ucode only treats a path ending in ".so" as a
#     native module. A .dylib -- or a symlink to one, which ucode resolves
#     back via realpath -- is compiled as ucode source and fails with
#     "Unexpected character". CMake 4 no longer lets a preload file override
#     CMAKE_SHARED_LIBRARY_SUFFIX, so the two artifacts are copied to their
#     final names here.
#   install_name/rpath      the binding links @rpath/libucode.0.dylib and
#     lucihttp.so links @rpath/lucihttp.dylib; both are rewritten to absolute
#     paths inside the prefix.
# -I.../include/ucode and -I.../json-c/include: upstream adds no include path
# for ucode, whose module.h pulls in json-c.
# CMAKE_POLICY_VERSION_MINIMUM: upstream still declares
# cmake_minimum_required(2.6), which CMake >= 4 refuses outright.
LUCIHTTP_DIR="$(clone jow-/lucihttp)"
echo "==> building lucihttp"
cmake -S "$LUCIHTTP_DIR" -B "$LUCIHTTP_DIR/build" $CMAKE_COMMON \
	-DBUILD_LUA=OFF -DBUILD_TESTS=OFF \
	-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
	-DCMAKE_SHARED_LINKER_FLAGS="-L$PREFIX/lib" \
	-DCMAKE_C_FLAGS="-Wno-error -Wno-deprecated-declarations -I$PREFIX/include -I$JSONC_PREFIX/include" >/dev/null
cmake --build "$LUCIHTTP_DIR/build" -j"$(sysctl -n hw.ncpu)" >/dev/null

mkdir -p "$PREFIX/lib" "$PREFIX/lib/ucode" "$PREFIX/include/lucihttp"
cp "$LUCIHTTP_DIR"/include/lucihttp/*.h "$PREFIX/include/lucihttp/"
# liblucihttp.0.1.dylib is the real Mach-O file; the unversioned names are
# build-tree symlinks and `cp` would copy the link itself.
cp "$LUCIHTTP_DIR/build/liblucihttp.0.1.dylib" "$PREFIX/lib/liblucihttp.so"
cp "$LUCIHTTP_DIR/build/ucode/lucihttp.dylib" "$PREFIX/lib/ucode/lucihttp.so"

install_name_tool -id "$PREFIX/lib/liblucihttp.so" "$PREFIX/lib/liblucihttp.so"
install_name_tool -id "$PREFIX/lib/ucode/lucihttp.so" \
	-change "@rpath/liblucihttp.0.dylib" "$PREFIX/lib/liblucihttp.so" \
	-change "@rpath/lucihttp.dylib" "$PREFIX/lib/ucode/lucihttp.so" \
	-change "@rpath/libucode.0.dylib" "$PREFIX/lib/libucode.0.dylib" \
	"$PREFIX/lib/ucode/lucihttp.so"

# The luci.* ucode modules themselves (http.uc, sys.uc, ...) are pure sources
# shipped by the luci-base package; OpenWrt installs them to
# /usr/share/ucode/luci. Stage the same layout inside the prefix so
# `import { urldecode_params } from 'luci.http'` resolves locally.
LUCI_DIR="$(clone_sparse openwrt/luci modules/luci-base/ucode)"
mkdir -p "$PREFIX/share/ucode/luci"
cp "$LUCI_DIR"/modules/luci-base/ucode/*.uc "$PREFIX/share/ucode/luci/"
cp -R "$LUCI_DIR"/modules/luci-base/ucode/controller "$PREFIX/share/ucode/luci/" 2>/dev/null || true
cp -R "$LUCI_DIR"/modules/luci-base/ucode/template "$PREFIX/share/ucode/luci/" 2>/dev/null || true

# sing-box is not built here, but the generator cases run `sing-box check` and
# the package targets sing-box >= 1.14, so an older binary reports unknown
# fields ("handshake_timeout", "certificate_provider") and fails the fixtures.
# Take the official release binary unless a matching one already exists.
sb_version() {
	if [ -x "$PREFIX/bin/sing-box" ]; then
		"$PREFIX/bin/sing-box" version 2>/dev/null |
			awk '/^sing-box version /{sub(/^sing-box version /,""); sub(/-.*/,""); print; exit}'
	fi
}
if [ "$(sb_version)" != "$SINGBOX_VERSION" ]; then
	echo "==> fetching sing-box $SINGBOX_VERSION"
	sb_tar="sing-box-$SINGBOX_VERSION-darwin-arm64.tar.gz"
	sb_url="https://github.com/SagerNet/sing-box/releases/download/v$SINGBOX_VERSION/$sb_tar"
	if ! curl -fsSL "$sb_url" -o "$BUILD/$sb_tar" >/dev/null 2>&1; then
		echo "ERROR: could not download $sb_url"
		exit 1
	fi
	tar xzf "$BUILD/$sb_tar" -C "$BUILD"
	cp "$BUILD/sing-box-$SINGBOX_VERSION-darwin-arm64/sing-box" "$PREFIX/bin/sing-box"
	chmod +x "$PREFIX/bin/sing-box"
fi

echo
echo "==> verifying"
"$PREFIX/bin/ucode" -e 'printf("ucode %s\n", ARGV[0] ?? "ok");'
printf '  sing-box   %s\n' "$("$PREFIX/bin/sing-box" version 2>/dev/null | head -1)"
FAILED=0
for mod in fs math uci ubus digest zlib struct resolv socket lucihttp luci.http luci.sys; do
	if "$PREFIX/bin/ucode" -e "import * as m from '$mod';" 2>/dev/null; then
		printf '  module %-10s OK\n' "$mod"
	else
		printf '  module %-10s MISSING\n' "$mod"
		FAILED=1
	fi
done

# Exercise the exact parser helper the share-link code depends on, so a
# broken lucihttp binding is detected here rather than mid-refactor. The
# expected values mirror upstream semantics: '+' decodes to a space inside a
# value and a repeated key keeps the last occurrence.
if ! "$PREFIX/bin/ucode" -e '
	import { urldecode_params } from "luci.http";
	let p = urldecode_params("a=1&b=x+y&b=2");
	(p.a == "1" && p.b == "2") || exit(1);
' 2>/dev/null; then
	echo "  luci.http urldecode_params  MISMATCH"
	FAILED=1
fi

echo
if [ "$FAILED" -eq 0 ]; then
	echo "==> done"
else
	echo "==> done WITH PROBLEMS (see MISSING/MISMATCH above)"
fi
echo "prefix: $PREFIX"
echo
echo "Add the toolchain to PATH (needed by tests/run.sh):"
echo "  export PATH=\"$PREFIX/bin:\$PATH\""
echo "The prefix also carries the matching sing-box, so it must come before any"
echo "other sing-box in PATH (e.g. /usr/local/bin)."

exit $FAILED
