# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2025 ImmortalWrt.org
#
# dnsmasq integration for homeproxy (PR-05: PHASE 7 extraction).
#
# homeproxy does not run its own DNS front end: it points dnsmasq at the
# sing-box DNS listener and, in the list-based routing modes, feeds it the
# per-domain `server=` / `nftset=` mappings.  All of that used to live inline
# in /etc/init.d/homeproxy.
#
# Layering note: this is a device-side module.  It calls `log` and, in
# hp_dnsmasq_write_snippets, relies on `config_load` having run (see
# runtime/service.sh's header for the rationale).
#
# Sourced by /etc/init.d/homeproxy.

# hp_dnsmasq_resolve_dir
# Locate the directory dnsmasq reads the homeproxy snippets from and store it
# in the global DNSMASQ_DIR.
#
# The UCI section name of the dnsmasq config is part of
# /tmp/etc/dnsmasq.conf.<name>, but `uci get` cannot return a section name
# (there is no `__name__`), so it is derived from the first `uci show` line.
# Either step can fail on an unusual setup; fall back to the generic
# directory and say so in the log instead of silently writing dnsmasq
# snippets nobody reads.
#
# Called ONCE, at source time.  stop_service deliberately reuses the value
# instead of recomputing it: the directory must be the one the snippets were
# written to, and a second resolution could log the warning twice or pick a
# different directory after a dnsmasq reconfiguration.
hp_dnsmasq_resolve_dir() {
	local dnsmasq_uci_config dnsmasq_conf_dir

	dnsmasq_uci_config="$(uci -q show "dhcp.@dnsmasq[0]" 2>"/dev/null" | head -n1)"
	dnsmasq_uci_config="${dnsmasq_uci_config#*.}"
	dnsmasq_uci_config="${dnsmasq_uci_config%%=*}"

	DNSMASQ_DIR=""
	if [ -n "$dnsmasq_uci_config" ] && [ -f "/tmp/etc/dnsmasq.conf.$dnsmasq_uci_config" ]; then
		dnsmasq_conf_dir="$(awk -F '=' '/^conf-dir=/ {print $2; exit}' "/tmp/etc/dnsmasq.conf.$dnsmasq_uci_config")"
		[ -n "$dnsmasq_conf_dir" ] && DNSMASQ_DIR="$dnsmasq_conf_dir/dnsmasq-homeproxy.d"
	fi

	if [ -z "$DNSMASQ_DIR" ]; then
		log "WARNING: unable to derive the dnsmasq conf-dir (section '${dnsmasq_uci_config:-unknown}'), using /tmp/dnsmasq.d/dnsmasq-homeproxy.d."
		DNSMASQ_DIR="/tmp/dnsmasq.d/dnsmasq-homeproxy.d"
	fi
}

# hp_dnsmasq_write_snippets <dns-dir> <hp-dir> <routing-mode>
# Write the include file plus the mode-specific snippet, then restart
# dnsmasq.  Requires config_load (reads ipv6_support and dns_port).
hp_dnsmasq_write_snippets() {
	local dnsmasq_dir="$1"
	local hp_dir="$2"
	local routing_mode="$3"
	local ipv6_support dns_port gfw_nftset_v6 wan_nftset_v6

	config_get_bool ipv6_support "config" "ipv6_support" "0"
	config_get dns_port "infra" "dns_port" "5333"

	mkdir -p "$dnsmasq_dir" || log "Warning: failed to create ${dnsmasq_dir}."
	echo -e "conf-dir=$dnsmasq_dir" > "$dnsmasq_dir/../dnsmasq-homeproxy.conf" \
		|| log "Warning: failed to write the dnsmasq conf-dir file."

	case "$routing_mode" in
	"bypass_mainland_china"|"custom"|"global")
		cat <<-EOF > "$dnsmasq_dir/redirect-dns.conf"
			no-poll
			no-resolv
			server=127.0.0.1#$dns_port
		EOF
		;;
	"gfwlist")
		[ "$ipv6_support" -eq "0" ] || gfw_nftset_v6=",6#inet#fw4#homeproxy_gfw_list_v6"
		sed -r -e "s/(.*)/server=\/\1\/127.0.0.1#$dns_port\nnftset=\/\1\\/4#inet#fw4#homeproxy_gfw_list_v4$gfw_nftset_v6/g" \
			"$hp_dir/resources/gfw_list.txt" > "$dnsmasq_dir/gfw_list.conf"
		;;
	"proxy_mainland_china")
		sed -r -e "s/(.*)/server=\/\1\/127.0.0.1#$dns_port/g" \
			"$hp_dir/resources/china_list.txt" > "$dnsmasq_dir/china_list.conf"
		;;
	esac

	if [ "$routing_mode" != "custom" ] && [ -s "$hp_dir/resources/proxy_list.txt" ]; then
		[ "$ipv6_support" -eq "0" ] || wan_nftset_v6=",6#inet#fw4#homeproxy_wan_proxy_addr_v6"
		sed -r -e '/^\s*$/d' -e "s/(.*)/server=\/\1\/127.0.0.1#$dns_port\nnftset=\/\1\\/4#inet#fw4#homeproxy_wan_proxy_addr_v4$wan_nftset_v6/g" \
			"$hp_dir/resources/proxy_list.txt" > "$dnsmasq_dir/proxy_list.conf"
	fi

	/etc/init.d/dnsmasq restart >"/dev/null" 2>&1 \
		|| log "Warning: failed to restart dnsmasq, DNS-based routing may be stale."
}

# hp_dnsmasq_remove_snippets <dns-dir>
# Remove the include file and the snippet directory, then restart dnsmasq.
# The snippets are removed rather than restored: nothing ever captures the
# pre-existing state, so there is no original to put back.
hp_dnsmasq_remove_snippets() {
	local dnsmasq_dir="$1"

	rm -rf "$dnsmasq_dir/../dnsmasq-homeproxy.conf" "$dnsmasq_dir"
	/etc/init.d/dnsmasq restart >"/dev/null" 2>&1 \
		|| log "Warning: failed to restart dnsmasq after removing the homeproxy snippets."
}
