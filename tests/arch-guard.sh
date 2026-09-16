#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Architecture Guard.
#
# Static, cross-file invariants that the behavioural suites cannot see because
# each of them only exercises one layer at a time.  Every guard here exists
# because a real defect slipped through the whole suite:
#
#   guard 1  the generators read the UCI configuration through
#            HP_DIR + '/config', i.e. /etc/homeproxy/config/homeproxy - a path
#            that exists nowhere.  uci.load() returned null, every uci.get()
#            returned null, and the Loader silently produced pure defaults, so
#            every generated config lacked the main-out, the route/dns finals
#            and all of the user's ports and nodes.  The staged tests passed
#            because the test rewrote HP_DIR and staged the fixture wherever
#            the code happened to look.
#
#   guard 2  update_subscriptions.uc read subscription_urls and filter_keywords
#            off access_control.subscription, but the Loader puts them on
#            access_control itself.  Both were always [], so the updater's
#            `if (!isEmpty(subscription_urls))` guard never called main(): the
#            LuCI button and the cron entry were silent no-ops that exited 0.
#            The project's own model test asserted the *correct* shape, which
#            is exactly why the consumer's wrong read was never questioned.
#
# The lesson both share: a test that stages its own inputs cannot notice that
# production reads a different place.  These guards compare the layers to each
# other instead of comparing each layer to a fixture.
#
# POSIX sh only - no ucode, no node, no python.  Run:
#   sh tests/arch-guard.sh [repo-root]

set -u

ROOT="$(cd "${1:-$(dirname "$0")/..}" && pwd)"
SCRIPTS="$ROOT/root/etc/homeproxy/scripts"
RPC="$ROOT/root/usr/share/rpcd/ucode/luci.homeproxy"
ACL="$ROOT/root/usr/share/rpcd/acl.d/luci-app-homeproxy.json"
VIEWS="$ROOT/htdocs/luci-static/resources"
RUNTIME="$SCRIPTS/runtime"

FAILED=0
checks=0

pass() { checks=$((checks + 1)); printf 'PASS: %s\n' "$1"; }
fail() { checks=$((checks + 1)); FAILED=1; printf 'FAIL: %s\n' "$1"; }

# assert_empty <description> <command...>
assert_empty() {
	desc="$1"; shift
	out="$("$@" 2>/dev/null)"
	if [ -z "$out" ]; then
		pass "$desc"
	else
		fail "$desc"
		printf '      %s\n' "$out" | head -20
	fi
}

# assert_nonempty <description> <command...>
assert_nonempty() {
	desc="$1"; shift
	out="$("$@" 2>/dev/null)"
	if [ -n "$out" ]; then
		pass "$desc"
	else
		fail "$desc (nothing found)"
	fi
}

echo "== guard 1: the generators read the production UCI directory =="

# The confdir the Loader hands to cursor() must be /etc/config.  Anything else
# means uci.load() reads a file the package does not ship.
if grep -q "^export const UCICONFIG_DIR = '/etc/config';$" "$SCRIPTS/homeproxy.uc"; then
	pass "UCICONFIG_DIR defaults to /etc/config"
else
	fail "UCICONFIG_DIR does not default to /etc/config"
	grep -n "UCICONFIG_DIR" "$SCRIPTS/homeproxy.uc" | sed 's/^/      /'
fi

for g in generate_client.uc generate_server.uc; do
	if grep -q "Loader.load(UCICONFIG_DIR)" "$SCRIPTS/$g"; then
		pass "$g loads through UCICONFIG_DIR"
	else
		fail "$g does not call Loader.load(UCICONFIG_DIR)"
		grep -n "Loader.load" "$SCRIPTS/$g" | sed 's/^/      /'
	fi
done

# The original mistake, in either spelling: deriving the UCI directory from
# HP_DIR.  HP_DIR is /etc/homeproxy and holds resources/scripts, not config.
assert_empty "no source derives the UCI dir from HP_DIR" \
	grep -rn "Loader.load(HP_DIR\|Loader\.load( *HP_DIR" "$SCRIPTS"

# Every Loader.load() call site must use one of exactly two forms: the shared
# constant, or the bare default cursor().  A literal path - or any other
# expression - is how the original mistake would come back.
BADLOAD="$(grep -rhoE 'Loader\.load\([^)]*\)' "$SCRIPTS" \
	| grep -vE '^Loader\.load\((UCICONFIG_DIR)?\)$' | sort -u)"
if [ -z "$BADLOAD" ]; then
	pass "every Loader.load() call site uses UCICONFIG_DIR or the bare default"
else
	fail "unexpected Loader.load() argument:"
	printf '      %s\n' "$BADLOAD"
fi

echo
echo "== guard 2: the subscription updater reads fields where the Loader puts them =="

# Keys the Loader nests inside access_control.subscription (the
# load_settings(...) list).
LOADER="$SCRIPTS/config/loader.uc"
NESTED="$(awk '
	/subscription: load_settings\(uci, SECTION\.subscription, \[/ { inb = 1; next }
	inb && /\]\)/ { inb = 0; next }
	inb { print }
' "$LOADER" | grep -oE "'[a-z_][a-z0-9_]*'" | tr -d "'" | sort -u)"

if [ -n "$NESTED" ]; then
	pass "parsed the nested subscription keys ($(printf '%s' "$NESTED" | wc -l | tr -d ' ') of them)"
else
	fail "could not parse the nested subscription keys out of loader.uc"
fi

# Every `sub.<field>` read in the updater must be one of them.  `sub` is bound
# to loaded.access_control.subscription.
UPDATER="$SCRIPTS/update_subscriptions.uc"
BAD=""
for f in $(grep -oE '\bsub\.[a-z_][a-z0-9_]*' "$UPDATER" | sed 's/^sub\.//' | sort -u); do
	if ! printf '%s\n' "$NESTED" | grep -qx "$f"; then
		BAD="$BAD sub.$f"
	fi
done

if [ -z "$BAD" ]; then
	pass "every sub.<field> read in update_subscriptions.uc is nested under subscription"
else
	fail "update_subscriptions.uc reads fields off subscription that the Loader does not nest there:$BAD"
fi

# And the other direction: the two fields that regressed sit on access_control
# itself, so the updater must reach them through access_control - reading them
# through `sub.` is what made them a permanent [].  Asserted positively too, so
# the check cannot pass by finding nothing (the first draft of this guard
# grepped the *loader* for an "access_control.X" spelling that never appears
# there, matched nothing, and silently checked nothing at all).
for f in subscription_urls filter_keywords; do
	if grep -qE "\bsub\.$f\b" "$UPDATER"; then
		fail "update_subscriptions.uc reads sub.$f, but load_access_control() puts it on access_control"
	elif grep -qE "\baccess_control\.$f\b" "$UPDATER"; then
		pass "$f is read from access_control"
	else
		fail "$f is neither read from access_control nor from sub - the updater lost it entirely"
	fi
done

echo
echo "== guard 3: the ACL grants only what the browser actually writes =="

# The certificate buttons and the staging path each one uploads to.  The
# frontend derives /tmp/homeproxy_cert_<name>.tmp from the same name it passes
# to certificate_write, so the button list is the source of truth for what the
# ACL needs.
BTN="$(grep -rhoE "uploadCertificate[^;]*'[a-z_]+'\)" "$VIEWS" \
	| grep -oE "'[a-z_]+'\)$" | tr -d "')" | sort -u)"

if [ -n "$BTN" ]; then
	pass "found the certificate upload buttons: $(printf '%s ' $BTN)"
else
	fail "could not find any uploadCertificate call site under $VIEWS"
fi

for n in $BTN; do
	if grep -q "/tmp/homeproxy_cert_$n.tmp" "$ACL"; then
		pass "the ACL grants the staging path for $n"
	else
		fail "the ACL is missing the staging path for $n"
	fi
done

# The write-file block, as a list of paths.
WRITE_FILES="$(awk '
	/"write"[[:space:]]*:/ { inwrite = 1 }
	inwrite && /"file"[[:space:]]*:/ { infile = 1; next }
	infile && /^[[:space:]]*}/ { infile = 0; inwrite = 0; next }
	infile { print }
' "$ACL" | grep -oE '"/[^"]*"' | tr -d '"')"

if [ -n "$WRITE_FILES" ]; then
	pass "parsed the ACL write-file list ($(printf '%s\n' "$WRITE_FILES" | grep -c . ) paths)"
else
	fail "could not parse the ACL write-file list"
fi

# The file ACL governs what a *browser session* may touch through fs.*.  The
# backend writes certs/ and resources/ as root, authorised by its ubus method
# entry - not by this list.  So a /etc/ entry here grants nothing the feature
# needs, and does grant a session holding only this ACL the ability to
# overwrite server_privatekey.pem directly through fs.write, bypassing the PEM
# and binary checks in certificate_write.
ETC_WRITES="$(printf '%s\n' "$WRITE_FILES" | grep '^/etc/' || true)"
if [ -z "$ETC_WRITES" ]; then
	pass "the ACL write list grants no /etc/ path"
else
	fail "the ACL write list grants /etc/ paths no browser operation uses:"
	printf '      %s\n' "$ETC_WRITES"
fi

# The general form, so a future fs.write has to come with a deliberate ACL
# change rather than silently inheriting a stale grant.
assert_empty "the frontend makes no fs.write call" \
	grep -rn "fs\.write" "$VIEWS"

echo
echo "== guard 4: the ACL and the rpcd method table agree =="

BACKEND_METHODS="$(sed -n 's/^\t\([a-z_][a-z0-9_]*\): {$/\1/p' "$RPC" | sort -u)"
if [ -n "$BACKEND_METHODS" ]; then
	pass "parsed $(printf '%s\n' "$BACKEND_METHODS" | grep -c .) rpcd methods"
else
	fail "could not parse any method out of $(basename "$RPC")"
fi

ACL_METHODS="$(awk '
	/"ubus"[[:space:]]*:/ { inubus = 1; next }
	inubus && /^[[:space:]]*}/ { inubus = 0; next }
	inubus && /"luci.homeproxy"[[:space:]]*:/ { inlist = 1; next }
	inlist && /\]/ { inlist = 0; next }
	inlist { print }
' "$ACL" | grep -oE '"[a-z_]+"' | tr -d '"' | sort -u)"

if [ -n "$ACL_METHODS" ]; then
	pass "parsed $(printf '%s\n' "$ACL_METHODS" | grep -c .) ACL ubus methods"
else
	fail "could not parse any ubus method out of the ACL"
fi

# Not `comm`: it takes file arguments, and POSIX sh has no process
# substitution.  The first draft used it anyway, so comm failed, the variable
# came back empty and the check passed without testing anything.
UNGATED=""
for m in $BACKEND_METHODS; do
	printf '%s\n' "$ACL_METHODS" | grep -qx "$m" || UNGATED="$UNGATED $m"
done
if [ -z "$UNGATED" ]; then
	pass "every rpcd method is reachable through the ACL"
else
	fail "these rpcd methods have no ACL entry, so no session can call them:"
	printf '      %s\n' "$UNGATED"
fi

PHANTOM=""
for m in $ACL_METHODS; do
	printf '%s\n' "$BACKEND_METHODS" | grep -qx "$m" || PHANTOM="$PHANTOM $m"
done
if [ -z "$PHANTOM" ]; then
	pass "the ACL grants no method the module does not define"
else
	fail "the ACL grants methods that do not exist:"
	printf '      %s\n' "$PHANTOM"
fi

# A wildcard would make the two checks above meaningless.
if grep -qE '"[*]"' "$ACL"; then
	fail "the ACL contains a wildcard"
else
	pass "the ACL contains no wildcard"
fi

echo
echo "== guard 5: every RPC the frontend calls is a real method, and is tested =="

FRONTEND_METHODS="$(grep -rhoE "rpcCall\('[a-z_]+'" "$VIEWS" \
	| sed "s/rpcCall('//" | tr -d "'" | sort -u)"

if [ -n "$FRONTEND_METHODS" ]; then
	pass "parsed $(printf '%s\n' "$FRONTEND_METHODS" | grep -c .) rpcCall method names"
else
	fail "found no rpcCall method names under $VIEWS"
fi

UNKNOWN=""
for m in $FRONTEND_METHODS; do
	# 'list' is the ubus *service* object, not this module's.
	if [ "$m" = "list" ]; then
		grep -rq "object: 'service'" "$VIEWS" \
			|| UNKNOWN="$UNKNOWN list(not via the service object)"
		continue
	fi
	printf '%s\n' "$BACKEND_METHODS" | grep -qx "$m" || UNKNOWN="$UNKNOWN $m"
done

if [ -z "$UNKNOWN" ]; then
	pass "every frontend rpcCall names a method the backend defines"
else
	fail "the frontend calls methods the backend does not define:$UNKNOWN"
fi

# And every one of them must be exercised somewhere, so a method cannot be
# shipped - or a call site broken - without a test noticing.
UNTESTED=""
for m in $FRONTEND_METHODS; do
	[ "$m" = "list" ] && continue
	grep -rq "$m" "$ROOT/tests" || UNTESTED="$UNTESTED $m"
done

if [ -z "$UNTESTED" ]; then
	pass "every RPC the frontend calls is referenced by a test"
else
	fail "these RPCs are called by the frontend but referenced by no test:$UNTESTED"
fi

echo
echo "== guard 6: every certificate button has a backend case =="

# guard 3 already found $BTN from the views.
BACKEND_CASES="$(awk '/certificate_write: \{/,/^\t\},/' "$RPC" \
	| grep -oE "case '[a-z_]+'" | sed "s/case '//" | tr -d "'" | sort -u)"

if [ -n "$BACKEND_CASES" ]; then
	pass "parsed the certificate_write cases: $(printf '%s ' $BACKEND_CASES)"
else
	fail "could not parse the certificate_write cases"
fi

for n in $BTN; do
	printf '%s\n' "$BACKEND_CASES" | grep -qx "$n" \
		&& pass "certificate_write handles '$n'" \
		|| fail "the '$n' upload button has no certificate_write case"
done

echo
echo "== guard 7: the semantic layers do not touch UCI =="

# UCI -> Loader -> {Parser, Generator, Runtime}: config/loader.uc owns the only
# cursor on the client path.  A parser or generator that grows its own cursor
# breaks the layering this refactor exists to establish.
LAYERS="$SCRIPTS/generator $SCRIPTS/parser $SCRIPTS/config/model.uc $SCRIPTS/config/adapter.uc"
assert_empty "no parser/generator/model/adapter imports the uci module" \
	grep -rn "from 'uci'" $LAYERS
assert_empty "no parser/generator/model/adapter opens a cursor" \
	grep -rn "cursor(" $LAYERS
assert_nonempty "the Loader is still the one that owns the cursor" \
	grep -rn "cursor(" "$SCRIPTS/config/loader.uc"

echo
echo "== guard 8: the generators write through a private scratch dir =="

# reload_service generates the client and start_service generates it again, so
# two runs can overlap. A fixed `<out>.tmp` name in RUN_DIR meant both wrote the
# same file, and `sing-box check` could validate a file the other run was still
# writing - the winner then installed a half-written config. mkdtemp() gives each
# run its own 0700 directory.
for g in generate_client.uc generate_server.uc; do
	if grep -q "mkdtemp()" "$SCRIPTS/$g"; then
		pass "$g uses mkdtemp() for its scratch dir"
	else
		fail "$g does not use mkdtemp() - its scratch path is shared between runs"
	fi

	# The specific shape that was wrong: a temp path built from RUN_DIR.
	SHARED="$(grep -n "RUN_DIR + '/sing-box-.*\.tmp'" "$SCRIPTS/$g" || true)"
	if [ -z "$SHARED" ]; then
		pass "$g does not build a fixed temp path under RUN_DIR"
	else
		fail "$g builds a shared temp path under RUN_DIR:"
		printf '      %s\n' "$SHARED"
	fi
done

echo
echo "== guard 9: the pgrep fallback still matches the procd command =="

# hp_instance_running falls back to `pgrep -f` only when ubus cannot be asked at
# all, and the pattern it matches has to stay in step with the command procd is
# told to run. Change either alone and the fallback silently stops matching -
# and then the health gate degrades to "always times out", which rolls back a
# perfectly good configuration. A wrong pattern would look like a bad config.
# ^[^#]* keeps this to code: health.sh's header comment mentions `pgrep -f`
# while explaining why the procd answer wins, and the first version of this
# guard matched that instead of the pattern.
PGREP_LINE="$(grep -nE '^[^#]*pgrep -f' "$RUNTIME/health.sh" | head -1)"
PROCD_LINE="$(grep -nE '^[^#]*procd_append_param command run' "$RUNTIME/service.sh" | head -1)"

if printf '%s' "$PGREP_LINE" | grep -q 'pgrep -f "run --config '; then
	pass "the pgrep fallback matches 'run --config <config>'"
else
	fail "the pgrep fallback no longer matches 'run --config <config>':"
	printf '      %s\n' "$PGREP_LINE"
fi

if printf '%s' "$PROCD_LINE" | grep -q 'procd_append_param command run --config '; then
	pass "procd is told to run 'run --config <config>'"
else
	fail "the procd command no longer starts with 'run --config':"
	printf '      %s\n' "$PROCD_LINE"
fi

echo
echo "== guard 10: nothing installs or removes packages on a target =="

# On 2026-09-15 an `apk add luci-app-homeproxy` on the test machine rewrote
# /etc/config/homeproxy from the feed package and destroyed the node
# configuration - six nodes plus the dns, server and subscription sections, with
# no backup and no snapshot. The suite stages instead, and this is the guard
# that keeps it that way: a package-manager *write* is never part of testing.
#
# Reading is fine and is used: tests/run.sh reports the target's installed
# version with `apk list -I`, and the opkg fallback reads `opkg status`.
# grep -v drops comment lines: this guard's own explanation quotes the command
# it forbids, and the first version flagged itself.
MUTATING="$(grep -rnE '(^|[^a-z-])(apk|opkg)[[:space:]]+(add|del|delete|remove|upgrade|fix|update)([[:space:]]|$)' \
	"$ROOT/.github/workflows" "$ROOT/tests" 2>/dev/null \
	| grep -vE ':[0-9]+:[[:space:]]*#' || true)"

if [ -z "$MUTATING" ]; then
	pass "no workflow or test runs a package-manager write"
else
	fail "a package-manager write appears - this is how the device config was lost:"
	printf '      %s\n' "$MUTATING"
fi

echo
echo "== guard 11: firewall_post.ut validates every UCI-derived field =="

# Three code-review findings rolled into one guard, because they share the
# same shape: any UCI value the template concatenates into an nft expression
# is an injection surface (closes a set expression, the whole fw4 reload
# fails, the router loses its firewall).  The defensive helpers exist; the
# guard exists so they cannot quietly stop being used.
TEMPLATE="$ROOT/root/etc/homeproxy/scripts/firewall_post.ut"
UTILS="$ROOT/root/etc/homeproxy/scripts/firewall_utils.uc"

if [ -f "$UTILS" ]; then
	pass "firewall_utils.uc exists (where the H1 validators live)"
else
	fail "firewall_utils.uc is missing - the H1 validators have nowhere to live"
fi

for fn in ipv4_to_nftarr mac_to_nftarr iface_to_nftarr ports_to_nftarr; do
	if grep -qE "^export function $fn\b" "$UTILS"; then
		pass "$fn is exported from firewall_utils.uc"
	else
		fail "$fn is not exported from firewall_utils.uc - the validator the report's H1 demands is missing"
	fi
done

# The template must actually import them - having the helpers but not using
# them would still leave a poisoned field landing in the nft output.
for fn in ipv4_to_nftarr mac_to_nftarr iface_to_nftarr ports_to_nftarr; do
	if grep -q "\b$fn\b" "$TEMPLATE"; then
		pass "firewall_post.ut imports/uses $fn"
	else
		fail "firewall_post.ut does not reference $fn"
	fi
done

# Every field type whose nft set/rule used to be raw `join(', ', control_info.X)`
# or `array_to_nftarr(control_info.X)` must now go through the matching helper.
# The names are taken from the helper function names; the field list is the
# closure of every control_info.X reference that ever appeared bare - kept as
# a literal so a new bare call site is obvious in a diff.
assert_empty "no bare array_to_nftarr(control_info.X) call site remains" \
	grep -nE 'array_to_nftarr\(control_info\.' "$TEMPLATE"
assert_empty "no bare join(', ', control_info.X) call site remains" \
	grep -nE "join\('\\. ', control_info\." "$TEMPLATE"
assert_empty "no bare join(', ', split(routing_port,...)) call site remains" \
	grep -nE "join\('\\. ', split\(routing_port" "$TEMPLATE"

# The four field families whose UCI surface area is the report's whole H1:
# IPv4 addresses, MAC addresses, interface names, and ports.  Any one of
# these landing verbatim in an nft expression closes a set and reloads the
# whole fw4 stack.  Asserted positively: each helper must be used on every
# field of its family, so a field the helper was meant to cover but the
# template forgot is a guard failure rather than a silent omission.
# (ipv6 is intentionally absent: it already had ipv6_to_nftarr before H1.)
#
# Field list is the exact set of control_info.<family> names used by the
# template - if a new field of an existing family is added, this list grows
# with it and the diff is the place to notice.
for f in wan_proxy_ipv4_ips wan_direct_ipv4_ips \
         lan_proxy_ipv4_ips lan_direct_ipv4_ips \
         lan_global_proxy_ipv4_ips lan_gaming_mode_ipv4_ips; do
	if grep -qE "ipv4_to_nftarr\(control_info\.$f\b" "$TEMPLATE"; then
		pass "ipv4_to_nftarr covers $f"
	else
		fail "ipv4_to_nftarr is not applied to $f (closes a nft set on a bad value)"
	fi
done

for f in lan_proxy_mac_addrs lan_direct_mac_addrs \
         lan_global_proxy_mac_addrs lan_gaming_mode_mac_addrs; do
	if grep -qE "mac_to_nftarr\(control_info\.$f\b" "$TEMPLATE"; then
		pass "mac_to_nftarr covers $f"
	else
		fail "mac_to_nftarr is not applied to $f (closes a nft set on a bad value)"
	fi
done

if grep -qE "iface_to_nftarr\(control_info\.listen_interfaces\b" "$TEMPLATE"; then
	pass "iface_to_nftarr covers listen_interfaces"
else
	fail "iface_to_nftarr is not applied to listen_interfaces"
fi

if grep -qE "ports_to_nftarr\(routing_port\b\)" "$TEMPLATE"; then
	pass "ports_to_nftarr covers routing_port"
else
	fail "ports_to_nftarr is not applied to routing_port"
fi

echo
echo "== guard 12: capabilities stay minimal =="

# Review H2: sing-box on this package runs in tproxy / TUN mode. Both rely
# on the kernel's packet path, not raw sockets, so CAP_NET_RAW is not needed;
# CAP_SYS_PTRACE lets any child process read arbitrary /proc/<pid>/mem, which
# on a process that handles untrusted network traffic is gratuitous attack
# surface.  Neither is granted anywhere.  inheritable is kept empty because
# nothing the orchestrator spawns needs to inherit caps.
CAPS="$ROOT/root/etc/capabilities/homeproxy.json"

if [ -f "$CAPS" ]; then
	pass "homeproxy.json exists"
else
	fail "homeproxy.json is missing"
fi

for cap in CAP_SYS_PTRACE CAP_NET_RAW CAP_SYS_ADMIN CAP_DAC_OVERRIDE CAP_SYS_MODULE CAP_SYS_RAWIO; do
	if grep -qE "\"$cap\"" "$CAPS"; then
		fail "$cap is granted somewhere - review H2 said this should be dropped"
	else
		pass "$cap is not granted"
	fi
done

# inheritable must be empty: every child process the orchestrator spawns
# is a shell / sh / helper that does not need elevated caps.
INHERITABLE="$(awk '/"inheritable"/,/]/' "$CAPS")"
if printf '%s' "$INHERITABLE" | grep -qE '"CAP_[A-Z_]+"'; then
	fail "inheritable is not empty:"
	printf '      %s\n' "$INHERITABLE"
else
	pass "inheritable is empty"
fi

# The two caps the package actually needs. Asserted positively so the
# check cannot pass by finding nothing.
for cap in CAP_NET_ADMIN CAP_NET_BIND_SERVICE; do
	if grep -qE "\"$cap\"" "$CAPS"; then
		pass "$cap is granted"
	else
		fail "$cap is missing - sing-box needs it for tproxy/TUN"
	fi
done

echo
echo "== guard 13: tests/run.sh has no guessed test host =="

# Review M1: tests/run.sh used to default HP_TEST_HOST to a specific LAN
# address, and tests/README.md repeated it.  Anyone cloning the repo and
# running `tests/run.sh` would have ssh'd into a stranger's box, with the
# whole checkout unpacked on top.  The default is now empty (SKIP), and
# the hardcoded IP is gone from tests/, .github/workflows/ and tests/README.md.
#
# Strip comment lines first: tests/README.md and the workflow headers
# legitimately mention the production-router IP in prose, and the workflow
# has an explicit refusal pattern that matches 192.168.1.1 to refuse it.
# Neither is a silent-connect.
strip_comments() {
	# `grep -v` of lines whose first non-whitespace character is `#`.
	awk '
		{
			s = $0
			sub(/^[[:space:]]+/, "", s)
			if (substr(s, 1, 1) != "#") print FILENAME ":" NR ":" $0
		}' "$1"
}

# The specific shape that was wrong: a literal ssh target in a HP_TEST_HOST
# default.  The empty default makes the suite skip instead.
BAD_DEFAULT="$(grep -nE 'HP_TEST_HOST[:=].*root@[0-9]' "$ROOT/tests/run.sh" \
	| strip_comments /dev/stdin || true)"
if [ -z "$BAD_DEFAULT" ]; then
	pass "tests/run.sh does not default HP_TEST_HOST to a hardcoded ssh host"
else
	fail "tests/run.sh defaults HP_TEST_HOST to a hardcoded ssh host - the silent-connect trap is back:"
	printf '      %s\n' "$BAD_DEFAULT"
fi

# The on-target.yml input default and the workflow-level host pinning.
# Same shape: a literal IP in the `host:` default or in a `HOST` env var.
BAD_INPUT="$(grep -nE "default:.*'[a-z]+@[0-9]" "$ROOT/.github/workflows/on-target.yml" \
	| strip_comments /dev/stdin || true)"
if [ -z "$BAD_INPUT" ]; then
	pass "on-target.yml input default is not a hardcoded ssh host"
else
	fail "on-target.yml input default is a hardcoded ssh host:"
	printf '      %s\n' "$BAD_INPUT"
fi

# The empty default is what makes the suite skip rather than silently
# connect to a guessed address.  Asserted positively so the check cannot
# pass by finding nothing.
if grep -q 'HOST="${HP_TEST_HOST:-}"' "$ROOT/tests/run.sh"; then
	pass "tests/run.sh defaults HP_TEST_HOST to empty (skip rather than connect)"
else
	fail "tests/run.sh no longer defaults HP_TEST_HOST to empty - the silent-connect trap is back"
fi

if grep -qE "default: ''" "$ROOT/.github/workflows/on-target.yml"; then
	pass "on-target.yml input default is empty"
else
	fail "on-target.yml input default is no longer empty - the workflow silently targets an IP again"
fi

echo
echo "== guard 14: wGETVerbose redacts the URL at the source =="

# Review H3: the original fetcher.uc logged a redacted URL but returned the
# raw wget stderr, which still had the full URL (wget -nv reports the target
# on the failure line, query string and all).  Every caller of wGETVerbose
# had to remember to redact the error themselves, and any that did not -
# silently leaked the subscription token.  The fix moved redaction into
# wGETVerbose itself, so the returned `error` is safe no matter where the
# caller ships it.
HOMEPROXY="$SCRIPTS/homeproxy.uc"
FETCHER="$SCRIPTS/subscription/fetcher.uc"

if grep -qE '^export function redactReason\b' "$HOMEPROXY"; then
	pass "redactReason is exported from homeproxy.uc"
else
	fail "redactReason is missing - the H3 redaction has no entry point"
fi

# wGETVerbose must call redactReason on the reason string before returning.
# Asserted positively so the check cannot pass by finding nothing (a regex
# in a comment would otherwise be enough to satisfy it).
# awk does not understand \b, so the function name pattern is anchored
# with `export function` and the opening paren instead.
WGET_BODY="$(awk '/^export function wGETVerbose/,/^};/' "$HOMEPROXY")"
if printf '%s' "$WGET_BODY" | grep -q 'redactReason(reason)'; then
	pass "wGETVerbose calls redactReason before returning"
else
	fail "wGETVerbose does not call redactReason on the reason - the token still leaks"
fi

# The fetcher used to do `redactUrl(url)` on the URL parameter *and* pass
# `result.error` (which carried the raw URL) into the log.  Now that
# wGETVerbose redacts internally, the fetcher must not double-process the
# error - it may still redact the URL parameter (it is the subscription
# token, distinct from the error), but must not touch result.error.
FETCHER_LOG="$(awk '/log\(sprintf.*Failed to fetch/,/\);$/' "$FETCHER")"
if printf '%s' "$FETCHER_LOG" | grep -qE "redactUrl\(result\.error"; then
	fail "subscription/fetcher.uc redacts result.error again - the redaction is now duplicated and result.error is meant to be already safe"
else
	pass "subscription/fetcher.uc does not re-redact result.error"
fi

echo
echo "== guard 15: every RPC whitelist uses index() === -1 ===="

# Review M6: the backend RPC module used two whitelisting spellings side by
# side (`x in [...]` and `index([...], x) === -1`).  They both work but the
# reader has to stop and confirm, and one of them silently behaves
# differently when the haystack is a string (it does substring matching
# instead of membership).  Pinning the rule to index() means a future method
# has to use the spelling the rest of the file uses.
# The exclusion list is the few legitimate `in` uses that are not array
# membership (object key checks, `for ... in ...` loops, etc.).
RPC="$ROOT/root/usr/share/rpcd/ucode/luci.homeproxy"

IN_ARR="$(grep -nE "\bin \['[^']+'(, '[^']+')+\]" "$RPC" \
	| grep -vE '^[^:]+:[^:]+:[[:space:]]*//|^[^:]+:[^:]+:[[:space:]]*\*' || true)"
if [ -z "$IN_ARR" ]; then
	pass "no array-membership 'in [...]' remains in luci.homeproxy"
else
	fail "array-membership 'in [...]' remains in luci.homeproxy - the report's M6 said unify on index():"
	printf '      %s\n' "$IN_ARR"
fi

# Each whitelisting call site must use index() === -1 (or !== -1 for the
# subset checks).  Asserted positively so the check cannot pass by finding
# nothing (a regex in a comment would otherwise be enough).
if grep -qE "index\(\[".*"\], req\.args\?\.type\) === -1" "$RPC"; then
	pass "luci.homeproxy uses index() === -1 for whitelist checks"
else
	fail "luci.homeproxy no longer uses index() === -1 for whitelist checks - did someone reintroduce the in-style?"
fi

echo
echo "== guard 16: every shell argument goes through shellQuote() =="

# Review M6: shellQuote() is the one helper that wraps an arbitrary string
# into single quotes that the shell cannot parse as syntax.  Every script
# argument that the shell sees has to come out of shellQuote(); the only
# exception is a literal constant with no interpolation.  Today the
# generators used string concatenation (`'rm -rf ' + tmp`), the rpcd
# module had a local lowercase `shellquote()` that the report caught, and
# one site interpolated `${req.args?.params}` raw.  This guard pins all of
# those to the imported shellQuote() so a future shell call cannot
# quietly escape the rule.
#
# The check walks every `system(...)` / `popen(...)` invocation under
# $SCRIPTS and the rpcd tree.  A call is "compliant" if it either:
#   (a) contains no `${...}` interpolation at all (literal command), or
#   (b) contains at least one `shellQuote(` call somewhere in its
#       arguments, so every interpolation goes through it.
# grep -E0 is unavailable; split the check into two passes so a compliant
# line is not double-counted.

# Pass 1: shell calls with no interpolation at all are fine.
SHELL_CALLS="$(grep -rEn '(^|[^A-Za-z_])(system|popen)\(' \
	"$SCRIPTS" "$RPC" 2>/dev/null \
	| grep -vE '/\*|^[^:]+:[^:]+:[[:space:]]*//' || true)"

# Pass 2: of those, lines that contain `${` (interpolation) must also
# contain `shellQuote(` somewhere in the same line.  ${} inside a string
# means the value reached the shell unquoted.
UNQUOTED="$(printf '%s\n' "$SHELL_CALLS" | python3 -c '
import sys, re
# Two styles reach the shell unquoted:
#   (a) template literal with `${someVar}`     - luci.homeproxy
#   (b) string concatenation `+ someVar +`     - the generator scripts
# A line is compliant if shellQuote() appears on it; both styles are
# caught with one rule because the helper is the same either way.
template = re.compile(r"\$\{[A-Za-z_]")
concat   = re.compile(r"\+ +[A-Za-z_][A-Za-z_0-9]*(?!\()")
quote    = re.compile(r"shellQuote\(")
for raw in sys.stdin:
    line = raw.rstrip("\n")
    # Strip the "<file>:<lineno>:" prefix the grep produced.
    body = line.split(":", 2)[2] if line.count(":") >= 2 else line
    if not (template.search(body) or concat.search(body)):
        continue
    if not quote.search(body):
        print(line)
')"

# Two exclusions the rule has to live with:
#   - update_subscriptions.uc uses sprintf() with shellQuote() arguments,
#     so `${shellQuote(x)}` is fine but the awk heuristic only sees it as
#     `${shellQuote(x)}` and considers it quoted.  sprintf() is a sibling
#     function that builds the command before passing it to system(); the
#     guard's grep on the source line therefore catches every other case
#     without needing to descend into sprintf.
#   - firewall_pre.uc writes nft fragments to disk rather than passing
#     them to a shell, so its system() calls only see literal commands.

if [ -z "$UNQUOTED" ]; then
	pass "every shell arg with \${...} interpolation goes through shellQuote()"
else
	fail "shell args with \${...} interpolation bypass shellQuote():"
	printf '      %s\n' "$UNQUOTED" | head -20
fi

# The local lowercase `shellquote()` placeholder must be gone - it shadows
# the imported shellQuote() and would silently no-op on a future call site.
LOWER="$(grep -rnE '\bshellquote\(' "$SCRIPTS" "$RPC" 2>/dev/null || true)"
if [ -z "$LOWER" ]; then
	pass "the local lowercase shellquote() placeholder is gone"
else
	fail "local lowercase shellquote() is still referenced - replace with the imported shellQuote():"
	printf '      %s\n' "$LOWER"
fi

echo
printf '%s checks, %s failures\n' "$checks" "$([ "$FAILED" = 0 ] && echo 0 || echo 'nonzero')"
if [ "$FAILED" != 0 ]; then
	echo "ARCHITECTURE GUARD FAILED"
	exit 1
fi

echo "ARCHITECTURE GUARD PASSED"
exit 0
