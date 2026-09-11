#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Run the ucode-level tests: the parse_uri unit tests and the generator
# regression fixtures. Requires ucode; sing-box is needed for the generator
# cases (they validate the emitted config with `sing-box check`).
#
# Usage: sh tests/ucode/run.sh <repo-root> [work-dir]

ROOT="${1:-.}"
WORK="${2:-/tmp/hp-ucode-tests}"

ROOT="$(cd "$ROOT" && pwd)"
FAILED=0

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

echo "== generator regression tests =="
sh "$ROOT/tests/ucode/test_generators.sh" "$ROOT" "$WORK/generators" || FAILED=1

exit $FAILED
