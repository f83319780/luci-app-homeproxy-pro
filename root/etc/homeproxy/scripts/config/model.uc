/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Stage A1.1 of the architecture refactor (see
 * homeproxy_architecture_refactor_agent_guide.md):
 *
 *     UCI -> Config Loader -> HomeProxyConfig / Node -> Adapter -> sing-box
 *
 * The point of this layer is that nothing below it may touch UCI, and nothing
 * in it may know about sing-box JSON. A Node therefore describes *what the
 * user configured*, not what sing-box wants: no `outbound`, no `type` field
 * named after a sing-box outbound kind, no `tag` arithmetic.
 *
 * `raw` keeps the untouched UCI dict for fields the model does not interpret
 * yet. It exists so the migration can be incremental, and it is the only part
 * of the model allowed to be opaque.
 */

'use strict';

import { isEmpty } from 'homeproxy';

/* Canonical credential multiplexing for a Node. The current generator picks
 * these apart with ternaries per field (`username` vs `user` vs `password` vs
 * `psk`, keyed on every protocol); expressing them as data is what makes a new
 * protocol a table entry instead of another branch.
 *
 * The value is the UCI option name (as the loader sees it on the flat UCI
 * section), the key is the canonical credential name. The adapter later
 * emits the field under whatever name the sing-box outbound wants
 * (e.g. snell: credentials.psk is emitted as the outbound `psk` field,
 * shadowsocks: credentials.method becomes outbound `method`).
 *
 * Fixed during Stage A1.1: snell `userkey` actually comes from the
 * `snell_userkey` UCI option (not `username`), and shadowsocks `method`
 * actually comes from `shadowsocks_encrypt_method` (not `method`).
 * The earlier table assumed both mapped to bare option names and failed
 * the skeleton test against the real fixture. */
export const CREDENTIALS = {
	vless:   { uuid: 'uuid' },
	vmess:   { uuid: 'uuid' },
	trojan:  { password: 'password' },
	hysteria: { auth_str: 'auth', auth_base64: 'auth' },
	hysteria2: { password: 'password' },
	tuic:    { uuid: 'uuid', password: 'password' },
	shadowsocks: { password: 'password', method: 'shadowsocks_encrypt_method' },
	socks:   { username: 'username', password: 'password' },
	http:    { username: 'username', password: 'password' },
	snell:   { psk: 'password', userkey: 'snell_userkey' },
	/* The node form writes ssh_priv_key / ssh_priv_key_pp, not the bare
	 * private_key this table used to claim, so the key the user pasted was
	 * never read.  (There was also no PROTOCOL_OPTIONS row for ssh, so the
	 * rest of the SSH options were dropped as well.) */
	ssh:     { user: 'username', password: 'password',
	           private_key: 'ssh_priv_key', private_key_passphrase: 'ssh_priv_key_pp' },
	anytls:  { password: 'password' },
	shadowtls: { password: 'password' },
	direct:  {}
};

/* --- Domain types ------------------------------------------------------- */

export const Config = {
	create: (name) => ({
		name: name,
		general: {},
		nodes: [],

		/* Stage A1.1 placeholders: the loader does not read these yet, so
		   they exist as empty objects to make the HomeProxyConfig shape
		   complete. A1.2 - A1.4 fill them in: dns, routing, endpoints,
		   access_control, server. Downstream code may assert their
		   presence even when empty. */
		dns: {},
		routing: {},
		endpoints: {},
		access_control: {},
		server: {},

		/* The full unmodelled UCI tail. Not part of the domain contract;
		   shrinks as the refactor progresses. */
		raw: {}
	})
};

export const Node = {
	create: (opts) => ({
		/* identity */
		id: opts.id,
		name: opts.name,
		type: opts.type,

		/* endpoint */
		address: opts.address,
		port: opts.port,

		/* cross-protocol common fields (proxy_protocol, tcp_fast_open,
		 * tcp_multi_path, udp_fragment). The Adapter reads from here so
		 * it never has to reach back into `raw` for these. */
		common: opts.common || {},

		/* credentials, already canonical */
		credentials: opts.credentials || {},

		/* transport/TLS are sub-objects, not flat prefixed keys: that is the
		   boundary the adapter needs in order to reuse the shared builders. */
		tls: opts.tls || {},
		transport: opts.transport || {},
		multiplex: opts.multiplex || {},

		/* per-protocol extras, canonical names only */
		protocol_options: opts.protocol_options || {},

		/* verbatim UCI dict, for the not-yet-modelled tail */
		raw: opts.raw || {}
	}),

	/* A node is usable only if the adapter can build a valid outbound from it.
	 * The old code discovers this by crashing inside the JSON builder.
	 *
	 * Scope: generic, cross-protocol sanity only. The Adapter layer owns
	 * per-protocol required-field rules (a vless needs uuid, vmess needs
	 * both uuid and a security cipher, snell needs a psk, ...) because
	 * those rules are sing-box-outbound-shaped. Anything the model can
	 * express without naming a protocol or a JSON field goes here.
	 *
	 * Booleans are still raw UCI strings at this layer; this validator
	 * compares against the literal '1' the way UCI emits them.
	 *
	 * Implementation note: ucode's push() returns the value pushed, not
	 * the new array, so the natural-looking `problems = push(problems, X)`
	 * pattern reassigns problems to a string and silently corrupts the
	 * accumulator. Build the array via spread instead - cheap because the
	 * validator is at most four checks. */
	validate: (node) => {
		let problems = [];

		if (!node.type)
			problems = [...problems, 'missing type'];

		/* A direct outbound can run without a server/server_port - sing-box
		 * uses the inbound's destination as the upstream, which is the
		 * transparent-proxy case. For every other protocol the server
		 * and port are mandatory. */
		if (node.type !== 'direct') {
			if (!node.address)
				problems = [...problems, 'missing address'];

			if (node.port == null || int(node.port) < 1 || int(node.port) > 65535)
				problems = [...problems, `invalid port '${node.port}'`];
		}

		/* TLS without server_name is a sing-box-side rejection, but the
		 * rule itself is protocol-agnostic - the reality branch covers the
		 * only legitimate escape - so it stays here. */
		if (node.tls.enabled === '1' && !node.tls.server_name && node.tls.reality.enabled !== '1')
			problems = [...problems, 'TLS enabled without server_name'];

		return problems;
	},

	/* sing-box tag convention lives here, not scattered through the generator */
	tag: (node) => 'cfg-' + node.id + '-out'
};

/* --- Config helpers ----------------------------------------------------- */

export const ConfigQuery = {
	node_by_id: (config, id) => {
		for (let node in config.nodes)
			if (node.id === id)
				return node;

		return null;
	},

	/* Linear search by UCI section name (which is what the router still
	 * uses in routing_node / dns_server / etc. references). Returns the
	 * flat section dict so the existing uci.foreach-style consumers do
	 * not have to change. */
	find_by_name: (items, name) => {
		for (let it in items)
			if (it['.name'] === name)
				return it;
		return null;
	},

	node_ids: (config) => map(config.nodes, (node) => node.id),

	/* Which node the routing modes route through. The default (`nil`) means
	 * "no proxy node", which is a legitimate configuration. */
	main_node_id: (config) => config.general.main_node || 'nil',

	main_udp_node_id: (config) => config.general.main_udp_node || 'nil',

	/* endpoints is a derived list (not a UCI section): each entry is the
	 * resolved outbound the generator eventually emits as a sing-box
	 * endpoint. The shape is filled in by the application/service layer
	 * (A3 / A4), not by the Loader. This helper returns an empty list
	 * so callers can iterate unconditionally before A3 lands. */
	endpoints: (config) => {
		const ep = config.endpoints;
		if (type(ep) !== 'object' || length(ep) === 0)
			return [];
		return ep;
	}
};
