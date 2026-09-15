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
HOST="${HP_TEST_HOST:-root@192.168.1.102}"
REMOTE_DIR="${HP_TEST_DIR:-/tmp/hp-tests}"
FAILED=0

echo "== zh_Hans translation coverage =="
python3 "$ROOT/tests/i18n-coverage.py" --warn-below 100

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

echo "== runtime extraction equivalence (PR-05) =="
# Pure shell: no ucode/sing-box needed, so it runs before the local-or-SSH
# branch below. A host without the toolchain can still prove that the init
# script refactor did not change behaviour.
sh "$ROOT/tests/runtime/test_runtime_extraction.sh" "$ROOT" || FAILED=1

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
	sh "$ROOT/tests/ucode/run.sh" "$ROOT" || FAILED=1
else
	echo "(no local ucode/sing-box, executing on $HOST)"
	if tar czf - -C "$ROOT" --exclude .git --exclude node_modules . \
		| ssh "$HOST" "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR && tar xzf - -C $REMOTE_DIR"; then
		ssh "$HOST" "sh $REMOTE_DIR/tests/ucode/run.sh $REMOTE_DIR" || FAILED=1
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
