# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2025 ImmortalWrt.org
#
# Runtime health helpers for homeproxy.
#
# After a reload the service must be able to answer "did the instance
# actually come up with the new configuration?".  That answer decides whether
# the transaction in runtime/config.sh rolls back, so it is kept here instead
# of being inlined in init.d/homeproxy.
#
# Sourced by /etc/init.d/homeproxy; testable off-target by stubbing pgrep (see
# tests/runtime/test_config_transaction.sh).

: "${HP_SERVICE:=homeproxy}"

# hp_instance_running <instance-name> <config-path>
# 0 when the instance has a live process.
#
# The process check comes first: procd reports through ubus, which lags a
# respawn by a moment, and a false negative here would trigger a needless
# rollback.  The ubus query is only a second opinion.
hp_instance_running() {
	name="$1"
	config="$2"

	if command -v pgrep > "/dev/null" 2>&1; then
		pgrep -f "run --config $config" > "/dev/null" 2>&1 && return 0
	fi

	if command -v ubus > "/dev/null" 2>&1 && command -v jsonfilter > "/dev/null" 2>&1; then
		state="$(ubus call service list "{\"name\":\"$HP_SERVICE\"}" 2>"/dev/null" \
			| jsonfilter -e "@['$HP_SERVICE'].instances['$name'].running" 2>"/dev/null")"
		[ "$state" = "true" ] && return 0
	fi

	return 1
}

# hp_wait_instance <instance-name> <config-path> [seconds]
# Poll hp_instance_running for up to [seconds] (default 10).
hp_wait_instance() {
	name="$1"
	config="$2"
	tries="${3:-10}"

	while [ "$tries" -gt 0 ]; do
		hp_instance_running "$name" "$config" && return 0
		sleep 1
		tries=$((tries - 1))
	done

	return 1
}
