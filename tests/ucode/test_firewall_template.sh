#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Render firewall_post.ut and verify the homeproxy fw4 objects survive as real
# nft statements.
#
# The template opens with `{%-`, which trims the whitespace in front of it: any
# text placed above that tag loses its trailing newline and is glued onto the
# first generated statement, turning it into a comment. That silently dropped
# every homeproxy chain/set from the fw4 ruleset once, so keep this check.
#
# Two layers, because the render needs the real `fw4` ucode module which only
# exists on a device (OpenWrt's firewall4 package ships /usr/share/ucode/fw4.uc):
#
#   1. a source-level assertion, always run, that the glue condition itself
#      cannot come back - `{%-` must be the first thing after the shebang, so
#      there is no preceding text whose newline could be trimmed;
#   2. the render + structural assertions, run whenever `fw4` is resolvable,
#      skipped with an explicit NOT RUN otherwise. A stub fw4 would make this
#      layer run everywhere, but it would also mean asserting on a ruleset the
#      real fw4 never produced, so the skip is kept and made *enforceable*
#      instead: HP_REQUIRE_FW4=1 turns it into a failure. tests/run.sh sets that
#      in its ssh branch, because a target always has firewall4 - so the one
#      environment that can run this layer must run it, and a target that
#      somehow cannot is a failure rather than a quiet NOT RUN.
#
#      `utpl` is not the blocker: it ships with ucode, which
#      tests/toolchain/build-ucode-linux.sh builds. The missing piece is
#      firewall4's /usr/share/ucode/fw4.uc.
#
# Usage: sh tests/ucode/test_firewall_template.sh <repo-root>

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
OUT="$(mktemp)"
FAILED=0

TEMPLATE_SRC="$ROOT/root/etc/homeproxy/scripts/firewall_post.ut"

# --- layer 1: the glue condition cannot come back ------------------------
# `{%-` trims the whitespace before it, so anything other than the shebang
# ahead of the tag ends up glued onto the first rendered line. Read the tag
# position directly instead of trusting a comment.
first_tag_line="$(grep -n '{%-' "$TEMPLATE_SRC" | head -1 | cut -d: -f1)"

if [ -z "$first_tag_line" ]; then
	echo "FAIL: firewall_post.ut has no '{%-' template tag"
	FAILED=1
else
	# Lines 1..(tag-1) must be blank or the shebang.
	bad="$(sed -n "1,$((first_tag_line - 1))p" "$TEMPLATE_SRC" |
		grep -nvE '^[[:space:]]*$|^#!/' || true)"
	if [ -n "$bad" ]; then
		echo "FAIL: text precedes the '{%-' tag and will be glued onto the first statement"
		echo "$bad" | head -3
		FAILED=1
	fi
fi

# --- layer 2: the render -------------------------------------------------
STAGE="$(mktemp -d)"
STAGED="$STAGE/firewall_post.ut"

# Probe with ucode, not utpl: `utpl -e` is not an eval flag, it renders the
# argument as template text and always succeeds.
if ! ucode -e 'require("fw4");' > "/dev/null" 2>&1; then
	echo "NOT RUN: the 'fw4' ucode module is not available (device-only), render skipped"

	# A skipped layer must not be able to hide a broken template. Firewall4 is
	# always installed where homeproxy runs, so the on-target suite sets
	# HP_REQUIRE_FW4=1 (tests/run.sh does it in the ssh branch) and a skip there
	# is a failure: it means the render stopped being exercised in the one
	# environment that can exercise it. `utpl` itself is not the blocker - it
	# ships with ucode, which the toolchain builds - the missing piece is
	# firewall4's /usr/share/ucode/fw4.uc, and stubbing that would mean
	# asserting on a ruleset the real fw4 never produced.
	if [ "${HP_REQUIRE_FW4:-0}" = "1" ]; then
		echo "FAIL: HP_REQUIRE_FW4=1 but 'fw4' is not resolvable, so the render"
		echo "      layer cannot run here and the template is unverified"
		rm -f "$OUT"
		exit 1
	fi

	[ "$FAILED" -eq 0 ] && echo "PASS: firewall_post.ut keeps '{%-' directly after the shebang"
	rm -f "$OUT"
	exit $FAILED
fi

# The template is written for a device: it imports homeproxy.uc through
# /etc/homeproxy/scripts/ and reads /etc/homeproxy/resources. Neither exists
# off-target, so render a staged copy with those prefixes rewritten to the
# checkout - the same trick run.sh uses for the absolute import in
# root/usr/share/rpcd/ucode/luci.homeproxy.
sed -e "s#'/etc/homeproxy/#'$ROOT/root/etc/homeproxy/#g" "$TEMPLATE_SRC" > "$STAGED"

# Hard guard: if the prefix ever changes, the sed silently no-ops and the
# render fails for an unrelated reason, which would look like a template
# regression. Refuse to run instead.
if grep -q "'/etc/homeproxy/" "$STAGED"; then
	echo "FAIL: firewall_post.ut: could not rewrite the device paths"
	echo "      (the '/etc/homeproxy/' prefix anchor no longer matches)"
	rm -f "$OUT"
	exit 1
fi

if ! utpl -S "$STAGED" > "$OUT" 2>"/tmp/hp-fw4tpl.err"; then
	echo "FAIL: could not render firewall_post.ut"
	head -5 "/tmp/hp-fw4tpl.err"
	rm -f "$OUT"
	exit 1
fi

# Declared unconditionally by the template, so they must always be present as
# standalone statements.
for name in homeproxy_local_addr_v4 homeproxy_wan_proxy_addr_v4; do
	if ! grep -q "^set $name {" "$OUT"; then
		echo "FAIL: 'set $name {' is missing from the rendered firewall template"
		grep -n "$name" "$OUT" | head -2
		FAILED=1
	fi
done

# A statement glued onto the preceding comment looks like
# "# <comment text>.set homeproxy_x {" -- exactly the failure mode above.
if grep -nE "^#[^!].*homeproxy_[a-z0-9_]+ \{" "$OUT" > "/dev/null"; then
	echo "FAIL: an nft statement is glued onto a comment line"
	grep -nE "^#[^!].*homeproxy_[a-z0-9_]+ \{" "$OUT" | head -2
	FAILED=1
fi

[ "$FAILED" -eq 0 ] && echo "PASS: firewall_post.ut renders homeproxy objects as standalone nft statements"

rm -f "$OUT"
exit $FAILED
