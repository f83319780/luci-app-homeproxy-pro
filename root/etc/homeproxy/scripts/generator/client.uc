/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Stage PHASE 4 of the architecture refactor (see
 * homeproxy_architecture_refactor_agent_guide.md):
 *
 *     generator/client.uc: client-side orchestrator.
 *
 * This file is the only place the client generator still knows the
 * overall shape. Each section builder lives in its own module under
 * generator/; this file glues them together.
 *
 *     generate(dm)
 *         -> build_dns
 *         -> build_inbounds
 *         -> build_outbounds (mutates direct_overrides)
 *         -> build_route
 *         -> build_user_rulesets (custom mode only)
 *         -> build_http_clients
 *         -> attachSchema, attachExperimental
 *         -> final config object (caller writes + sing-box check)
 *
 * Every section builder takes (config, ctx, ...) where `ctx` carries
 * the routing-mode- and proxy-mode-derived scalars (main_node,
 * dns_server, proxy_mode, ...) plus the mutable accumulators (outbounds,
 * endpoints, ...) the builders append to. The orchestrator owns them
 * and threads them through, which is what kept the original
 * generate_client.uc at 1240 lines: a 1100-line config blob with a
 * single closure scope.
 *
 * The output is the final config object: no `$schema`, no atomic write,
 * no `sing-box check`. The 10-line CLI shell (`scripts/generate_client.uc`)
 * is responsible for those - per the architecture guide, the generator
 * must not double as the runner.
 */

'use strict';

import { connect } from 'ubus';
import { readfile } from 'fs';

import { isEmpty, strToInt, RUN_DIR, HP_DIR } from 'homeproxy';

import { build_dns } from './dns.uc';
import { build_inbounds } from './inbound.uc';
import { build_outbounds } from './outbound.uc';
import { build_route } from './route.uc';
import { build_user_rulesets, build_http_clients } from './ruleset.uc';
import { attachSchema, attachExperimental } from './common.uc';

const ubus = connect();

/* Resolve the WAN DNS server address used as the default-dns upstream.
 *
 * ubus may be unreachable (no ubusd, or a dev host); the caller falls
 * back to a public resolver below, which is also what a router without
 * a WAN lease uses. The extra parentheses keep the ?. chain guarded
 * when ubus is null. */
function resolve_wan_dns(routing_mode) {
	let wan_dns = (ubus?.call('network.interface', 'status', {'interface': 'wan'}))?.['dns-server']?.[0];
	if (!wan_dns)
		wan_dns = (routing_mode in ['proxy_mainland_china', 'global']) ? '8.8.8.8' : '223.5.5.5';
	return wan_dns;
}

/* Build the routing-mode-independent ctx the section builders consume.
 * Mode-dependent defaults are filled in here so each builder can stay a
 * straight consumer of its fields without recomputing them. */
function build_ctx(dm) {
	const routing_mode = dm.general.routing_mode || 'bypass_mainland_china';
	const proxy_mode = dm.general.proxy_mode || 'redirect_tproxy';

	/* Mode-shared scalars */
	const ipv6_support = dm.general.ipv6_support || '0';
	const log_level = dm.general.log_level || 'warn';
	const ntp_server = dm.infra.ntp_server || 'time.apple.com';
	const dns_port = dm.infra.dns_port || '5333';
	const mixed_port = dm.infra.mixed_port || '5330';
	const udp_timeout = (routing_mode === 'custom')
		? (dm.routing.settings.udp_timeout)
		: dm.infra.udp_timeout;

	/* self_mark is intentionally null for proxy_mode 'tun' only:
	 * the DNS server detour (default-dns / system-dns / china-dns) is
	 * gated on it, and the old generator kept the same code shape -
	 * any non-empty string is truthy, so the test fixture's
	 * self_mark='100' would leak a 'detour: direct-out' onto every
	 * DNS server when proxy_mode is tun. removeBlankAttrs() then
	 * strips the null detour, so the generated JSON stays identical
	 * to the pre-refactor output. */
	const self_mark = match(proxy_mode, /redirect/)
		? (dm.infra.self_mark || '100') : null;

	/* proxy-mode-derived ports / TUN params */
	let redirect_port, tproxy_port, tun_name, tun_addr4, tun_addr6,
	    tun_mtu, tcpip_stack, endpoint_independent_nat;
	if (match(proxy_mode, /redirect/))
		redirect_port = dm.infra.redirect_port || '5331';
	if (match(proxy_mode, /tproxy/))
		if ((dm.general.main_udp_node || 'nil') !== 'nil' || routing_mode === 'custom')
			tproxy_port = dm.infra.tproxy_port || '5332';
	if (match(proxy_mode, /tun/)) {
		tun_name = dm.infra.tun_name || 'singtun0';
		tun_addr4 = dm.infra.tun_addr4 || '172.19.0.1/30';
		tun_addr6 = dm.infra.tun_addr6 || 'fdfe:dcba:9876::1/126';
		tun_mtu = dm.infra.tun_mtu || '9000';
		tcpip_stack = 'system';
		if (routing_mode === 'custom') {
			tcpip_stack = dm.routing.settings.tcpip_stack || 'system';
			endpoint_independent_nat = dm.routing.settings.endpoint_independent_nat;
		}
	}

	const wan_dns = resolve_wan_dns(routing_mode);

	/* dns/routing fields used by both sections */
	const dns_optimistic_cache = (dm.dns.settings || {}).optimistic_cache || '0';
	const dns_optimistic_timeout = (dm.dns.settings || {}).optimistic_timeout;
	const dns_query_timeout = (dm.dns.settings || {}).dns_timeout;
	const dns_store_dns = (dm.dns.settings || {}).cache_file_store_dns || '0';

	const tun_dns_mode_raw = dm.general.tun_dns_mode,
	      tun_dns_address = dm.general.tun_dns_address,
	      udp_mapping_raw = dm.general.udp_mapping,
	      udp_filtering_raw = dm.general.udp_filtering,
	      udp_nat_max = strToInt(dm.general.udp_nat_max);

	const tun_dns_mode = (tun_dns_mode_raw === 'default') ? '' : tun_dns_mode_raw,
	      udp_mapping = (udp_mapping_raw === 'default') ? '' : udp_mapping_raw,
	      udp_filtering = (udp_filtering_raw === 'default') ? '' : udp_filtering_raw;

	/* Routing-mode-dependent defaults */
	const ctx = {
		routing_mode, proxy_mode, ipv6_support, log_level,
		self_mark, ntp_server, dns_port, mixed_port,
		redirect_port, tproxy_port,
		tun_name, tun_addr4, tun_addr6, tun_mtu,
		tcpip_stack, endpoint_independent_nat,
		udp_timeout, udp_mapping, udp_filtering, udp_nat_max,
		tun_dns_mode, tun_dns_address,
		wan_dns, dns_optimistic_cache, dns_optimistic_timeout,
		dns_query_timeout, dns_store_dns,
		default_interface: (dm.access_control.control || {}).bind_interface,

		/* udp/tcp shaping knobs the endpoint builder reads */
		endpoint_options: {
			udp_mapping, udp_filtering, udp_nat_max
		},

		/* Routing-mode-specific scalars; the dns/route modules consult
		 * only the fields their branch needs. */
		main_node: dm.general.main_node,
		main_udp_node: dm.general.main_udp_node,
		default_outbound: (dm.routing.settings || {}).default_outbound,
		default_outbound_dns: (dm.routing.settings || {}).default_outbound_dns || 'default-dns',
		domain_strategy: (dm.routing.settings || {}).domain_strategy,
		find_neighbor: (dm.routing.settings || {}).find_neighbor,

		/* Main-line defaults. The DNS server fallbacks mirror what the
	 * pre-refactor generate_client.uc did inline: an empty UCI value
	 * becomes 'wan' for the main DNS server, which is itself turned
	 * into the WAN resolver below; the China DNS server falls back
	 * to the Aliyun public resolver instead of leaking into the
	 * default-dns pipeline. Both branches are exercised by the
	 * client fixture. */
		dns_server: dm.general.dns_server || 'wan',
		china_dns_server: (dm.general.china_dns_server && dm.general.china_dns_server !== 'wan')
			? dm.general.china_dns_server : '223.5.5.5',
		/* dns_default_strategy: in proxy mode, ipv4_only is the safe
		 * default whenever ipv6_support is off; in custom mode the
		 * UCI default_strategy field is the source of truth (no
		 * implicit fallback - missing UCI => strategy: null =>
		 * removeBlankAttrs strips it). */
		dns_default_strategy: (routing_mode === 'custom')
			? (dm.dns.settings || {}).default_strategy
			: ((ipv6_support !== '1') ? 'ipv4_only' : null),
		cn_ip_fallback: dm.general.cn_ip_fallback,
		main_urltest_nodes: dm.general.main_urltest_nodes || [],
		main_urltest_interval: dm.general.main_urltest_interval,
		main_urltest_tolerance: dm.general.main_urltest_tolerance,
		main_udp_urltest_nodes: dm.general.main_udp_urltest_nodes || [],
		main_udp_urltest_interval: dm.general.main_udp_urltest_interval,
		main_udp_urltest_tolerance: dm.general.main_udp_urltest_tolerance,

		/* Custom-mode DNS settings */
		dns_default_server: (dm.dns.settings || {}).default_server,
		dns_disable_cache: (dm.dns.settings || {}).disable_cache,
		dns_disable_cache_expire: (dm.dns.settings || {}).disable_cache_expire,
		dns_client_subnet: (dm.dns.settings || {}).client_subnet,

		/* Mutable accumulators threaded through every builder */
		/* (kept here so the ctx shape is unchanged across builds; the
		 * actual mutation happens on config.outbounds / config.endpoints
		 * directly so the JSON key order stays stable. */
	};

	/* Inline static rule-sets (direct-domain, proxy-domain) only fire
	 * when the routing mode has a non-empty domain list. Both lists are
	 * loaded once into ctx so the dns and route builders share them.
	 * The files live at /etc/homeproxy/resources/; the path is exposed
	 * via HP_DIR (homeproxyuc) so this code does not hard-code it. */
	ctx.direct_domain_list = [];
	ctx.proxy_domain_list = [];
	if (routing_mode !== 'custom') {
		const direct_list_raw = readfile(HP_DIR + '/resources/direct_list.txt');
		ctx.direct_domain_list = direct_list_raw ? split(trim(direct_list_raw), /[\r\n]/) : [];

		const proxy_list_raw = readfile(HP_DIR + '/resources/proxy_list.txt');
		ctx.proxy_domain_list = proxy_list_raw ? split(trim(proxy_list_raw), /[\r\n]/) : [];
	}

	/* `dedicated_udp_node` means main_udp_node was set to a different
	 * proxy-able node than main_node (the 'same'/'nil' sentinels don't
	 * qualify). Kept on ctx so both build_outbounds and build_route
	 * see the same value. */
	ctx.dedicated_udp_node = !isEmpty(ctx.main_udp_node) && !(ctx.main_udp_node in ['same', ctx.main_node]);

	return ctx;
}

/* --- public entry ------------------------------------------------------ */

/* Build the sing-box client config object. Pure function: takes the
 * HomeProxyConfig from the Loader, returns the JSON object the caller
 * writes and `sing-box check`s. No UCI, no file I/O, no procd. */
export function generate(dm) {
	const ctx = build_ctx(dm);

	const config = {
		log: {
			disabled: false,
			level: ctx.log_level,
			output: RUN_DIR + '/sing-box-c.log',
			timestamp: true
		}
	};

	if (!isEmpty(ctx.ntp_server))
		config.ntp = {
			enabled: true,
			server: ctx.ntp_server,
			detour: 'direct-out',
			domain_resolver: 'default-dns',
		};

	/* `direct_overrides` is the single side effect that survives the
	 * split: a direct node with override_address / override_port
	 * records the override here so build_route can emit the
	 * route-options action later. The orchestrator owns the map and
	 * passes it to both builders. */
	const direct_overrides = {};

	build_dns(config, dm, ctx);
	build_inbounds(config, ctx);

	/* direct_outbounds live on config.outbounds regardless of mode:
	 * the DNS path always references them, and a custom-mode config
	 * without any direct-out/block-out would not have a fallback for
	 * a routing rule that emits a missing tag. Initialised AFTER
	 * build_dns / build_inbounds so the JSON key order is
	 * log, ntp, dns, inbounds, outbounds, ... matching the
	 * pre-refactor generator. The builder appends to the same array
	 * (no reassignment), which preserves the key order that
	 * removeBlankAttrs() emits and keeps golden snapshots stable. */
	config.outbounds = [
		{
			type: 'direct',
			tag: 'direct-out',
			routing_mark: strToInt(ctx.self_mark)
		},
		{
			type: 'block',
			tag: 'block-out'
		}
	];
	config.endpoints = [];

	build_outbounds(config, dm, ctx, direct_overrides);
	build_route(config, dm, ctx, direct_overrides);

	/* User-defined rulesets are custom-mode only; passing an empty
	 * dm.routing.rulesets through build_user_rulesets is a no-op
	 * because every cfg in it is filtered by !cfg.enabled (PR-01). */
	if (ctx.routing_mode === 'custom')
		build_user_rulesets(config.route.rule_set, dm, ctx);

	const http_clients = build_http_clients(config.route.rule_set, dm, ctx);
	if (length(http_clients))
		config.http_clients = http_clients;

	if (isEmpty(config.route.rule_set))
		config.route.rule_set = null;
	if (isEmpty(config.endpoints))
		config.endpoints = null;

	attachExperimental(config, ctx.routing_mode, ctx.dns_store_dns);
	attachSchema(config);

	return config;
};