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
printf '%s checks, %s failures\n' "$checks" "$([ "$FAILED" = 0 ] && echo 0 || echo 'nonzero')"
if [ "$FAILED" != 0 ]; then
	echo "ARCHITECTURE GUARD FAILED"
	exit 1
fi

echo "ARCHITECTURE GUARD PASSED"
exit 0
