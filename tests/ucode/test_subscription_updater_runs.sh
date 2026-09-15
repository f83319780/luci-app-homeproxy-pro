#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# The subscription updater has to actually run.
#
# update_subscriptions.uc used to read subscription_urls and filter_keywords
# off access_control.subscription, while the Loader puts them on access_control
# itself.  Both came back [], so `if (!isEmpty(subscription_urls)) call(main)`
# was false: the script exited 0 having logged nothing, and both the LuCI
# "Update nodes from subscriptions" button and the cron entry were silent
# no-ops.  Nothing caught it because no test had ever executed main() - the
# repository test calls apply_nodes() directly, and the model test asserted the
# *correct* shape, which only made the consumer's wrong read look fine.
#
# So this test drives the real script end to end and asserts the one property
# that was missing: given a configured subscription URL, the updater must
# attempt an update and say something about the outcome.  The URL points at a
# closed port, so the attempt fails fast and main() returns before the
# `/etc/init.d/homeproxy reload` at its end - the device is not touched.
#
# Usage: sh tests/ucode/test_subscription_updater_runs.sh <repo-root> [workdir]

set -u

ROOT="$(cd "${1:-$(dirname "$0")/../..}" && pwd)"
WORK="${2:-/tmp/hp-updater-test}"

if ! command -v ucode > "/dev/null" 2>&1; then
	echo "NOT RUN: ucode is not on PATH."
	exit 2
fi

rm -rf "$WORK"
mkdir -p "$WORK/scripts" "$WORK/cfg" "$WORK/run"
cp -R "$ROOT/root/etc/homeproxy/scripts/." "$WORK/scripts/"

# Redirect the package's runtime dir into the sandbox so the test does not
# append to the device's live /var/run/homeproxy/homeproxy.log.
sed -e "s#^export const RUN_DIR = '/var/run/homeproxy';#export const RUN_DIR = '$WORK/run';#" \
    "$ROOT/root/etc/homeproxy/scripts/homeproxy.uc" > "$WORK/scripts/homeproxy.uc"

# Point the updater's Loader at the sandbox config.  Portable sed: write to a
# temp file and rename, so this works under both busybox and BSD sed.
sed "s#^const loaded = Loader.load();#const loaded = Loader.load('$WORK/cfg');#" \
	"$WORK/scripts/update_subscriptions.uc" > "$WORK/scripts/update_subscriptions.uc.new"
mv -f "$WORK/scripts/update_subscriptions.uc.new" "$WORK/scripts/update_subscriptions.uc"

cat > "$WORK/cfg/homeproxy" <<-EOF
	config homeproxy 'config'
		option routing_mode 'proxy'
		option main_node 'nil'

	config homeproxy 'subscription'
		option subscription_url 'https://127.0.0.1:1/never'
		option filter_nodes 'disabled'
		option auto_update '0'
EOF

LOGFILE="$WORK/run/homeproxy.log"

FAILED=0
if ( cd "$WORK/scripts" && ucode -L "$WORK/scripts" update_subscriptions.uc ) > "$WORK/stdout" 2>&1; then
	:
else
	echo "FAIL: update_subscriptions.uc exited non-zero"
	cat "$WORK/stdout"
	FAILED=1
fi

# The property under test: a configured URL means the updater must try.  Before
# the fix the log stayed empty because main() was never reached.
if [ -s "$LOGFILE" ]; then
	echo "PASS: the updater attempted an update and logged the outcome"
	sed 's/^/      /' "$LOGFILE"
else
	echo "FAIL: the updater logged nothing - main() was not reached, so the"
	echo "      subscription URL was read from the wrong level again"
	FAILED=1
fi

# And the log must name the failure rather than claim success.
if grep -q "Successfully updated subscriptions" "$LOGFILE" 2>/dev/null; then
	echo "FAIL: the updater reported success against an unreachable subscription"
	FAILED=1
fi

rm -rf "$WORK"

if [ "$FAILED" != 0 ]; then
	exit 1
fi

exit 0
