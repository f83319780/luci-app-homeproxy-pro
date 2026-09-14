#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# B1.2: integration test for subscription/repository.uc. Unlike
# the filter/decoder unit tests, this one writes to a real UCI
# cursor, so the runner stages a sandboxed config dir with a
# pre-existing homeproxy file and points the cursor at it.
#
# Staging layout:
#   $WORK/sandbox/homeproxy           UCI file with seed sections
#   $WORK/sandbox/                    cursor root
#   $WORK/scripts/                    test + homeproxy mock + module
#
# cursor(dir) reads from <dir>/<name> directly (NOT <dir>/config/
# <name>), so the seed file lives at the top of the sandbox dir.
#
# Run from tests/ucode/run.sh, which exports UCODE_MODULES_DIR so
# `import { cursor } from 'uci'` and `import { md5 } from 'digest'`
# resolve against the local testbed modules.
#
# Usage: sh tests/ucode/test_subscription_repository.sh <repo-root> [work-dir]

ROOT="${1:-.}"
WORK="${2:-/tmp/hp-subscription-repo-test}"

ROOT="$(cd "$ROOT" && pwd)"
FAILED=0

SANDBOX="$WORK/sandbox"
STAGE="$WORK/scripts"

rm -rf "$WORK"
mkdir -p "$SANDBOX" "$STAGE"

# Seed the UCI file. The cursor reads <sandbox>/homeproxy (NOT
# <sandbox>/config/homeproxy); see the comment above.
uci_seed() {
	printf 'config homeproxy %s\n' "$1" >> "$SANDBOX/homeproxy"
	shift
	for kv in "$@"; do
		key="${kv%%=*}"
		val="${kv#*=}"
		printf '\toption %s %s\n' "$key" "$val" >> "$SANDBOX/homeproxy"
	done
}

uci_seed cfgUSER0001 label=user-only type=vless address=user.example.com
uci_seed cfgKEEP00001 label=kept-node grouphash=test-group type=vless \
	address=old.example.com stale_field=remove-me
uci_seed cfgDROP00001 label=dropped-node grouphash=test-group type=vless \
	address=gone.example.com

# Stage the mock + the module + the test alongside each other so
# bare-name imports (`from 'homeproxy'`, `from 'repository'`) resolve
# via the work-dir -L path.
cp "$ROOT/tests/ucode/mocks/homeproxy.uc" "$STAGE/"
cp "$ROOT/root/etc/homeproxy/scripts/subscription/repository.uc" "$STAGE/"
cp "$ROOT/tests/ucode/test_subscription_repository.uc" "$STAGE/"

if ( cd "$STAGE" && ucode -L "$STAGE" test_subscription_repository.uc "$SANDBOX" ); then
	echo "PASS: subscription repository integration test"
else
	echo "FAIL: subscription repository integration test"
	FAILED=1
fi

exit $FAILED
