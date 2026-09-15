#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# One-shot entry point for the test suite:
#
#   tests/run.sh
#
# Translation coverage and the LuCI form snapshots run locally (they only need
# python3 / node). The ucode tests run locally when ucode and sing-box are
# available, otherwise the checkout is copied to $HP_TEST_HOST and run there.
#
# The default is the dedicated test machine, NOT the production router: the
# fallback untars the whole checkout into $HP_TEST_DIR on the target, which
# must never land on the box the house actually routes through.
#
#   HP_TEST_HOST=root@192.168.1.102 tests/run.sh
#   HP_TEST_DIR=/tmp/hp-tests          tests/run.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# One work root per invocation. The sub-suites default to fixed paths like
# /tmp/hp-ucode-tests, so two concurrent runs of this script (a local one and a
# CI one over ssh, say) deleted each other's staging mid-test. mktemp -d gives
# each run its own, and the trap removes it.
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hp-run.XXXXXX")" || exit 1
HOST="${HP_TEST_HOST:-root@192.168.1.102}"

# The remote staging dir is per-run too, derived from the work root. With a
# shared /tmp/hp-tests two concurrent runs deleted each other's checkout
# mid-suite: "could not stage the tests" was the reproducible symptom.
# HP_TEST_DIR still overrides it.
REMOTE_DIR="${HP_TEST_DIR:-/tmp/hp-tests-$(basename "$WORK_ROOT")}"

# Both roots are removed on every exit path. The remote one needs ssh, so if the
# host is unreachable this is a no-op rather than an error.
cleanup() {
	rm -rf "$WORK_ROOT"
	case "${STAGED_REMOTELY:-0}" in
	1) ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "rm -rf '$REMOTE_DIR'" 2>/dev/null || true ;;
	esac
}
trap cleanup EXIT INT TERM
FAILED=0

echo "== zh_Hans translation coverage =="
if ! python3 "$ROOT/tests/i18n-coverage.py" --fail-below 100; then
	echo "FAIL: zh_Hans translation coverage is below 100%"
	FAILED=1
fi

echo "== LuCI form snapshots =="
for target in node client server; do
	if ! node "$ROOT/tests/luci-form-snapshot.js" "$ROOT" "$target" > "/tmp/hp-snapshot-$target.json" 2> "/tmp/hp-snapshot-$target.err"; then
		echo "FAIL: could not render the $target form"
		cat "/tmp/hp-snapshot-$target.err"
		FAILED=1
		continue
	fi

	if diff -q "$ROOT/tests/snapshots/$target.json" "/tmp/hp-snapshot-$target.json" > "/dev/null"; then
		echo "PASS: $target form snapshot"
	else
		echo "FAIL: $target form snapshot changed:"
		diff "$ROOT/tests/snapshots/$target.json" "/tmp/hp-snapshot-$target.json" | head -40
		FAILED=1
	fi
done

echo "== frontend protocol inventory =="
# Node-only, no ucode/sing-box needed: the frontend's protocol table must agree
# with the backend tables that decide what the generators can build.
node "$ROOT/tests/frontend-protocol-inventory.js" "$ROOT" || FAILED=1

echo "== frontend rpc boundary =="
# One declaration site, and no call site that looks like error handling but is
# not. Source-level because the behaviour needs a browser.
node "$ROOT/tests/frontend-rpc-inventory.js" "$ROOT" || FAILED=1

echo "== frontend validators =="
# A `validate` callback is a function, so no snapshot records it; this drives it
# with a fake form context instead.
node "$ROOT/tests/frontend-validators.js" "$ROOT" || FAILED=1

echo "== package JSON and UCI assets =="
# A malformed acl.d makes rpcd refuse the whole ACL, so every RPC is denied;
# a menu.d action pointing at a renamed view drops the page from the menu.
# Nothing else looks at these files.
node "$ROOT/tests/json-assets.js" "$ROOT" || FAILED=1

echo "== frontend RPC fallbacks =="
# What the UI claims when an RPC does not answer: the protocol list must not
# shrink (a saved node's type would be silently rewritten on the next save),
# and the status bar must not report a failed query as NOT RUNNING.
node "$ROOT/tests/frontend-rpc-fallbacks.js" "$ROOT" || FAILED=1

echo "== frontend title escaping =="
# Two sinks, two different escapes: a tab title decodes once, a section modal
# title goes through form.stripTags() which *decodes entities*, so escaping
# alone would hand it live markup. This models both decodes.
node "$ROOT/tests/frontend-title-escaping.js" "$ROOT" || FAILED=1

echo "== runtime extraction equivalence (PR-05) =="
# Pure shell: no ucode/sing-box needed, so it runs before the local-or-SSH
# branch below. A host without the toolchain can still prove that the init
# script refactor did not change behaviour.
sh "$ROOT/tests/runtime/test_runtime_extraction.sh" "$ROOT" "$WORK_ROOT/runtime-extraction" || FAILED=1

echo "== architecture guard =="
# Cross-file invariants that no single-layer test can see: the generators must
# read the production UCI directory, and the subscription updater must read the
# fields where the Loader actually puts them.  Both regressed silently once.
# Pure shell, no ucode/node, so it also runs before the toolchain branch.
sh "$ROOT/tests/arch-guard.sh" "$ROOT" || FAILED=1

echo "== ucode tests =="
if command -v ucode > "/dev/null" 2>&1 && command -v sing-box > "/dev/null" 2>&1; then
	# The generator cases feed the emitted config to `sing-box check` and the
	# package targets sing-box >= 1.14; an older binary rejects 1.14-only
	# fields. Fail loudly here instead of letting each fixture look like a
	# generator regression.
	SB_VER="$(sing-box version 2>/dev/null | sed -n 's/^sing-box version \([0-9][0-9.]*\).*/\1/p' | head -1)"
	case "$SB_VER" in
	1.1[4-9]*|1.[2-9][0-9]*|[2-9].*) ;;
	*)	echo "FAIL: sing-box >= 1.14 required, found '${SB_VER:-unknown}' ($(command -v sing-box))"
		echo "      tests/toolchain/build-ucode-macos.sh installs a matching one"
		FAILED=1
		;;
	esac
	sh "$ROOT/tests/ucode/run.sh" "$ROOT" "$WORK_ROOT/ucode" || FAILED=1
else
	echo "(no local ucode/sing-box, executing on $HOST)"
	# BatchMode: a host-key or password prompt would otherwise hang the suite
	# forever with no output. ConnectTimeout bounds an unreachable host.
	#
	# $REMOTE_DIR is expanded here and quoted inside the remote command: it was
	# interpolated bare into `rm -rf`, so a value with a space would have
	# removed two paths instead of one.
	SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
	if tar czf - -C "$ROOT" --exclude .git --exclude node_modules . \
		| $SSH "$HOST" "rm -rf '$REMOTE_DIR' && mkdir -p '$REMOTE_DIR' && tar xzf - -C '$REMOTE_DIR'"; then
		STAGED_REMOTELY=1
		# HP_REQUIRE_FW4: a target always has firewall4, so the fw4 render
		# layer in test_firewall_template.sh must actually run there. Without
		# this, a target missing it would report NOT RUN and the suite would
		# still pass, which is how a device-only layer quietly stops being
		# exercised at all.
		# The second argument is the work dir. Without it the remote run fell
		# back to ucode/run.sh's default /tmp/hp-ucode-tests, so two concurrent
		# suite runs on the target shared it and deleted each other's staging -
		# "could not sandbox ... missing anchor".
		$SSH "$HOST" "HP_REQUIRE_FW4=1 sh '$REMOTE_DIR/tests/ucode/run.sh' '$REMOTE_DIR' '$REMOTE_DIR/work'" || FAILED=1
	else
		echo "FAIL: could not stage the tests on $HOST"
		FAILED=1
	fi
fi

if [ "$FAILED" -eq 0 ]; then
	echo "ALL TESTS PASSED"
else
	echo "SOME TESTS FAILED"
fi

exit $FAILED
