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

	# Stage A1.1: generate_client.uc imports ./config/loader.uc + ./config/model.uc
	# when HP_TEST_DOMAIN_MODEL=1. Mirror that layout in the staging dir.
	mkdir -p "$dir/scripts/config"
	cp "$ROOT/root/etc/homeproxy/scripts/config/loader.uc"  "$dir/scripts/config/"
	cp "$ROOT/root/etc/homeproxy/scripts/config/model.uc"   "$dir/scripts/config/"
	cp "$ROOT/root/etc/homeproxy/scripts/config/adapter.uc" "$dir/scripts/config/"

	# routing_mark is a Linux-only SO_MARK socket option in sing-box, so the
	# redirect/tproxy modes cannot pass `sing-box check` on a development host
	# (there is no portable equivalent: sing-box 1.14 has no set_mark route
	# option). Neutralise the two emission sites in the *staged copy* only:
	# null fields are dropped by removeBlankAttrs, so the generated JSON is the
	# same on every platform. The production generator is not modified, and the
	# custom-routing assertions do not depend on the mark.
	sed_expr="s#const uci = cursor();#const uci = cursor('$dir/config');#"
	sed_expr="$sed_expr;s#Loader.load()#Loader.load('$dir/config')#g"
	sed_expr="$sed_expr;s#__HP_TEST_DOMAIN_MODEL__#${HP_TEST_DOMAIN_MODEL:-0}#"
	if [ "$(uname -s)" = "Darwin" ]; then
		sed_expr="$sed_expr;s#routing_mark: strToInt(self_mark)#routing_mark: null#"
	fi

	sed -e "$sed_expr" \
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

# Stage A2 dual-run equivalence check: the same fixture must produce
# byte-identical sing-box-c.json regardless of the HP_TEST_DOMAIN_MODEL
# flag. The flag flips generate_client.uc's UCI read path between
# uci.get() (off, the production behaviour) and Loader.load() (on, the
# HomeProxyConfig-backed path). Once every UCI read is behind a
# dm_get() helper and the uci.get() fallback is removed, this block
# becomes a no-op (set HP_SKIP_DUAL_RUN=1 to silence it locally).
if [ "${HP_SKIP_DUAL_RUN:-0}" = "1" ]; then
	exit $FAILED
fi

dual_run() {
	# $1 = name, $2 = fixture, $3 = outfile, $4 = generator basename
	local name="$1" fixture="$2" outfile="$3" generator="${4:-generate_client.uc}"
	local base_dir="$WORK/$name"
	local on_dir="$base_dir-on"

	# Reuse the staging run_case() already built: that is the flag=0
	# reference. Copy it aside, then flip the staged generator's
	# __HP_TEST_DOMAIN_MODEL__ (or whatever it was substituted to by
	# staging) to 1 and rerun.
	#
	# The base homeproxy.uc has HP_DIR/RUN_DIR rewritten to $base_dir,
	# so the on_dir copy needs the same rewrite done again (to $on_dir)
	# - otherwise the generator writes to $base_dir/run and the diff
	# collapses to nothing.
	rm -rf "$on_dir"
	cp -R "$base_dir" "$on_dir"
	sed -i.bak -e "s#^export const HP_DIR = '.*';#export const HP_DIR = '$on_dir';#" \
	          -e "s#^export const RUN_DIR = '.*';#export const RUN_DIR = '$on_dir/run';#" \
	          "$on_dir/scripts/homeproxy.uc"
	rm -f "$on_dir/scripts/homeproxy.uc.bak"

	if sed -i.bak 's#__HP_TEST_DOMAIN_MODEL__#1#;s#const USE_DOMAIN_MODEL = (0 === 1);#const USE_DOMAIN_MODEL = (1 === 1);#' "$on_dir/scripts/$generator"; then
		rm -f "$on_dir/scripts/$generator.bak"
	else
		echo "FAIL: $name dual-run: sed could not flip the flag"
		FAILED=1
		return
	fi
	if ! ( cd "$on_dir/scripts" && ucode "$generator" ); then
		echo "FAIL: $name dual-run: flag=1 generator exited non-zero"
		FAILED=1
		return
	fi

	if cmp -s "$base_dir/run/$outfile" "$on_dir/run/$outfile"; then
		echo "PASS: $name dual-run byte-identical ($(wc -c < "$base_dir/run/$outfile") bytes)"
	else
		# Some generator-emitted paths are built from HP_DIR / RUN_DIR
		# which the dual-run sed already rewrote to $on_dir; map those
		# back to $base_dir so we compare semantics, not testbench paths.
		# Everything else must still be byte-identical.
		if sed -i.bak -e "s#\"output\": \"$on_dir/run#\"output\": \"$base_dir/run#" \
		            -e "s#\"data_directory\": \"$on_dir#\"data_directory\": \"$base_dir#" \
		            -e "s#\"path\": \"$on_dir/resources/#\"path\": \"$base_dir/resources/#" \
		            -e "s#\"path\": \"$on_dir/cache.db#\"path\": \"$base_dir/cache.db#" \
		            "$on_dir/run/$outfile"; then
			rm -f "$on_dir/run/$outfile.bak"
		fi
		if cmp -s "$base_dir/run/$outfile" "$on_dir/run/$outfile"; then
			echo "PASS: $name dual-run byte-identical ($(wc -c < "$base_dir/run/$outfile") bytes) (HP_DIR / RUN_DIR paths normalised)"
		else
			echo "FAIL: $name dual-run diverges"
			diff -u "$base_dir/run/$outfile" "$on_dir/run/$outfile" | head -40
			FAILED=1
		fi
	fi
}

# The flag=0 path is exactly the run_case() output already on disk; that
# is the reference. The flag=1 path is staged by dual_run(). Pin flag=0
# explicitly so the comparison is well-defined (sed in macOS BSD sed
# tolerates a non-empty extension; -i.bak works for both BSD and GNU).
if sed -i.bak 's#__HP_TEST_DOMAIN_MODEL__#0#' "$WORK/client/scripts/generate_client.uc"; then
	rm -f "$WORK/client/scripts/generate_client.uc.bak"
fi
if sed -i.bak 's#__HP_TEST_DOMAIN_MODEL__#0#' "$WORK/custom/scripts/generate_client.uc"; then
	rm -f "$WORK/custom/scripts/generate_client.uc.bak"
fi
if sed -i.bak 's#__HP_TEST_DOMAIN_MODEL__#0#' "$WORK/server/scripts/generate_server.uc"; then
	rm -f "$WORK/server/scripts/generate_server.uc.bak"
fi
dual_run client "$ROOT/tests/fixtures/generators/client.uci" sing-box-c.json generate_client.uc
dual_run custom "$ROOT/tests/fixtures/generators/custom.uci" sing-box-c.json generate_client.uc
dual_run server "$ROOT/tests/fixtures/generators/server.uci" sing-box-s.json generate_server.uc

exit $FAILED
