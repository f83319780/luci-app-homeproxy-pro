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
	mkdir -p "$dir/config" "$dir/run" "$dir/scripts" "$dir/resources" "$dir/ruleset"
	: > "$dir/resources/direct_list.txt"
	: > "$dir/resources/proxy_list.txt"

	if grep -q "__RULESET_DIR__" "$fixture"; then
		# The fixture needs a real local rule-set on disk.
		printf '%s' '{"version":1,"rules":[{"domain_suffix":["example.com"]}]}' > "$dir/ruleset/src.json"
		if ! sing-box rule-set compile "$dir/ruleset/src.json" -o "$dir/ruleset/test.srs"; then
			echo "FAIL: $name: could not compile the local rule-set fixture"
			FAILED=1
			return
		fi
		sed "s#__RULESET_DIR__#$dir/ruleset#" "$fixture" > "$dir/config/homeproxy"
	else
		cp "$fixture" "$dir/config/homeproxy"
	fi

	# HP_VALIDATE_DATA lets a development host replace /sbin/validate_data
	# (see tests/README.md); on a target the production path is kept.
	VALIDATE_DATA="${HP_VALIDATE_DATA:-/sbin/validate_data}"
	sed -e "s#^export const HP_DIR = '/etc/homeproxy';#export const HP_DIR = '$dir';#" \
	    -e "s#^export const RUN_DIR = '/var/run/homeproxy';#export const RUN_DIR = '$dir/run';#" \
	    -e "s#/sbin/validate_data#${VALIDATE_DATA}#" \
	    "$ROOT/root/etc/homeproxy/scripts/homeproxy.uc" > "$dir/scripts/homeproxy.uc"

	# Stage the config/ subtree (Loader / Model / Adapter, imported via
	# the relative path "./config/*.uc" in generate_client.uc).
	mkdir -p "$dir/scripts/config"
	cp "$ROOT/root/etc/homeproxy/scripts/config/loader.uc"  "$dir/scripts/config/"
	cp "$ROOT/root/etc/homeproxy/scripts/config/model.uc"   "$dir/scripts/config/"
	cp "$ROOT/root/etc/homeproxy/scripts/config/adapter.uc" "$dir/scripts/config/"

	# Substitute the testbed placeholder. The production generator has
	# `Loader.load('__LOADER_DIR__')` - on a real device the string
	# stays as `'__LOADER_DIR__'`, which Loader.load() interprets as
	# the relative /etc/config path - but we want it to point at the
	# staging dir on the dev host. The substitution is a normal sed.
	sed_expr="s#'__LOADER_DIR__'#'$dir/config'#g"
	if [ "$(uname -s)" = "Darwin" ]; then
		sed_expr="$sed_expr;s#routing_mark: strToInt(self_mark)#routing_mark: null#"
	fi

	sed -e "$sed_expr" \
	    "$ROOT/root/etc/homeproxy/scripts/$generator" > "$dir/scripts/$generator"

	if ! ( cd "$dir/scripts" && ucode -L "$dir/scripts" "$generator" ); then
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

exit $FAILED
