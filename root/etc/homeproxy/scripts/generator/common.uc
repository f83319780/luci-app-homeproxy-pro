/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Stage PHASE 4 of the architecture refactor (see
 * homeproxy_architecture_refactor_agent_guide.md):
 *
 *     generator/common.uc: shared helpers used by every generator module.
 *
 * Every "select a tag from a UCI-style reference" function lives in this
 * file because the same selector logic (a routing_node name, an
 * array-of-names, a direct/block/default marker, a ruleset id list) is
 * reached by the DNS section, the route section, the outbound/endpoint
 * builder and the ruleset section. Duplicating them per-module would
 * drift; consolidating them here keeps the convention "one place to
 * change a tag shape".
 *
 * The Loader owns UCI; nothing in here reads UCI directly. The orchestrator
 * passes `dm` for the routing_node lookups that need to resolve a name into
 * the underlying node id.
 */

'use strict';

import { isEmpty } from 'homeproxy';

import { ConfigQuery } from '../config/model.uc';

/* Parse the comma-separated port list UCI emits for source_port / port
 * rule fields. A single value comes through as a string, a list as an
 * array of strings; both forms are normalised into an array of integers
 * (or null when the field is empty). */
export function parse_port(strport) {
	if (type(strport) !== 'array' || isEmpty(strport))
		return null;

	let ports = [];
	for (let i in strport)
		push(ports, int(i));

	return ports;
}

/* Resolve a UCI outbound-style reference (string or array of strings)
 * into the sing-box tag the generator should emit. The arrays carry
 * either 'block-out' / 'direct-out' / 'any-out' sentinels or routing_node
 * section names; a single string is the same thing with one entry.
 *
 * `dm` is needed for the routing_node -> node id lookup; we deliberately
 * do not read `dm.routing.nodes` until we know we need it (the common
 * case is the sentinel). */
export function get_outbound(cfg, dm) {
	if (isEmpty(cfg))
		return null;

	if (type(cfg) === 'array') {
		if ('any-out' in cfg)
			return 'any';

		let outbounds = [];
		for (let i in cfg)
			push(outbounds, get_outbound(i, dm));
		return outbounds;
	}

	switch (cfg) {
	case 'block-out':
	case 'direct-out':
		return cfg;
	default:
		const rn = ConfigQuery.find_by_name(dm.routing.nodes, cfg);
		if (!rn || isEmpty(rn.node))
			die(sprintf("%s's node is missing, please check your configuration.", cfg));
		else if (rn.node === 'urltest')
			return 'cfg-' + cfg + '-out';
		else
			return 'cfg-' + rn.node + '-out';
	}
}

/* Resolve a UCI resolver reference (a dns_server section name or one of
 * the sentinels) into a sing-box resolver tag. */
export function get_resolver(cfg) {
	if (isEmpty(cfg))
		return null;

	switch (cfg) {
	case 'default-dns':
	case 'system-dns':
		return cfg;
	default:
		return 'cfg-' + cfg + '-dns';
	}
}

/* Resolve a UCI ruleset reference list (array of ruleset section names)
 * into the corresponding sing-box rule_set tag list. */
export function get_ruleset(cfg) {
	if (isEmpty(cfg))
		return null;

	let rules = [];
	for (let i in cfg)
		push(rules, isEmpty(i) ? null : 'cfg-' + i + '-rule');
	return rules;
}

/* Resolve the direct-node destination override that the route builder
 * needs for a `direct` routing_node target. The override is recorded
 * earlier by generate_outbound() (see outbound.uc) when a direct node
 * carries override_address / override_port; this helper just looks it
 * up. Returns null when the target is not a direct node or no override
 * is configured. */
export function get_direct_override(outbound_selector, dm, direct_overrides) {
	if (type(outbound_selector) === 'array' || isEmpty(outbound_selector))
		return null;

	switch (outbound_selector) {
	case 'direct-out':
	case 'block-out':
		return null;
	default:
		const rn = ConfigQuery.find_by_name(dm.routing.nodes, outbound_selector);
		const node = rn && rn.node;
		return (!isEmpty(node) && node !== 'urltest') ? (direct_overrides[node] || null) : null;
	}
}

/* True when `tag` (the sing-box outbound tag) belongs to a direct outbound.
 * Used by the http_clients builder to drop the detour field on a pure-TUN
 * setup: sing-box 1.14 rejects detouring to a direct outbound that has
 * nothing to detour through. */
export function isDirectOutboundTag(tag, dm) {
	if (isEmpty(tag) || tag === 'block-out')
		return false;
	if (tag === 'direct-out')
		return true;

	const rn = ConfigQuery.find_by_name(dm.routing.nodes, tag);
	const node_name = (rn && rn.node) || tag;
	const node = ConfigQuery.node_by_id(dm, node_name);
	return !!(node && node.type === 'direct');
}

/* Append the sing-box JSON $schema field. Kept here because the value is
 * fixed and the two generators used to spell it the same way; if it ever
 * changes, both should pick up the new URL automatically. */
export function attachSchema(config) {
	config['$schema'] = 'https://sing-box.sagernet.org/schema.json';
	return config;
}

/* Attach the experimental cache_file block when one of the routing modes
 * that needs it is active. Routing-mode gating stays here because the
 * block is the same regardless of mode; only the condition differs. */
export function attachExperimental(config, routing_mode, dns_store_dns) {
	if (routing_mode in ['bypass_mainland_china', 'custom']) {
		config.experimental = {
			cache_file: {
				enabled: true,
				path: '/etc/homeproxy/cache.db',
				store_dns: (dns_store_dns === '1') ? true : null
			}
		};
	}
	return config;
}