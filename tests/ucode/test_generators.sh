#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Run generate_client.uc / generate_server.uc against the UCI fixtures and let
# sing-box validate the result. The generators read /etc/config and write
# /var/run, so this script materialises an isolated copy of them: homeproxy.uc
# is rewritten to point HP_DIR/RUN_DIR at a scratch directory, and the uci
# cursor is pointed at the fixture config.
#
# Usage: sh tests/ucode/test_generators.sh <repo-root> [work-dir]

ROOT="${1:-.}"
WORK="${2:-/tmp/hp-generator-test}"

ROOT="$(cd "$ROOT" && pwd)"
FAILED=0

run_case() {
	name="$1"
	fixture="$2"
	generator="$3"
	outfile="$4"
	dir="$WORK/$name"

	rm -rf "$dir"
	mkdir -p "$dir/config" "$dir/run" "$dir/scripts" "$dir/resources"
	cp "$fixture" "$dir/config/homeproxy"
	: > "$dir/resources/direct_list.txt"
	: > "$dir/resources/proxy_list.txt"

	sed -e "s#^export const HP_DIR = '/etc/homeproxy';#export const HP_DIR = '$dir';#" \
	    -e "s#^export const RUN_DIR = '/var/run/homeproxy';#export const RUN_DIR = '$dir/run';#" \
	    "$ROOT/root/etc/homeproxy/scripts/homeproxy.uc" > "$dir/scripts/homeproxy.uc"

	sed -e "s#const uci = cursor();#const uci = cursor('$dir/config');#" \
	    "$ROOT/root/etc/homeproxy/scripts/$generator" > "$dir/scripts/$generator"

	if ! ( cd "$dir/scripts" && ucode "$generator" ); then
		echo "FAIL: $name: $generator exited non-zero"
		FAILED=1
		return
	fi

	if [ ! -f "$dir/run/$outfile" ]; then
		echo "FAIL: $name: $outfile was not generated"
		FAILED=1
		return
	fi

	if ! sing-box check --config "$dir/run/$outfile"; then
		echo "FAIL: $name: sing-box rejected the generated $outfile"
		FAILED=1
		return
	fi

	echo "PASS: $name ($(wc -c < "$dir/run/$outfile") bytes)"
}

run_case client "$ROOT/tests/fixtures/generators/client.uci" generate_client.uc sing-box-c.json
run_case server "$ROOT/tests/fixtures/generators/server.uci" generate_server.uc sing-box-s.json

exit $FAILED
