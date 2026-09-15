/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Stage PHASE 4 of the architecture refactor (see
 * homeproxy_architecture_refactor_agent_guide.md):
 *
 *     generator/inbound.uc: build the sing-box `inbounds` block.
 *
 * The client always needs the dns-in and mixed-in inbounds, plus
 * whichever of redirect-in / tproxy-in / tun-in matches proxy_mode.
 * udp_* fields on tproxy-in and tun-in come from the same UCI settings
 * (a single source of truth in init.d, but the orchestrator extracts
 * them and re-shapes them for sing-box here).
 */

'use strict';

import { isEmpty, strToInt, strToTime, strToBool } from '../homeproxy.uc';

/* Append the always-on inbounds. dns-in is the local UDP listener the
 * DNS chain hands queries to; mixed-in is the SOCKS/HTTP listener the
 * LAN redirects into. Their order matters because dns-in has to come
 * first when sing-box matches inbounds in declaration order. */
function pushBaseInbounds(inbounds, ctx) {
	push(inbounds, {
		type: 'direct',
		tag: 'dns-in',
		listen: '::',
		listen_port: int(ctx.dns_port)
	});

	push(inbounds, {
		type: 'mixed',
		tag: 'mixed-in',
		listen: '::',
		listen_port: int(ctx.mixed_port),
		udp_timeout: strToTime(ctx.udp_timeout),
		set_system_proxy: false
	});
}

/* --- public entry ------------------------------------------------------ */

/* Build the sing-box `inbounds` block. The caller supplies an empty
 * array on `config.inbounds` so this can be a pure builder. */
export function build_inbounds(config, ctx) {
	const inbounds = config.inbounds || [];

	pushBaseInbounds(inbounds, ctx);

	if (match(ctx.proxy_mode, /redirect/))
		push(inbounds, {
			type: 'redirect',
			tag: 'redirect-in',

			listen: '::',
			listen_port: int(ctx.redirect_port)
		});

	if (match(ctx.proxy_mode, /tproxy/))
		push(inbounds, {
			type: 'tproxy',
			tag: 'tproxy-in',

			listen: '::',
			listen_port: int(ctx.tproxy_port),
			network: 'udp',
			udp_timeout: strToTime(ctx.udp_timeout),
			udp_mapping: !isEmpty(ctx.udp_mapping) ? ctx.udp_mapping : null,
			udp_filtering: !isEmpty(ctx.udp_filtering) ? ctx.udp_filtering : null,
			udp_nat_max: ctx.udp_nat_max,
		});

	if (match(ctx.proxy_mode, /tun/))
		push(inbounds, {
			type: 'tun',
			tag: 'tun-in',

			interface_name: ctx.tun_name,
			address: (ctx.ipv6_support === '1') ? [ctx.tun_addr4, ctx.tun_addr6] : [ctx.tun_addr4],
			mtu: strToInt(ctx.tun_mtu),
			auto_route: false,
			endpoint_independent_nat: strToBool(ctx.endpoint_independent_nat),
			udp_timeout: strToTime(ctx.udp_timeout),
			dns_mode: !isEmpty(ctx.tun_dns_mode) ? ctx.tun_dns_mode : null,
			dns_address: !isEmpty(ctx.tun_dns_address) ? ctx.tun_dns_address : null,
			udp_mapping: !isEmpty(ctx.udp_mapping) ? ctx.udp_mapping : null,
			udp_filtering: !isEmpty(ctx.udp_filtering) ? ctx.udp_filtering : null,
			udp_nat_max: ctx.udp_nat_max,
			stack: ctx.tcpip_stack,
		});

	config.inbounds = inbounds;
	return config;
};