#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Run generate_client.uc / generate_server.uc against the UCI fixtures and let
# sing-box validate the result. The generators read /etc/config and write
# /var/run, so this script materialises an isolated copy of them: homeproxy.uc
# is rewritten to point HP_DIR/RUN_DIR at a scratch directory, and the uci
# cursor is pointed at the fixture config.
#
# Stage PHASE 4: the generators are now split into generator/*.uc modules
# and the production entry points (scripts/generate_client.uc and
# scripts/generate_server.uc) are 10-line CLI shells that just load the UCI,
# call the module's generate(), and run the atomic write + sing-box check.
# The testbed no longer needs to sed-substitute a `__LOADER_DIR__` token
# because that mechanism is gone - the staged scripts/ subtree is a regular
# directory and `Loader.load()` takes the path as an argument.
#
# Usage: sh tests/ucode/test_generators.sh <repo-root> [work-dir]

ROOT="${1:-.}"
WORK="${2:-/tmp/hp-generator-test}"

ROOT="$(cd "$ROOT" && pwd)"
FAILED=0

# The local rule-set fixture has to live under /tmp/homeproxy_ (see below), so
# it cannot sit inside $WORK; this is the per-run root that holds it instead.
# Created lazily by the first case that needs one.
RULESET_ROOT=""
cleanup() {
	[ -n "$RULESET_ROOT" ] && rm -rf "$RULESET_ROOT"
}
trap cleanup EXIT INT TERM

run_case() {
	name="$1"
	fixture="$2"
	generator="$3"
	outfile="$4"
	dir="$WORK/$name"

	rm -rf "$dir"
	mkdir -p "$dir/config" "$dir/run" "$dir/scripts" "$dir/scripts/config" "$dir/scripts/generator" "$dir/resources" "$dir/ruleset"
	: > "$dir/resources/direct_list.txt"
	: > "$dir/resources/proxy_list.txt"

	if grep -q "__RULESET_DIR__" "$fixture"; then
		# The fixture needs a real local rule-set on disk. The path must
		# live under /tmp/homeproxy_* (validateHomeProxyPath() in
		# homeproxy.uc whitelists /etc/homeproxy/ and /tmp/homeproxy_
		# only, and the custom fixture exercises the local-rule-set
		# path whitelist gate introduced by the security patch).
		printf '%s' '{"version":1,"rules":[{"domain_suffix":["example.com"]}]}' > "$dir/ruleset/src.json"
		if ! sing-box rule-set compile "$dir/ruleset/src.json" -o "$dir/ruleset/test.srs"; then
			echo "FAIL: $name: could not compile the local rule-set fixture"
			FAILED=1
			return
		fi
		# Stage the ruleset under a /tmp/homeproxy_* directory so the
		# whitelist recognises the staging path. Production paths
		# typically live at /etc/homeproxy/ruleset/...
		#
		# The path cannot move under $WORK (validateHomeProxyPath() in
		# homeproxy.uc whitelists /etc/homeproxy/ and /tmp/homeproxy_
		# only), but it can still be per-run: mktemp gives each run its
		# own tree, and the trap removes it even when a case bails out
		# early.  The old fixed /tmp/homeproxy_test_ruleset/$name leaked
		# one directory per run and let two concurrent runs overwrite
		# each other's compiled .srs.
		if [ -z "$RULESET_ROOT" ]; then
			RULESET_ROOT="$(mktemp -d /tmp/homeproxy_test_ruleset.XXXXXX)"
		fi
		HP_RULESET="$RULESET_ROOT/$name"
		mkdir -p "$HP_RULESET"
		cp "$dir/ruleset/test.srs" "$HP_RULESET/test.srs"
		sed "s#__RULESET_DIR__#$HP_RULESET#" "$fixture" > "$dir/config/homeproxy"
	else
		cp "$fixture" "$dir/config/homeproxy"
	fi


	# HP_VALIDATE_DATA lets a development host replace /sbin/validate_data
	# (see tests/README.md); on a target the production path is kept.
	#
	# UCICONFIG_DIR is the UCI confdir the Loader hands to cursor().  On a
	# target it is /etc/config; here it has to point at the fixture staged
	# below as $dir/config/homeproxy.  Rewriting the constant is what keeps
	# the staging seam out of the source files - staging it as
	# HP_DIR + '/config' instead would silently diverge from production,
	# which is exactly the bug this constant replaced.
	VALIDATE_DATA="${HP_VALIDATE_DATA:-/sbin/validate_data}"
	sed -e "s#^export const HP_DIR = '/etc/homeproxy';#export const HP_DIR = '$dir';#" \
	    -e "s#^export const RUN_DIR = '/var/run/homeproxy';#export const RUN_DIR = '$dir/run';#" \
	    -e "s#^export const UCICONFIG_DIR = '/etc/config';#export const UCICONFIG_DIR = '$dir/config';#" \
	    -e "s#/sbin/validate_data#${VALIDATE_DATA}#" \
	    "$ROOT/root/etc/homeproxy/scripts/homeproxy.uc" > "$dir/scripts/homeproxy.uc"

	# Stage the config/ subtree (Loader / Model / Adapter, imported via
	# the relative path "../config/*.uc" by the generator modules).
	cp "$ROOT/root/etc/homeproxy/scripts/config/loader.uc"  "$dir/scripts/config/"
	cp "$ROOT/root/etc/homeproxy/scripts/config/model.uc"   "$dir/scripts/config/"
	cp "$ROOT/root/etc/homeproxy/scripts/config/adapter.uc" "$dir/scripts/config/"
	# PR-02: config/loader.uc imports '../parser/mapping.uc', so the
	# parser tree has to be staged as a sibling of config/ or the
	# generator cannot even load the configuration.
	mkdir -p "$dir/scripts/parser"
	cp "$ROOT/root/etc/homeproxy/scripts/parser/"*.uc "$dir/scripts/parser/"

	# Stage the generator/ subtree that PHASE 4 introduced. The CLI
	# shells (scripts/generate_*.uc) import from generator/; the
	# modules in turn import from common.uc, dns.uc, ... inside the
	# same directory.
	cp "$ROOT/root/etc/homeproxy/scripts/generator/"*.uc "$dir/scripts/generator/"

	# Stage the CLI shells themselves. This is the entry point the
	# production init.d runs (`ucode -S generate_client.uc`); the
	# test exercises the same code path end-to-end, not a parallel
	# test-only driver.
	cp "$ROOT/root/etc/homeproxy/scripts/$generator" "$dir/scripts/$generator"

	# No platform patching here on purpose.  The suite used to rewrite
	# generator/client.uc's `routing_mark` to null on Darwin, because the
	# macOS sing-box rejects that Linux-only field - which meant the one
	# field the product needs on its target platform was silently deleted
	# before every test, and a regression in it could never be seen.  The
	# off-target layer is Linux-only now (see tests/README.md); a host that
	# cannot validate the generated configuration says so instead of
	# weakening it.

	# stderr is kept so a test can assert on warnings (e.g. a pruned urltest
	# candidate) as well as on the generated JSON.
	if ! ( cd "$dir/scripts" && ucode -L "$dir/scripts" "$generator" 2> "$dir/generate.err" ); then
		echo "FAIL: $name: $generator exited non-zero"
		head -5 "$dir/generate.err"
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

# The fixture's infra.self_mark, i.e. the value every node outbound has to
# carry as routing_mark in the redirect modes.
fixture_self_mark() {
	sed -n "s/^[[:space:]]*option self_mark '\([0-9]*\)'.*/\1/p" "$1" | head -1
}

# Read one field out of a generated configuration.  ucode is already required
# by this suite, and a JSON walk is stronger than a grep: it cannot be
# satisfied by a coincidental match elsewhere in the file.
run_case client "$ROOT/tests/fixtures/generators/client.uci" generate_client.uc sing-box-c.json

# The preset remote rule-sets must be fetched through the node. A direct
# download depends on the CDN staying reachable from mainland China and fails
# intermittently under DNS pollution, which shows up as "open connection to
# <ip>:443 using outbound/direct[direct]: i/o timeout" in sing-box-c.log.
if grep -q '"detour": "direct-out"' "$WORK/client/run/sing-box-c.json"; then
	echo "FAIL: client: a remote rule-set would still be downloaded directly"
	FAILED=1
fi
if ! grep -q '"detour": "main-out"' "$WORK/client/run/sing-box-c.json"; then
	echo "FAIL: client: no remote rule-set is configured to download through main-out"
	FAILED=1
fi

# --- the product default proxy mode --------------------------------------
#
# client.uci runs `proxy_mode 'tun'`, where self_mark is empty and no outbound
# carries routing_mark.  That made it the only end-to-end fixture for as long
# as the default mode (redirect_tproxy) was never generated here - and the
# adapter's COMMON_FIELDS neutralized routing_mark (it listed the key as null
# *after* the literal that sets it), so every node outbound lost the mark that
# keeps sing-box's own proxy connection out of the nft redirect chain.  This
# case covers the default mode and asserts the mark on the emitted bytes.
run_case redirect "$ROOT/tests/fixtures/generators/redirect.uci" generate_client.uc sing-box-c.json

redir_fixture="$ROOT/tests/fixtures/generators/redirect.uci"
redir_json="$WORK/redirect/run/sing-box-c.json"
redir_mark="$(fixture_self_mark "$redir_fixture")"

if [ -z "$redir_mark" ]; then
	echo "FAIL: redirect: $redir_fixture no longer declares infra.self_mark, so the"
	echo "      routing_mark assertion would pass vacuously"
	FAILED=1
elif [ ! -f "$redir_json" ]; then
	echo "FAIL: redirect: no config was generated"
	FAILED=1
else
	for tag in redirect-in tproxy-in; do
		if ! grep -q "\"tag\": \"$tag\"" "$redir_json"; then
			echo "FAIL: redirect: proxy_mode=redirect_tproxy did not emit $tag"
			FAILED=1
		fi
	done

	# Which outbounds must carry the mark: every outbound that dials.  Group
	# outbounds (urltest/selector) must NOT - sing-box rejects the field on
	# them with `json: unknown field "routing_mark"` - and block-out never
	# dials.  A structural walk is used instead of a grep count so the
	# group/leaf distinction cannot silently rot into a vacuous assertion.
	cat > "$WORK/markcheck.uc" <<'EOF'
'use strict';

import { readfile } from 'fs';

const want = +ARGV[0];
const config = json(readfile(ARGV[1]));
let checked = 0, problems = 0;

for (let ob in (config.outbounds || [])) {
	if (index(['block', 'urltest', 'selector'], ob.type) !== -1)
		continue;

	checked++;

	if (ob.routing_mark !== want)
		problems++;
}

printf('%d %d\n', checked, problems);
EOF

	mark_result="$(ucode "$WORK/markcheck.uc" "$redir_mark" "$redir_json" 2>"/dev/null")"
	mark_checked="${mark_result%% *}"
	mark_problems="${mark_result##* }"

	case "$mark_checked" in
	''|*[!0-9]*)
		echo "FAIL: redirect: could not check the emitted outbounds ($redir_json)"
		FAILED=1
		;;
	0)
		echo "FAIL: redirect: no dialling outbound was emitted, the assertion is vacuous"
		FAILED=1
		;;
	*)
		if [ "$mark_problems" -ne 0 ]; then
			echo "FAIL: redirect: $mark_problems of $mark_checked dialling outbounds do not"
			echo "      carry routing_mark=$redir_mark (see COMMON_FIELDS in config/adapter.uc);"
			echo "      without it sing-box does not mark its own sockets and the nft OUTPUT"
			echo "      redirect chain loops the proxy connection back into its own inbound"
			FAILED=1
		else
			echo "PASS: redirect: all $mark_checked dialling outbounds carry routing_mark=$redir_mark"
		fi
		;;
	esac
fi

# --- A1: the generator is a pure function of its arguments ----------------
#
# generator/client.uc used to resolve its own runtime environment - ubus for
# the WAN resolver, readfile() for the two domain-resource lists - while being
# documented as a pure function. "Generate the same config twice" was therefore
# not guaranteed, and reload's preflight generation was not provably the
# artifact start_service regenerated. The impure step now lives in the CLI
# shell, which hands the values to generate(dm, env).
#
# Both halves of that contract are pinned here, through the production entry
# point (not a test-only driver): the same inputs must produce byte-identical
# output, and a changed GenerationContext input must reach the generator. The
# comparison is exact string equality rather than a hash, because busybox has
# no cksum and macOS has no md5sum by default.
det_dir="$WORK/client"
det_gen="generate_client.uc"
det_out="$det_dir/run/sing-box-c.json"
det_first="$det_dir/determinism-first.json"

cp "$det_out" "$det_first"
( cd "$det_dir/scripts" && ucode -L "$det_dir/scripts" "$det_gen" ) >"/dev/null" 2>&1
if [ "$(cat "$det_out")" = "$(cat "$det_first")" ]; then
	echo "PASS: the same generation inputs produce byte-identical output"
else
	echo "FAIL: two identical generation runs produced different output"
	FAILED=1
fi

# direct_list.txt is read by the CLI and passed in as env.direct_domain_list.
# If that plumbing were lost - the exact shape of the old hidden read - the file
# would be ignored and the output would not move.
printf 'determinism.example.com\n' > "$det_dir/resources/direct_list.txt"
( cd "$det_dir/scripts" && ucode -L "$det_dir/scripts" "$det_gen" ) >"/dev/null" 2>&1
if [ "$(cat "$det_out")" != "$(cat "$det_first")" ]; then
	echo "PASS: a changed GenerationContext input changes the generated output"
else
	echo "FAIL: the domain-resource list did not reach the generator"
	FAILED=1
fi
if ! grep -qF 'determinism.example.com' "$det_out"; then
	echo "FAIL: the domain from direct_list.txt is absent from the generated config"
	FAILED=1
fi

run_case custom "$ROOT/tests/fixtures/generators/custom.uci" generate_client.uc sing-box-c.json

run_case server "$ROOT/tests/fixtures/generators/server.uci" generate_server.uc sing-box-s.json

# WireGuard is emitted as a sing-box endpoint, not an outbound, and it has its
# own builder.  A3 converted the call sites to pass a Node but left
# generate_endpoint() reading flat UCI keys, so the key material silently
# disappeared and sing-box rejected the config.  `sing-box check` alone is not
# a strong enough guard (a config with no server at all can still be valid),
# so assert the endpoint actually carries the fixture's keys.
run_case wireguard "$ROOT/tests/fixtures/generators/wireguard.uci" generate_client.uc sing-box-c.json

wg_json="$WORK/wireguard/run/sing-box-c.json"
if [ ! -f "$wg_json" ]; then
	echo "FAIL: wireguard: no config was generated"
	FAILED=1
else
	if ! grep -qF '"type": "wireguard"' "$wg_json"; then
		echo "FAIL: wireguard: no wireguard endpoint in the generated config"
		FAILED=1
	fi
	if ! grep -qF 'iKaNuoWRQTFPD5V3OoMNdMshsMgU9t7rolJNpgNx+UM=' "$wg_json"; then
		echo "FAIL: wireguard: the endpoint lost its private key"
		FAILED=1
	fi
	if ! grep -qF 'DDcdTHUv0Q6XYDf9l93jzwwuoY/G1TC+g74QH0A9HmM=' "$wg_json"; then
		echo "FAIL: wireguard: the peer lost its public key"
		FAILED=1
	fi
	if ! grep -qF '"172.16.0.2/32"' "$wg_json"; then
		echo "FAIL: wireguard: the endpoint lost its local address list"
		FAILED=1
	fi
fi

# A broken urltest candidate must be pruned, not fatal: the old behaviour was
# a die() that left the router with no configuration at all.
run_case partial_invalid "$ROOT/tests/fixtures/generators/partial_invalid.uci" generate_client.uc sing-box-c.json

pi_json="$WORK/partial_invalid/run/sing-box-c.json"
if [ ! -f "$pi_json" ]; then
	echo "FAIL: partial_invalid: a single broken urltest node aborted the whole config"
	FAILED=1
else
	if ! grep -qF '"cfg-n_ok-out"' "$pi_json"; then
		echo "FAIL: partial_invalid: the buildable candidate was dropped too"
		FAILED=1
	fi
	if grep -qF '"cfg-n_broken-out"' "$pi_json"; then
		echo "FAIL: partial_invalid: the broken candidate was emitted"
		FAILED=1
	fi
	if ! grep -q "skipping urltest candidate 'n_broken'" "$WORK/partial_invalid/generate.err"; then
		echo "FAIL: partial_invalid: the broken candidate was dropped without a warning"
		FAILED=1
	fi
fi

# A direct node as the main node leaves main-out with no fields of its own, and
# sing-box refuses to detour into an empty direct outbound - both the main-dns
# server and the rule-set http_client used to, so the service never started.
# `sing-box check` accepts the file (only `sing-box run` rejects it), so assert
# on the generated JSON rather than trusting check.
run_case direct_main "$ROOT/tests/fixtures/generators/direct_main.uci" generate_client.uc sing-box-c.json

dm_json="$WORK/direct_main/run/sing-box-c.json"
if [ ! -f "$dm_json" ]; then
	echo "FAIL: direct_main: no config was generated"
	FAILED=1
else
	if ! grep -q '"tag": "main-out"' "$dm_json"; then
		echo "FAIL: direct_main: main-out is missing from the generated config"
		FAILED=1
	fi
	if grep -q '"detour": "main-out"' "$dm_json"; then
		echo "FAIL: direct_main: something still detours into the empty direct main-out:"
		grep -n '"detour": "main-out"' "$dm_json" | head -3
		echo "      sing-box run rejects it with 'detour to an empty direct outbound makes no sense'"
		FAILED=1
	fi
fi

exit $FAILED