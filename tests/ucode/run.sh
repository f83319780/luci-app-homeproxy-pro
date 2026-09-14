#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Run the ucode-level tests: the parse_uri unit tests, the fw4 inventory check
# and the generator regression fixtures. Requires ucode; sing-box is needed for
# the generator cases (they validate the emitted config with `sing-box check`).
#
# Usage: sh tests/ucode/run.sh <repo-root> [work-dir]

ROOT="${1:-.}"
WORK="${2:-/tmp/hp-ucode-tests}"

ROOT="$(cd "$ROOT" && pwd)"
FAILED=0
SKIPPED=0

# homeproxy.uc validates data through /sbin/validate_data, which only exists on
# a target. Off-target the generator cases would fail on the very first
# hostname check, so point them at the local stand-in (which in turn uses the
# same validation code as the parser unit tests). On a target the production
# binary is used unchanged.
if [ ! -x /sbin/validate_data ] && [ -x "$ROOT/tests/toolchain/validate-data.sh" ]; then
	HP_VALIDATE_DATA="$ROOT/tests/toolchain/validate-data.sh"
	export HP_VALIDATE_DATA
fi

# Two sources import through an absolute OpenWrt path
# (/etc/homeproxy/scripts/homeproxy.uc), which only exists on a target. They
# are compile-checked in CI on the device; on a development host `ucode -c`
# cannot resolve the import and would report a false failure. The list is
# reported at the end so a local run never silently drops coverage.
# On a target /etc/homeproxy exists, so the absolute imports resolve and the
# full check runs. On a development host they cannot, and the target-only
# sources are skipped instead of reported as failures.
ON_TARGET=0
[ -d /etc/homeproxy/scripts ] && ON_TARGET=1

is_target_only() {
	case "$1" in
	# Import through an absolute /etc/... path that only exists on a target.
	*/etc/homeproxy/scripts/firewall_pre.uc|*/usr/share/rpcd/ucode/luci.homeproxy) return 0 ;;
	# Imports init_action from luci.sys (three start/stop calls around a
	# subscription update) and stops/starts the real service, which cannot be
	# staged off-target.
	*/etc/homeproxy/scripts/update_subscriptions.uc) return 0 ;;
	esac
	return 1
}

skip_reason() {
	case "$1" in
	*/etc/homeproxy/scripts/firewall_pre.uc|*/usr/share/rpcd/ucode/luci.homeproxy|*/etc/homeproxy/scripts/firewall_post.ut)
		echo "imports an absolute /etc/... path" ;;
	*/etc/homeproxy/scripts/update_subscriptions.uc)
		echo "imports init_action from luci.sys and drives the service" ;;
	*) echo "needs a target" ;;
	esac
}

echo "== ucode syntax check =="
for file in "$ROOT"/root/etc/homeproxy/scripts/*.uc \
           "$ROOT"/root/etc/homeproxy/scripts/subscription/*.uc \
           "$ROOT"/root/etc/homeproxy/scripts/config/*.uc \
           "$ROOT"/root/usr/share/rpcd/ucode/*; do
	[ -f "$file" ] || continue
	# Modules (with export statements) cannot be compiled as a program; they
	# are loaded through `import` below instead.
	case "$file" in
	*homeproxy.uc|*parse_uri.uc|*/subscription/*.uc|*/config/*.uc) continue ;;
	esac
	if is_target_only "$file" && [ "$ON_TARGET" -eq 0 ]; then
		echo "SKIP: ${file#"$ROOT"/} ($(skip_reason "$file"), needs a target)"
		SKIPPED=$((SKIPPED + 1))
		continue
	fi
	if ! ucode -L "$ROOT/root/etc/homeproxy/scripts" -c -o "/dev/null" "$file" 2> "/tmp/hp-ucode-syntax.err"; then
		echo "FAIL: $file"
		head -8 "/tmp/hp-ucode-syntax.err"
		FAILED=1
	fi
done
# Modules are syntax-checked by loading them through `import`. The
# -e expression is a no-op program; the import itself is what we
# want to validate. Subscriptions and config modules live in
# subdirectories, so they need an explicit `.uc` path that ucode's
# resolver can follow (bare `subscription/filter` is not searched
# in the -L tree, only top-level module names are).
for module in homeproxy parse_uri; do
	if ! ucode -L "$ROOT/root/etc/homeproxy/scripts" -e "import * as m from \"$module\";" 2> "/tmp/hp-ucode-syntax.err"; then
		echo "FAIL: module $module"
		head -8 "/tmp/hp-ucode-syntax.err"
		FAILED=1
	fi
done
for module in subscription/filter subscription/decoder subscription/fetcher subscription/repository; do
	if ! ucode -L "$ROOT/root/etc/homeproxy/scripts" -e "import * as m from \"$ROOT/root/etc/homeproxy/scripts/$module.uc\";" 2> "/tmp/hp-ucode-syntax.err"; then
		echo "FAIL: module $module"
		head -8 "/tmp/hp-ucode-syntax.err"
		FAILED=1
	fi
done
[ "$FAILED" -eq 0 ] && echo "PASS: all ucode sources compile"

echo "== fw4 chain/set inventory =="
sh "$ROOT/tests/ucode/test_fw4_names.sh" "$ROOT" || FAILED=1

echo "== firewall template rendering =="
if [ "$ON_TARGET" -eq 0 ]; then
	echo "SKIP: firewall_post.ut ($(skip_reason "$ROOT/root/etc/homeproxy/scripts/firewall_post.ut"), needs a target)"
	SKIPPED=$((SKIPPED + 1))
else
	sh "$ROOT/tests/ucode/test_firewall_template.sh" "$ROOT" || FAILED=1
fi

echo "== parse_uri unit tests =="
rm -rf "$WORK/parse_uri"
mkdir -p "$WORK/parse_uri"
cp "$ROOT/root/etc/homeproxy/scripts/parse_uri.uc" "$WORK/parse_uri/"
cp "$ROOT/tests/ucode/mocks/homeproxy.uc" "$WORK/parse_uri/"
cp "$ROOT/tests/ucode/test_parse_uri.uc" "$WORK/parse_uri/"

if ( cd "$WORK/parse_uri" && ucode test_parse_uri.uc ); then
	echo "PASS: parse_uri unit tests"
else
	echo "FAIL: parse_uri unit tests"
	FAILED=1
fi

echo "== subscription filter unit tests =="
# The production modules live at root/etc/homeproxy/scripts/subscription/
# *.uc and are imported by update_subscriptions.uc with a relative path.
# For the unit tests we want the modules on a flat search path so their
# `from 'homeproxy'` import resolves to the mock, so we stage them at
# the work dir top level (drop the subscription/ prefix) and let the
# test files import them as bare names.
rm -rf "$WORK/subscription"
mkdir -p "$WORK/subscription"
cp "$ROOT/tests/ucode/mocks/homeproxy.uc" "$WORK/subscription/"
cp "$ROOT/root/etc/homeproxy/scripts/subscription/filter.uc" "$WORK/subscription/filter.uc"
cp "$ROOT/root/etc/homeproxy/scripts/subscription/decoder.uc" "$WORK/subscription/decoder.uc"
cp "$ROOT/tests/ucode/test_subscription_filter.uc" "$WORK/subscription/"
cp "$ROOT/tests/ucode/test_subscription_decoder.uc" "$WORK/subscription/"

if ( cd "$WORK/subscription" && ucode -L "$WORK/subscription" test_subscription_filter.uc ); then
	echo "PASS: subscription filter unit tests"
else
	echo "FAIL: subscription filter unit tests"
	FAILED=1
fi

if ( cd "$WORK/subscription" && ucode -L "$WORK/subscription" test_subscription_decoder.uc ); then
	echo "PASS: subscription decoder unit tests"
else
	echo "FAIL: subscription decoder unit tests"
	FAILED=1
fi

echo "== subscription repository integration test =="
# The repository writes to a real UCI cursor, so its testbed needs
# the uci + digest shared objects. tests/ucode/run.sh exports
# UCODE_MODULES_DIR for that; the test runner script itself stages
# a sandboxed config dir with seed sections.
sh "$ROOT/tests/ucode/test_subscription_repository.sh" "$ROOT" "$WORK/subscription_repo" || FAILED=1

echo "== homeproxy helper tests =="
rm -rf "$WORK/homeproxy"
mkdir -p "$WORK/homeproxy"
cp "$ROOT/root/etc/homeproxy/scripts/homeproxy.uc" "$WORK/homeproxy/"
cp "$ROOT/tests/ucode/test_homeproxy_utils.uc" "$WORK/homeproxy/"
if ( cd "$WORK/homeproxy" && ucode test_homeproxy_utils.uc ); then
	echo "PASS: executeCommand() regression tests"
else
	echo "FAIL: executeCommand() regression tests"
	FAILED=1
fi

echo "== executeCommand() failure-path test =="
rm -rf "$WORK/homeproxy_inject"
mkdir -p "$WORK/homeproxy_inject"
sed 's|const exitcode = system(.*);|die("injected failure");|' \
	"$ROOT/root/etc/homeproxy/scripts/homeproxy.uc" > "$WORK/homeproxy_inject/homeproxy.uc"
cp "$ROOT/tests/ucode/test_homeproxy_utils_inject.uc" "$WORK/homeproxy_inject/"
if ( cd "$WORK/homeproxy_inject" && ucode test_homeproxy_utils_inject.uc 2>"/dev/null" ); then
	echo "PASS: executeCommand() failure path"
else
	echo "FAIL: executeCommand() failure path"
	FAILED=1
fi

echo "== generator regression tests =="
sh "$ROOT/tests/ucode/test_generators.sh" "$ROOT" "$WORK/generators" || FAILED=1

echo "== architecture demo equivalence =="
sh "$ROOT/tests/ucode/test_demo_architecture.sh" "$ROOT" "$WORK/demo" || FAILED=1

echo "== domain model skeleton =="
sh "$ROOT/tests/ucode/test_domain_model_skeleton.sh" "$ROOT" "$WORK/domain_model" || FAILED=1

if [ "$SKIPPED" -gt 0 ]; then
	echo
	echo "$SKIPPED check(s) skipped: they need an OpenWrt target (see SKIP lines above)."
fi

exit $FAILED
