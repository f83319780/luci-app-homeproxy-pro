#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Runtime configuration-transaction tests.
#
# These cover the pieces init.d/homeproxy relies on so that a bad
# configuration cannot leave the router without a working service:
#
#   * the known-good copy recorded after a configuration passed check
#   * the fallback to that copy when a regeneration produces nothing
#   * the rollback after a reload that comes up unhealthy
#   * the health probe that decides whether a rollback is needed
#
# The helpers are pure shell on purpose (see scripts/runtime/), so this runs
# anywhere, without ucode, procd or a router.
#
# Usage: sh tests/runtime/test_config_transaction.sh <repo-root>

ROOT="${1:-.}"
ROOT="$(cd "$ROOT" && pwd)"
RUNTIME="$ROOT/root/etc/homeproxy/scripts/runtime"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hp-runtime.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM

FAILED=0
CHECKS=0
FAILURES=0

expect() {
	# expect <name> <actual> <expected>
	CHECKS=$((CHECKS + 1))
	if [ "$2" = "$3" ]; then
		echo "PASS: $1"
	else
		echo "FAIL: $1 (expected '$3', got '$2')"
		FAILED=1
		FAILURES=$((FAILURES + 1))
	fi
}

if [ ! -f "$RUNTIME/config.sh" ] || [ ! -f "$RUNTIME/health.sh" ]; then
	echo "FAIL: runtime helpers are missing under $RUNTIME"
	exit 1
fi

# shellcheck source=/dev/null
. "$RUNTIME/config.sh"
# shellcheck source=/dev/null
. "$RUNTIME/health.sh"

LIVE="$WORK/run/sing-box-c.json"
GOOD="$WORK/run/known-good/sing-box-c.json"

echo "== config transaction =="

# Nothing generated yet and no fallback: unusable.
hp_ensure_live "$LIVE" "$GOOD"
expect "ensure_live: nothing usable" "$?" "2"

# A configuration that passed check becomes the known-good copy.
mkdir -p "$WORK/run"
printf 'v1\n' > "$LIVE"
hp_known_good "$LIVE" "$GOOD"
expect "known_good: recorded" "$?" "0"
expect "known_good: content" "$(cat "$GOOD")" "v1"

# Live file present -> ensure_live leaves it alone.
hp_ensure_live "$LIVE" "$GOOD"
expect "ensure_live: keeps the live file" "$?" "0"

# Generation failed and removed the live file -> restore the fallback.  This
# is the start-up path: without it a failed generation left the router with
# no configuration at all.
rm -f "$LIVE"
hp_ensure_live "$LIVE" "$GOOD"
expect "ensure_live: restores the fallback" "$?" "1"
expect "ensure_live: restored content" "$(cat "$LIVE")" "v1"

# A new configuration that passes check but is not yet proven: the fallback
# still holds the previous one.
printf 'v2\n' > "$LIVE"
hp_same_file "$LIVE" "$GOOD"
expect "same_file: different configs" "$?" "1"
hp_rollback "$LIVE" "$GOOD"
expect "rollback: applied" "$?" "0"
expect "rollback: previous content restored" "$(cat "$LIVE")" "v1"
hp_same_file "$LIVE" "$GOOD"
expect "same_file: identical configs" "$?" "0"

# Nothing to roll back to must be reported, not silently ignored.
rm -f "$GOOD"
hp_rollback "$LIVE" "$GOOD"
expect "rollback: refuses without a fallback" "$?" "1"
hp_same_file "$LIVE" "$GOOD"
expect "same_file: missing file is not equal" "$?" "1"

echo "== health probe =="

# Deterministic stubs so the probe's control flow is tested rather than the
# host's process table or a real service.  ubus/jsonfilter are stubbed too:
# on a router they exist and would otherwise report the *real* homeproxy
# instance, which has nothing to do with this fixture.
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/pgrep" <<'STUB'
#!/bin/sh
[ "${HP_FAKE_RUNNING:-0}" = "1" ]
STUB
cat > "$BIN/ubus" <<'STUB'
#!/bin/sh
echo '{}'
STUB
cat > "$BIN/jsonfilter" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod +x "$BIN/pgrep" "$BIN/ubus" "$BIN/jsonfilter"
PATH="$BIN:$PATH"
export PATH

CFG="$WORK/run/sing-box-c.json"
: > "$CFG"

HP_FAKE_RUNNING=0
export HP_FAKE_RUNNING
hp_instance_running "sing-box-c" "$CFG"
expect "instance_running: reports down" "$?" "1"

HP_FAKE_RUNNING=1
hp_instance_running "sing-box-c" "$CFG"
expect "instance_running: reports up" "$?" "0"

hp_wait_instance "sing-box-c" "$CFG" 1
expect "wait_instance: succeeds while running" "$?" "0"

HP_FAKE_RUNNING=0
hp_wait_instance "sing-box-c" "$CFG" 1
expect "wait_instance: times out when down" "$?" "1"

printf '%d checks, %d failures\n' "$CHECKS" "$FAILURES"
exit $FAILED
