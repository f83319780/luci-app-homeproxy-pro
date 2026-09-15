#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# PR-05 extraction equivalence test.
#
# PHASE 7 moved the dnsmasq / fw4 / tproxy-TUN / service plumbing out of
# root/etc/init.d/homeproxy into root/etc/homeproxy/scripts/runtime/*.sh.
# That refactor is only defensible if the observable behaviour is unchanged,
# and "observable" on a router means: which commands run, in what order, with
# which arguments, and which files end up where.
#
# This test drives the init script through a stubbed environment and records
# exactly that.  The trace is compared against
# tests/fixtures/runtime/trace.pre-pr05.txt, captured from the init script as
# it stood *before* the extraction (commit 7e561e0, 517 lines).  A diff means
# the refactor changed behaviour.
#
# It is also the only test that exercises the start/stop orchestration as a
# whole: procd cannot run off-target, but the ordering a refactor can
# plausibly break (generate before teardown, known-good before firewall, cron
# before config_load, early return before mkdir) is all visible here.
#
# Usage: sh tests/runtime/test_runtime_extraction.sh <repo-root> [work-dir]
#
#   HP_INITD=<path>     drive another init script (used to regenerate the
#                       golden trace from the pre-PR-05 revision)
#   HP_UPDATE_GOLDEN=1  rewrite the golden fixture instead of comparing

ROOT="${1:-.}"
WORK="${2:-/tmp/hp-runtime-extraction}"

ROOT="$(cd "$ROOT" && pwd)"
SCRIPTS="$ROOT/root/etc/homeproxy/scripts"
GOLDEN="$ROOT/tests/fixtures/runtime/trace.pre-pr05.txt"
INITD="${HP_INITD:-$ROOT/root/etc/init.d/homeproxy}"

TRACE="$WORK/trace.txt"
SANDBOX="$WORK/box"
BIN="$WORK/bin"
# The dnsmasq conf-dir path is absolute in the payload; the section-name
# lookup is keyed off this file name.
DNSMASQ_CONF="/tmp/etc/dnsmasq.conf.hp_test"

rm -rf "$WORK"
mkdir -p "$SANDBOX/etc/homeproxy/scripts/runtime" \
         "$SANDBOX/etc/homeproxy/resources" \
         "$SANDBOX/var/run/homeproxy" \
         "$SANDBOX/dnsmasq" \
         "$SANDBOX/sbin" \
         "$BIN"

# --- the payload the init script expects ---------------------------------
cp "$SCRIPTS/runtime/"*.sh "$SANDBOX/etc/homeproxy/scripts/runtime/"
cp "$SCRIPTS/fw4_names.sh" "$SANDBOX/etc/homeproxy/scripts/fw4_names.sh"
# One line each is enough: the snippet generator rewrites these lists, it
# does not parse them.
printf 'example.com\nfoo.example.org\n' > "$SANDBOX/etc/homeproxy/resources/gfw_list.txt"
printf 'example.cn\n' > "$SANDBOX/etc/homeproxy/resources/china_list.txt"
printf 'proxy.example.net\n' > "$SANDBOX/etc/homeproxy/resources/proxy_list.txt"
# Makes the conf-dir resolver take its success path.
mkdir -p "$(dirname "$DNSMASQ_CONF")"
printf 'conf-dir=%s\n' "$SANDBOX/dnsmasq" > "$DNSMASQ_CONF"
# Makes the ujail branches reachable off-target.
: > "$SANDBOX/sbin/ujail"
chmod +x "$SANDBOX/sbin/ujail"

# --- stubs: every external command the orchestration can reach -----------
stub() {
	cat > "$BIN/$1" <<'EOF'
#!/bin/sh
printf '%s %s\n' "$(basename "$0")" "$*" >> "$TRACE"
exit 0
EOF
	chmod +x "$BIN/$1"
}

for cmd in nft fw4 utpl pgrep ubus jsonfilter chown; do
	stub "$cmd"
done

# `ip` is the one command whose exit status drives control flow: teardown
# drains duplicate rules with `while ip rule del ...; do :; done`, which only
# terminates because deleting a non-existent rule fails.  A stub that always
# succeeds would spin forever.
cat > "$BIN/ip" <<'EOF'
#!/bin/sh
printf 'ip %s\n' "$*" >> "$TRACE"
case "$*" in
*"rule del"*) exit 1 ;;
esac
exit 0
EOF
chmod +x "$BIN/ip"

# The WAN wait polls `ip route show default`, `ip -6 route show default` and
# `ifstatus wan`; the first two produce no output through the generic stub, so
# ifstatus has to report the interface up or every scenario would spin for a
# minute.  `sleep` is neutralised for the same reason.
cat > "$BIN/ifstatus" <<'EOF'
#!/bin/sh
printf '%s %s\n' ifstatus "$*" >> "$TRACE"
echo '{ "up": true }'
exit 0
EOF
chmod +x "$BIN/ifstatus"

cat > "$BIN/sleep" <<'EOF'
#!/bin/sh
printf '%s %s\n' sleep "$*" >> "$TRACE"
exit 0
EOF
chmod +x "$BIN/sleep"

# The conf-dir resolver derives the dnsmasq section name from `uci show`.
cat > "$BIN/uci" <<'EOF'
#!/bin/sh
printf '%s %s\n' uci "$*" >> "$TRACE"
case "$*" in
*"show dhcp.@dnsmasq[0]"*) echo "dhcp.hp_test= dnsmasq" ;;
esac
exit 0
EOF
chmod +x "$BIN/uci"

# `uname -r` decides the GSO workaround; pin it so both traces agree.
cat > "$BIN/uname" <<'EOF'
#!/bin/sh
printf '%s %s\n' uname "$*" >> "$TRACE"
[ "$1" = "-r" ] && echo "6.12.94" || echo "Linux"
EOF
chmod +x "$BIN/uname"

# `sing-box version -n` feeds the version gate and the "started" log line.
cat > "$BIN/sing-box" <<'EOF'
#!/bin/sh
printf '%s %s\n' sing-box "$*" >> "$TRACE"
[ "$1" = "version" ] && echo "1.14.0"
exit 0
EOF
chmod +x "$BIN/sing-box"

# `ucode -S generate_*.uc` is where the live configuration comes from.  The
# stub writes a configuration that passes the jail gate (no wireguard/tun
# outbound), so the ujail branch is exercised at all.
cat > "$BIN/ucode" <<'EOF'
#!/bin/sh
printf '%s %s\n' ucode "$*" >> "$TRACE"
for arg in "$@"; do
	case "$arg" in
	*generate_client.uc) printf '{"log":{},"outbounds":[]}\n' > "$HP_TEST_RUN_DIR/sing-box-c.json" ;;
	*generate_server.uc) printf '{"log":{},"inbounds":[]}\n' > "$HP_TEST_RUN_DIR/sing-box-s.json" ;;
	esac
done
exit 0
EOF
chmod +x "$BIN/ucode"

# --- harness: UCI + procd + the log sink ---------------------------------
# Sourced *into* the same shell as the init script, exactly like rc.common
# does, so the init script's globals and functions resolve as on a router.
cat > "$WORK/harness.sh" <<'EOF'
# Fixture UCI values.  config_get assigns through its first argument - an
# OpenWrt config_get is a variable-setting function, not a getter.
HP_CFG_routing_mode="bypass_mainland_china"
HP_CFG_proxy_mode="tun"
HP_CFG_main_node="n1"
HP_CFG_main_udp_node="nil"
HP_CFG_default_outbound="direct-out"
HP_CFG_ipv6_support="0"
HP_CFG_auto_update="0"
HP_CFG_auto_update_time="2"
HP_CFG_server_enabled="0"
HP_CFG_table_mark="100"
HP_CFG_tproxy_mark="101"
HP_CFG_tun_mark="102"
HP_CFG_tun_name="singtun0"
HP_CFG_dns_port="5333"

config_load() { printf 'config_load %s\n' "$*" >> "$TRACE"; }

config_get() {
	__cg_var="$1"; __cg_opt="$3"; __cg_def="$4"
	eval "__cg_val=\"\${HP_CFG_${__cg_opt}:-}\""
	[ -n "$__cg_val" ] || __cg_val="$__cg_def"
	eval "$__cg_var=\"\$__cg_val\""
}

config_get_bool() {
	__cg_var="$1"; __cg_opt="$3"; __cg_def="$4"
	eval "__cg_val=\"\${HP_CFG_${__cg_opt}:-}\""
	[ -n "$__cg_val" ] || __cg_val="$__cg_def"
	eval "$__cg_var=\"\$__cg_val\""
}

# procd is not available off-target; record the calls instead, so a lost or
# reordered instance parameter shows up as a trace diff.
procd_open_instance() { printf 'procd_open_instance %s\n' "$*" >> "$TRACE"; }
procd_close_instance() { printf 'procd_close_instance\n' >> "$TRACE"; }
procd_set_param() { printf 'procd_set_param %s\n' "$*" >> "$TRACE"; }
procd_append_param() { printf 'procd_append_param %s\n' "$*" >> "$TRACE"; }
procd_add_jail() { printf 'procd_add_jail %s\n' "$*" >> "$TRACE"; }
procd_add_jail_mount() { printf 'procd_add_jail_mount %s\n' "$*" >> "$TRACE"; }
procd_add_jail_mount_rw() { printf 'procd_add_jail_mount_rw %s\n' "$*" >> "$TRACE"; }
procd_add_reload_trigger() { printf 'procd_add_reload_trigger %s\n' "$*" >> "$TRACE"; }
procd_add_interface_trigger() { printf 'procd_add_interface_trigger %s\n' "$*" >> "$TRACE"; }

# The real log() stamps a timestamp and appends to a file, which would make
# the trace nondeterministic.
hp_trace_log() { printf 'log %s\n' "$*" >> "$TRACE"; }
EOF

# --- run one scenario ----------------------------------------------------
# $1 scenario name, then the HP_CFG_* overrides for it.
run_scenario() {
	scenario="$1"; shift

	rm -rf "$SANDBOX/var/run/homeproxy" "$SANDBOX/dnsmasq/dnsmasq-homeproxy.d" \
	       "$SANDBOX/dnsmasq/dnsmasq-homeproxy.conf" "$SANDBOX/etc/homeproxy/cache.db" \
	       "$SANDBOX/etc/homeproxy/ruleset" "$SANDBOX/etc/homeproxy/certs"
	mkdir -p "$SANDBOX/var/run/homeproxy" "$SANDBOX/dnsmasq"

	printf '\n===== scenario: %s =====\n' "$scenario" >> "$TRACE"

	(
		PATH="$BIN:$PATH"; export PATH
		TRACE="$TRACE"; export TRACE
		HP_TEST_RUN_DIR="$SANDBOX/var/run/homeproxy"; export HP_TEST_RUN_DIR

		for kv in "$@"; do
			eval "HP_CFG_${kv%%=*}=\"${kv#*=}\""
			export "HP_CFG_${kv%%=*}"
		done
		export HP_CFG_routing_mode HP_CFG_proxy_mode HP_CFG_main_node \
			HP_CFG_main_udp_node HP_CFG_default_outbound HP_CFG_ipv6_support \
			HP_CFG_auto_update HP_CFG_auto_update_time HP_CFG_server_enabled \
			HP_CFG_table_mark HP_CFG_tproxy_mark HP_CFG_tun_mark \
			HP_CFG_tun_name HP_CFG_dns_port

		. "$WORK/harness.sh"
		. "$WORK/initd.sh"

		# Override the log sink the init script just defined.
		log() { hp_trace_log "$*"; }

		start_service
		printf 'start_service rc=%d\n' "$?" >> "$TRACE"
		stop_service
		printf 'stop_service rc=%d\n' "$?" >> "$TRACE"
		service_stopped
		printf 'service_stopped rc=%d\n' "$?" >> "$TRACE"
	) >/dev/null 2>&1

	# Record the files that ended up in the output directories, with
	# contents, so a changed snippet or a lost known-good copy is visible.
	for f in "$SANDBOX/var/run/homeproxy"/* \
	         "$SANDBOX/var/run/homeproxy/known-good"/* \
	         "$SANDBOX/etc/homeproxy/cache.db" \
	         "$SANDBOX/dnsmasq"/* \
	         "$SANDBOX/dnsmasq/dnsmasq-homeproxy.d"/*; do
		[ -f "$f" ] || continue
		printf 'file %s: ' "${f#"$SANDBOX"/}" >> "$TRACE"
		tr '\n' '|' < "$f" >> "$TRACE"
		printf '\n' >> "$TRACE"
	done
}

# --- stage the init script under test ------------------------------------
# Rewrite the absolute paths to the sandbox.  Anchor guards: a silent no-op
# rewrite would make this test compare two unsandboxed runs and pass for the
# wrong reason.
#
# `/sbin/ujail` lives in init.d before PR-05 and in runtime/service.sh after
# it, so the rewrite has to cover both.
sandbox_ujail() {
	sed "s#-x \"/sbin/ujail\"#-x \"$SANDBOX/sbin/ujail\"#g" "$1" > "$1.tmp" \
		&& mv "$1.tmp" "$1"
}

sed -e "s#^HP_DIR=\"/etc/homeproxy\"#HP_DIR=\"$SANDBOX/etc/homeproxy\"#" \
    -e "s#^RUN_DIR=\"/var/run/homeproxy\"#RUN_DIR=\"$SANDBOX/var/run/homeproxy\"#" \
    "$INITD" > "$WORK/initd.sh"
sandbox_ujail "$WORK/initd.sh"

for module in "$SANDBOX/etc/homeproxy/scripts/runtime"/*.sh; do
	sandbox_ujail "$module"
done

for anchor in "HP_DIR=\"$SANDBOX/etc/homeproxy\"" \
              "RUN_DIR=\"$SANDBOX/var/run/homeproxy\""; do
	if ! grep -qF "$anchor" "$WORK/initd.sh"; then
		echo "FAIL: could not sandbox $INITD - missing anchor: $anchor"
		rm -f "$DNSMASQ_CONF"
		exit 1
	fi
done

if ! grep -qF "$SANDBOX/sbin/ujail" "$WORK/initd.sh" "$SANDBOX/etc/homeproxy/scripts/runtime"/*.sh; then
	echo "FAIL: could not sandbox the ujail probe - the jail branch would be skipped"
	rm -f "$DNSMASQ_CONF"
	exit 1
fi

# Scenario A: TUN client, bypass_mainland_china, no server, no ipv6.
run_scenario "A-tun-bypass-client-only" \
	proxy_mode=tun routing_mode=bypass_mainland_china \
	main_node=n1 main_udp_node=nil server_enabled=0 ipv6_support=0

# Scenario B: tproxy client with a UDP node + ipv6, gfwlist, server enabled,
# auto-update cron on.
run_scenario "B-tproxy-gfwlist-ipv6-with-server" \
	proxy_mode=redirect_tproxy routing_mode=gfwlist \
	main_node=n1 main_udp_node=u1 server_enabled=1 ipv6_support=1 \
	auto_update=1 auto_update_time=3

# Scenario C: neither side configured -> the early return must stay early.
run_scenario "C-nothing-configured" \
	proxy_mode=tun routing_mode=bypass_mainland_china \
	main_node=nil main_udp_node=nil server_enabled=0 ipv6_support=0

rm -f "$DNSMASQ_CONF"

# Strip the sandbox prefix so the trace is portable.
sed "s#$SANDBOX/##g" "$TRACE" > "$TRACE.norm"

if [ "${HP_UPDATE_GOLDEN:-0}" = "1" ]; then
	mkdir -p "$(dirname "$GOLDEN")"
	cp "$TRACE.norm" "$GOLDEN"
	echo "PASS: golden trace written to $GOLDEN ($(wc -l < "$GOLDEN") lines)"
	exit 0
fi

if [ ! -f "$GOLDEN" ]; then
	echo "FAIL: golden trace $GOLDEN is missing"
	exit 1
fi

if diff -u "$GOLDEN" "$TRACE.norm" > "$WORK/trace.diff"; then
	echo "PASS: runtime extraction is behaviour-identical to the pre-PR-05 init script"
	echo "      ($(wc -l < "$GOLDEN") trace lines across 3 scenarios)"
else
	echo "FAIL: the extracted runtime changed behaviour:"
	head -80 "$WORK/trace.diff"
	exit 1
fi

exit 0
