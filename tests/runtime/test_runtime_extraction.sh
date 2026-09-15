#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Runtime orchestration trace test.
#
# Drives root/etc/init.d/homeproxy through a stubbed environment and records
# exactly what the orchestration does: which commands run, in what order, with
# which arguments, and which files end up where.  The trace is compared against
# tests/fixtures/runtime/trace.golden.txt.
#
# Two baselines live in tests/fixtures/runtime/:
#
#   trace.pre-pr05.txt  captured from the 517-line init script before PHASE 7
#                       moved the dnsmasq/fw4/net/service plumbing out of it.
#                       It is the record that the extraction itself was
#                       behaviour-preserving (360 identical lines across three
#                       scenarios, commit c2aeac5).
#   trace.golden.txt    the baseline after the health-gate fix
#                       (docs/architecture-improvement-plan.md 2.14).  The
#                       difference between the two files IS the intentional
#                       change: start_service now waits for hp_wait_service
#                       before logging "started", records known-good only
#                       after that gate passed, and reload_service rolls back
#                       through start instead of duplicating the gate.
#                       `diff trace.pre-pr05.txt trace.golden.txt` is the
#                       review artifact.
#
# Scenario D is the regression test for the P0: a candidate configuration whose
# mixed_port is already taken must NOT be recorded as known-good, and a reload
# must roll back to the previous configuration.
#
# Usage: sh tests/runtime/test_runtime_extraction.sh <repo-root> [work-dir]
#
#   HP_INITD=<path>       drive another init script
#   HP_GOLDEN=<path>      compare against another baseline
#   HP_UPDATE_GOLDEN=1    rewrite the baseline instead of comparing

ROOT="${1:-.}"
# Per-run by default rather than a fixed /tmp path. This script has two
# callers (tests/run.sh and tests/ucode/run.sh) and one of them passed no work
# dir, so two concurrent suite runs shared /tmp/hp-runtime-trace and deleted
# each other's sandbox mid-test - the reproducible symptom was "could not
# sandbox ... missing anchor". tests/runtime/test_config_transaction.sh already
# defaults to mktemp -d.
WORK="${2:-$(mktemp -d "${TMPDIR:-/tmp}/hp-runtime-trace.XXXXXX")}"
OWN_WORK=0
[ -n "${2:-}" ] || OWN_WORK=1

# The dnsmasq conf path is the one shared resource left: it must stay at
# /tmp/etc/dnsmasq.conf.hp_test because the payload is what derives the section
# name, so it cannot move into $WORK. Concurrent runs therefore take turns on
# it, via mkdir (atomic everywhere, no flock dependency), with a bounded wait so
# a stale lock cannot hang the suite.
DNSMASQ_LOCK="/tmp/etc/.hp-runtime-trace.lock"
mkdir -p "$(dirname "$DNSMASQ_LOCK")"
_lock_tries=0
while ! mkdir "$DNSMASQ_LOCK" 2>/dev/null; do
	_lock_tries=$((_lock_tries + 1))
	if [ "$_lock_tries" -gt 120 ]; then
		echo "FAIL: another run has held $DNSMASQ_LOCK for over two minutes"
		exit 1
	fi
	sleep 1
done

# A trap rather than a line at the end: this script exits early on several
# failure paths, and the first version of this cleanup was inserted into the
# middle of one of them.
cleanup() {
	rmdir "$DNSMASQ_LOCK" 2>/dev/null
	[ "$OWN_WORK" = 1 ] && rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

ROOT="$(cd "$ROOT" && pwd)"
SCRIPTS="$ROOT/root/etc/homeproxy/scripts"
GOLDEN="${HP_GOLDEN:-$ROOT/tests/fixtures/runtime/trace.golden.txt}"
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
         "$SANDBOX/init.d" \
         "$SANDBOX/etc/crontabs" \
         "$BIN"

# The auto-update entry is installed by editing the crontab in place, so the
# file has to exist in the sandbox: on a laptop /etc/crontabs/root does not, the
# `sed -i` fails and the run logs a warning the target never produces.  Seeded
# with a stale entry so the delete path is actually exercised.
printf '# existing entry\n0 2 * * * /etc/init.d/acme renew\n0 2 * * * /x #homeproxy_autosetup\n' \
	> "$SANDBOX/etc/crontabs/root"

# Stand-ins for the absolute init scripts the runtime calls.  They record the
# call and succeed, so the trace is the same everywhere and the "Warning: failed
# to restart ..." lines a laptop produced cannot leak into the golden.
for initd in dnsmasq cron miniupnpd; do
	cat > "$SANDBOX/init.d/$initd" <<'EOF'
#!/bin/sh
printf 'init.d/%s %s\n' "$(basename "$0")" "$*" >> "$TRACE"
exit 0
EOF
	chmod +x "$SANDBOX/init.d/$initd"
done

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

for cmd in nft fw4 utpl pgrep chown; do
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

# `uname -r` decides the GSO workaround; pin it so traces agree.
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
# stub writes whichever mixed_port the fixture currently declares; whether that
# configuration can actually run is decided from its content by
# `hp_test_broken` below, so the answer follows the live file rather than a
# sticky marker (the rollback copies the old file over the live one without
# regenerating, and the gate has to see that as healthy).
cat > "$BIN/ucode" <<'EOF'
#!/bin/sh
printf 'ucode %s\n' "$*" >> "$TRACE"
for arg in "$@"; do
	case "$arg" in
	*generate_client.uc)
		printf '{"log":{},"inbounds":[{"tag":"dns-in","listen_port":%s},{"tag":"mixed-in","listen_port":%s}],"outbounds":[]}\n' \
			"${HP_CFG_dns_port:-5333}" "${HP_CFG_mixed_port:-5330}" > "$HP_TEST_RUN_DIR/sing-box-c.json"
		;;
	*generate_server.uc)
		printf '{"log":{},"inbounds":[],"outbounds":[]}\n' > "$HP_TEST_RUN_DIR/sing-box-s.json"
		;;
	esac
done
exit 0
EOF
chmod +x "$BIN/ucode"

# The fault model: a configuration that declares the port the fixture pretends
# is already taken cannot come up.  Keyed on the live file's content, so it
# stays correct when the rollback replaces that file without regenerating.
cat > "$BIN/hp_test_broken" <<'EOF'
#!/bin/sh
side="$1"
[ -n "${HP_TEST_OCCUPIED_PORT:-}" ] || exit 1
[ -f "$HP_TEST_RUN_DIR/sing-box-$side.json" ] || exit 1
grep -q "\"listen_port\":$HP_TEST_OCCUPIED_PORT" "$HP_TEST_RUN_DIR/sing-box-$side.json" || exit 1
exit 0
EOF
chmod +x "$BIN/hp_test_broken"

# `ubus call service list` output is not parsed; `jsonfilter` answers from the
# fixture state instead, which keeps the stub independent of jsonfilter's real
# expression language.  ubus does not write to the trace itself: its output
# always goes through a pipe, so a second writer would race the trace order.
cat > "$BIN/ubus" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$BIN/ubus"

# procd's view of the instance.  Down + exit_code 1 whenever the live
# configuration for that side cannot bind - which is what procd reports while
# it restarts a crashing instance.
cat > "$BIN/jsonfilter" <<'EOF'
#!/bin/sh
printf 'jsonfilter %s\n' "$*" >> "$TRACE"
side="c"
case "$*" in
*"sing-box-s"*) side="s" ;;
esac
down=no
hp_test_broken "$side" && down=yes
case "$*" in
*".instances["*)
	if [ "$down" = "yes" ]; then
		printf '{"running":false,"exit_code":1}\n'
	else
		printf '{"running":true}\n'
	fi
	;;
*"@.running"*)
	[ "$down" = "yes" ] && echo "false" || echo "true"
	;;
*"@.exit_code"*)
	[ "$down" = "yes" ] && echo "1"
	;;
esac
exit 0
EOF
chmod +x "$BIN/jsonfilter"

# The listen table.  The ports are taken from the LIVE configuration, the way
# the real gate derives them, and the occupied port is held by the process that
# took it - the case that makes a naive "is the port in the table?" check
# useless.
cat > "$BIN/netstat" <<'EOF'
#!/bin/sh
printf 'netstat %s\n' "$*" >> "$TRACE"
echo "Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name"
live="$HP_TEST_RUN_DIR/sing-box-c.json"
ports=$(grep -o '"listen_port"[^0-9]*[0-9]*' "$live" 2>/dev/null | grep -o '[0-9]*$' | tr '\n' ' ')
[ -n "$ports" ] || ports="${HP_CFG_mixed_port:-5330} ${HP_CFG_dns_port:-5333}"
for p in $ports; do
	if [ -n "${HP_TEST_OCCUPIED_PORT:-}" ] && [ "$p" = "$HP_TEST_OCCUPIED_PORT" ]; then
		printf 'tcp        0      0 :::%s                 :::*                    LISTEN      77/socat\n' "$p"
	else
		printf 'tcp        0      0 :::%s                 :::*                    LISTEN      4242/sing-box\n' "$p"
	fi
done
exit 0
EOF
chmod +x "$BIN/netstat"

# The WAN wait polls `ip route show default`, `ip -6 route show default` and
# `ifstatus wan`; the first two produce no output through the generic stub, so
# ifstatus has to report the interface up or every scenario would spin for a
# minute.  `sleep` is neutralised for the same reason: the 15-sample health
# budget must not cost 15 real seconds.
cat > "$BIN/ifstatus" <<'EOF'
#!/bin/sh
printf 'ifstatus %s\n' "$*" >> "$TRACE"
echo '{ "up": true }'
exit 0
EOF
chmod +x "$BIN/ifstatus"

cat > "$BIN/sleep" <<'EOF'
#!/bin/sh
printf 'sleep %s\n' "$*" >> "$TRACE"
exit 0
EOF
chmod +x "$BIN/sleep"

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
HP_CFG_mixed_port="5330"

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

# rc.common's lifecycle, modelled faithfully:
#
#   start() { rc_procd start_service "$@"; service_started; }
#   stop()  { stop_service "$@"; procd_kill ...; service_stopped; }
#
# start_service only *registers* the procd instances; procd runs them when the
# service is closed.  That is why the health gate lives in service_started()
# and why this harness has to call it - a harness that reported the instances
# healthy as soon as they were registered hid exactly that bug once.
start() { start_service; service_started; }
stop() { stop_service; service_stopped; }

# The real log() stamps a timestamp and appends to a file, which would make
# the trace nondeterministic.
hp_trace_log() { printf 'log %s\n' "$*" >> "$TRACE"; }
EOF

# --- run one scenario ----------------------------------------------------
# $1 scenario name, $2 the action (start|reload), then the HP_CFG_* overrides.
run_scenario() {
	scenario="$1"; shift
	action="$1"; shift

	rm -rf "$SANDBOX/var/run/homeproxy" "$SANDBOX/dnsmasq/dnsmasq-homeproxy.d" \
	       "$SANDBOX/dnsmasq/dnsmasq-homeproxy.conf" "$SANDBOX/etc/homeproxy/cache.db" \
	       "$SANDBOX/etc/homeproxy/ruleset" "$SANDBOX/etc/homeproxy/certs"
	mkdir -p "$SANDBOX/var/run/homeproxy" "$SANDBOX/dnsmasq"

	printf '\n===== scenario: %s (%s) =====\n' "$scenario" "$action" >> "$TRACE"

	(
		PATH="$BIN:$PATH"; export PATH
		TRACE="$TRACE"; export TRACE
		HP_TEST_RUN_DIR="$SANDBOX/var/run/homeproxy"; export HP_TEST_RUN_DIR

		# harness.sh assigns the fixture defaults, so it has to be sourced
		# BEFORE the per-scenario overrides - the other order silently
		# resets every override and makes all scenarios run the same
		# configuration.
		. "$WORK/harness.sh"

		for kv in "$@"; do
			eval "HP_CFG_${kv%%=*}=\"${kv#*=}\""
			export "HP_CFG_${kv%%=*}"
		done
		export HP_CFG_routing_mode HP_CFG_proxy_mode HP_CFG_main_node \
			HP_CFG_main_udp_node HP_CFG_default_outbound HP_CFG_ipv6_support \
			HP_CFG_auto_update HP_CFG_auto_update_time HP_CFG_server_enabled \
			HP_CFG_table_mark HP_CFG_tproxy_mark HP_CFG_tun_mark \
			HP_CFG_tun_name HP_CFG_dns_port HP_CFG_mixed_port \
			HP_TEST_OCCUPIED_PORT HP_TEST_DOWN

		. "$WORK/initd.sh"

		# Override the log sink the init script just defined.
		log() { hp_trace_log "$*"; }

		# Scenario D needs a good configuration in place first, so that the
		# rollback has a real target to restore.  The candidate is switched
		# to the already-taken port only for the reload.
		if [ "$action" = "reload" ]; then
			unset HP_TEST_OCCUPIED_PORT
			start
			printf 'prime start rc=%d\n' "$?" >> "$TRACE"
			HP_CFG_mixed_port="${HP_TEST_OCCUPIED_AFTER:-5399}"
			HP_TEST_OCCUPIED_PORT="${HP_TEST_OCCUPIED_AFTER:-5399}"
			export HP_CFG_mixed_port HP_TEST_OCCUPIED_PORT
			reload_service
			printf 'reload_service rc=%d\n' "$?" >> "$TRACE"
		else
			start
			printf 'start rc=%d\n' "$?" >> "$TRACE"
		fi

		stop
		printf 'stop rc=%d\n' "$?" >> "$TRACE"
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
# The runtime modules talk to a few ABSOLUTE paths, and those are the test's
# only host dependence: `/etc/init.d/dnsmasq` exists on a router (so the real
# script runs, with its own side effects) and not on a laptop, and `/sbin/ujail`
# likewise.  Rewriting them into the sandbox is what makes the trace identical
# on macOS, on the CI runner and on the target - the first on-target run differed
# from line 11 purely because dnsmasq's init script was there to run.
sandbox_paths() {
	sed -e "s#-x \"/sbin/ujail\"#-x \"$SANDBOX/sbin/ujail\"#g" \
	    -e "s#/etc/init.d/dnsmasq#$SANDBOX/init.d/dnsmasq#g" \
	    -e "s#/etc/init.d/cron#$SANDBOX/init.d/cron#g" \
	    -e "s#/etc/init.d/miniupnpd#$SANDBOX/init.d/miniupnpd#g" \
	    -e "s#/etc/crontabs/root#$SANDBOX/etc/crontabs/root#g" \
	    "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

sed -e "s#^HP_DIR=\"/etc/homeproxy\"#HP_DIR=\"$SANDBOX/etc/homeproxy\"#" \
    -e "s#^RUN_DIR=\"/var/run/homeproxy\"#RUN_DIR=\"$SANDBOX/var/run/homeproxy\"#" \
    "$INITD" > "$WORK/initd.sh"
sandbox_paths "$WORK/initd.sh"

for module in "$SANDBOX/etc/homeproxy/scripts/runtime"/*.sh; do
	sandbox_paths "$module"
done

for anchor in "HP_DIR=\"$SANDBOX/etc/homeproxy\"" \
              "RUN_DIR=\"$SANDBOX/var/run/homeproxy\""; do
	if ! grep -qF "$anchor" "$WORK/initd.sh"; then
		echo "FAIL: could not sandbox $INITD - missing anchor: $anchor"
		rm -f "$DNSMASQ_CONF"
		exit 1
	fi
done

for anchor in "$SANDBOX/sbin/ujail" "$SANDBOX/init.d/dnsmasq" "$SANDBOX/init.d/cron" \
              "$SANDBOX/etc/crontabs/root"; do
	if ! grep -qF "$anchor" "$WORK/initd.sh" "$SANDBOX/etc/homeproxy/scripts/runtime"/*.sh; then
		echo "FAIL: could not sandbox $anchor - the trace would depend on the host"
		rm -f "$DNSMASQ_CONF"
		exit 1
	fi
done

# Scenario A: TUN client, bypass_mainland_china, no server, no ipv6.
run_scenario "A-tun-bypass-client-only" start \
	proxy_mode=tun routing_mode=bypass_mainland_china \
	main_node=n1 main_udp_node=nil server_enabled=0 ipv6_support=0

# Scenario B: tproxy client with a UDP node + ipv6, gfwlist, server enabled,
# auto-update cron on.
run_scenario "B-tproxy-gfwlist-ipv6-with-server" start \
	proxy_mode=redirect_tproxy routing_mode=gfwlist \
	main_node=n1 main_udp_node=u1 server_enabled=1 ipv6_support=1 \
	auto_update=1 auto_update_time=3

# Scenario C: neither side configured -> the early return must stay early.
run_scenario "C-nothing-configured" start \
	proxy_mode=tun routing_mode=bypass_mainland_china \
	main_node=nil main_udp_node=nil server_enabled=0 ipv6_support=0

# Scenario D: the P0 regression.  A healthy configuration is started and
# recorded, then a candidate whose mixed_port is already taken is reloaded.
# The gate must reject it, the previous known-good must survive, and the
# rollback must bring the service back on the old configuration.
run_scenario "D-health-gate-rollback" reload \
	proxy_mode=tun routing_mode=bypass_mainland_china \
	main_node=n1 main_udp_node=nil server_enabled=0 ipv6_support=0 \
	HP_TEST_OCCUPIED_AFTER=5399

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

# The decision must not depend on `diff`.  This test also runs on the target
# (tests/ucode/run.sh stages it there), and busybox has `cmp` but often no
# `diff` - the first on-target run failed with "diff: not found" and looked
# exactly like an orchestration change.  The golden snapshot tests already do
# it this way: `cmp` decides, `diff` only formats the diagnosis.
if cmp -s "$GOLDEN" "$TRACE.norm"; then
	echo "PASS: runtime orchestration matches $(basename "$GOLDEN")"
	echo "      ($(wc -l < "$GOLDEN") trace lines across 4 scenarios)"
	exit 0
fi

echo "FAIL: the orchestration changed:"
if command -v diff > "/dev/null" 2>&1; then
	diff -u "$GOLDEN" "$TRACE.norm" | head -80
else
	# No diff here: name the first differing lines and show both sides, which
	# is enough to diagnose without the tool.
	awk '
		NR == FNR { golden[FNR] = $0; n = FNR; next }
		{
			if ($0 != golden[FNR] && shown < 20) {
				printf "  line %d\n    golden: %s\n    actual: %s\n", FNR, golden[FNR], $0;
				shown++;
			}
		}
		END {
			if (n > FNR)
				printf "  (golden has %d more lines than the trace)\n", n - FNR;
		}
	' "$GOLDEN" "$TRACE.norm"
fi

exit 1

exit 0
