# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2025 ImmortalWrt.org
#
# fw4 integration for homeproxy (PR-05: PHASE 7 extraction).
#
# homeproxy owns a fixed set of nft chains and sets inside the `fw4` table.
# They are created by the rendered template (firewall_post.ut, applied by
# `fw4 reload`) and torn down one object at a time on stop.  All of that used
# to live inline in /etc/init.d/homeproxy.
#
# Layering note: this is a device-side module.  It calls `log` and, for the
# teardown, requires the HP_FW4_CHAINS / HP_FW4_SETS inventory to be in scope
# (root/etc/homeproxy/scripts/fw4_names.sh, sourced by init.d).
#
# Sourced by /etc/init.d/homeproxy.

# hp_restore_upnp_mappings
# fw4 reload rewrites the whole ruleset, which drops the miniupnpd mappings,
# so ask miniupnpd to reinstall them - but only when it is actually enabled
# and running.
hp_restore_upnp_mappings() {
	[ -x /etc/init.d/miniupnpd ] && /etc/init.d/miniupnpd enabled && /etc/init.d/miniupnpd running \
		&& /etc/init.d/miniupnpd restart >"/dev/null" 2>&1
}

# hp_firewall_apply <hp-dir> <run-dir> <client-enabled>
# Run the pre-script, render the post-template for the client side, reload
# fw4 and restore the upnp mappings.  <client-enabled> is "1" when a client
# outbound exists; the post-template is client-only.
hp_firewall_apply() {
	local hp_dir="$1"
	local run_dir="$2"
	local client_enabled="$3"

	ucode "$hp_dir/scripts/firewall_pre.uc" 2>"/dev/null" || log "Error: firewall pre-script failed."
	if [ "$client_enabled" = "1" ]; then
		utpl -S "$hp_dir/scripts/firewall_post.ut" > "$run_dir/fw4_post.nft" 2>"/dev/null" || log "Error: firewall post-script failed."
	fi
	fw4 reload >"/dev/null" 2>&1 || log "Error: fw4 reload failed."
	hp_restore_upnp_mappings
}

# hp_firewall_teardown <run-dir>
# Flush and delete every fw4 object homeproxy owns.  Deleting one at a time
# matters: `nft -f` batches are atomic, so a single object that does not
# exist in the current proxy mode would roll back the rest.
hp_firewall_teardown() {
	local run_dir="$1"
	local fw4_name

	for fw4_name in $HP_FW4_CHAINS; do
		nft flush chain inet fw4 "$fw4_name" 2>"/dev/null"
		nft delete chain inet fw4 "$fw4_name" 2>"/dev/null"
	done
	for fw4_name in $HP_FW4_SETS; do
		nft flush set inet fw4 "$fw4_name" 2>"/dev/null"
		nft delete set inet fw4 "$fw4_name" 2>"/dev/null"
	done

	: > "$run_dir/fw4_forward.nft"
	: > "$run_dir/fw4_input.nft"
	: > "$run_dir/fw4_post.nft"

	fw4 reload >"/dev/null" 2>&1 || log "Warning: fw4 reload failed during stop."
	hp_restore_upnp_mappings
}
