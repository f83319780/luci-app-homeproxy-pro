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

if ! command -v ucode > "/dev/null" 2>&1; then
	echo "NOT RUN: ucode is not on PATH."
	echo "         Build the testbed toolchain first, or use tests/run.sh which"
	echo "         copies the checkout to a device when the host has no ucode:"
	echo "           sh tests/toolchain/build-ucode-linux.sh   # or -macos.sh"
	exit 2
fi

# homeproxy.uc validates data through /sbin/validate_data, which only exists on
# a target. Off-target the generator cases would fail on the very first
# hostname check, so point them at the local stand-in (which in turn uses the
# same validation code as the parser unit tests). On a target the production
# binary is used unchanged.
if [ ! -x /sbin/validate_data ] && [ -x "$ROOT/tests/toolchain/validate-data.sh" ]; then
	HP_VALIDATE_DATA="$ROOT/tests/toolchain/validate-data.sh"
	export HP_VALIDATE_DATA
fi

# Nothing in this suite is target-only any more.  Every source compiles with
# the toolchain from tests/toolchain/build-ucode-*.sh (which ships utpl, the
# luci.* ucode modules and a matching sing-box), and the files that import
# through an absolute /etc/homeproxy/... path are rewritten to the checkout
# below.  A missing piece of the toolchain now FAILS instead of being skipped:
# the old target-only skips are exactly what let a non-compiling
# update_subscriptions.uc, and a destructuring statement, reach the device.
SCRIPTS_DIR="$ROOT/root/etc/homeproxy/scripts"
mkdir -p "$WORK/syntax"

echo "== ucode grammar canary =="
if ! sh "$ROOT/tests/ucode/test_ucode_grammar.sh"; then
	echo "FAIL: ucode grammar does not match the target dialect"
	FAILED=1
fi

echo "== ucode syntax check =="
for file in "$SCRIPTS_DIR"/*.uc \
           "$SCRIPTS_DIR"/subscription/*.uc \
           "$SCRIPTS_DIR"/config/*.uc \
           "$SCRIPTS_DIR"/generator/*.uc \
           "$ROOT"/root/usr/share/rpcd/ucode/*; do
	[ -f "$file" ] || continue
	# Modules (with export statements) cannot be compiled as a program; they
	# are loaded through `import` below instead.
	case "$file" in
	*homeproxy.uc|*parse_uri.uc|*/subscription/*.uc|*/config/*.uc|*/generator/*.uc) continue ;;
	esac

	# luci.homeproxy imports homeproxy.uc through an absolute /etc/... path
	# that does not exist off-target.  Compile a rewritten copy instead of
	# skipping the file.
	target="$file"
	case "$file" in
	*/usr/share/rpcd/ucode/*)
		target="$WORK/syntax/$(basename "$file")"
		sed "s#'/etc/homeproxy/scripts/#'$SCRIPTS_DIR/#g" "$file" > "$target" ;;
	esac

	if ! ucode -L "$SCRIPTS_DIR" -c -o "/dev/null" "$target" 2> "/tmp/hp-ucode-syntax.err"; then
		echo "FAIL: ${file#"$ROOT"/}"
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
# `config/*.uc` is imported through a relative `./config/*.uc` by both
# generators, so a syntax error there only surfaces when a generator runs;
# import it explicitly too so the failure names the module.
#
# `generator/*.uc` was added in PHASE 4: client.uc and server.uc are the
# public entry points and pull every other generator module in transitively.
# Loading them through `import` is the cheapest way to syntax-check the
# whole subtree at once.
for module in subscription/filter subscription/decoder subscription/fetcher subscription/repository \
              config/loader config/model config/adapter \
              generator/client generator/server; do
	if ! ucode -L "$SCRIPTS_DIR" -e "import * as m from \"$SCRIPTS_DIR/$module.uc\";" 2> "/tmp/hp-ucode-syntax.err"; then
		echo "FAIL: module $module"
		head -8 "/tmp/hp-ucode-syntax.err"
		FAILED=1
	fi
done
[ "$FAILED" -eq 0 ] && echo "PASS: all ucode sources compile"

echo "== fw4 chain/set inventory =="
sh "$ROOT/tests/ucode/test_fw4_names.sh" "$ROOT" || FAILED=1

echo "== shell syntax check =="
# init.d/homeproxy and the runtime helpers are shell, so no ucode check covers
# them.  They decide whether a bad configuration can leave the router without
# a service, so a syntax error there is as bad as one in the generators.
for file in "$ROOT"/root/etc/init.d/* \
            "$ROOT"/root/etc/homeproxy/scripts/*.sh \
            "$ROOT"/root/etc/homeproxy/scripts/runtime/*.sh; do
	[ -f "$file" ] || continue
	if ! sh -n "$file" 2> "/tmp/hp-shell-syntax.err"; then
		echo "FAIL: ${file#"$ROOT"/}"
		head -5 "/tmp/hp-shell-syntax.err"
		FAILED=1
	fi
done

echo "== runtime configuration transaction =="
sh "$ROOT/tests/runtime/test_config_transaction.sh" "$ROOT" || FAILED=1

echo "== firewall template rendering =="
# utpl ships with ucode (it is a symlink to the same binary), so this check
# runs off-target too.  A toolchain without it is incomplete, not a reason to
# skip the only test that guards the fw4 statement layout.
if ! command -v utpl > "/dev/null" 2>&1; then
	echo "FAIL: utpl is missing; build the toolchain (tests/toolchain/build-ucode-*.sh)"
	FAILED=1
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

echo "== TLS / transport builder tests =="
rm -rf "$WORK/tls_transport"
mkdir -p "$WORK/tls_transport"
cp "$ROOT/root/etc/homeproxy/scripts/homeproxy.uc" "$WORK/tls_transport/"
cp "$ROOT/tests/ucode/test_tls_transport.uc" "$WORK/tls_transport/"
if ( cd "$WORK/tls_transport" && ucode test_tls_transport.uc ); then
	echo "PASS: TLS / transport builder tests"
else
	echo "FAIL: TLS / transport builder tests"
	FAILED=1
fi

echo "== subscription fetcher tests =="
rm -rf "$WORK/fetcher"
mkdir -p "$WORK/fetcher"
cp "$ROOT/root/etc/homeproxy/scripts/subscription/fetcher.uc" "$WORK/fetcher/fetcher.uc"
cp "$ROOT/tests/ucode/mocks/homeproxy_fetcher.uc" "$WORK/fetcher/homeproxy.uc"
cp "$ROOT/tests/ucode/test_subscription_fetcher.uc" "$WORK/fetcher/"
if ( cd "$WORK/fetcher" && ucode -L "$WORK/fetcher" test_subscription_fetcher.uc ); then
	echo "PASS: subscription fetcher tests"
else
	echo "FAIL: subscription fetcher tests"
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

echo "== golden protocol snapshot =="
sh "$ROOT/tests/ucode/test_golden_outbounds.sh" "$ROOT" "$WORK/golden" || FAILED=1

echo "== protocol inventory =="
sh "$ROOT/tests/ucode/test_protocol_inventory.sh" "$ROOT" "$WORK/inventory" || FAILED=1

echo "== domain model skeleton =="
sh "$ROOT/tests/ucode/test_domain_model_skeleton.sh" "$ROOT" "$WORK/domain_model" || FAILED=1

exit $FAILED
