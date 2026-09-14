/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Stage A1.1 of the architecture refactor (see
 * homeproxy_architecture_refactor_agent_guide.md):
 *
 *     UCI -> Config Loader -> HomeProxyConfig / Node -> Adapter -> sing-box
 *
 * Promoted from demo/architecture/model.uc. The copy in demo/architecture/
 * is the runnable reference. The two copies must stay in lockstep - changes
 * here need the same change in demo/architecture/model.uc, and vice versa.
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
	ssh:     { user: 'username', private_key: 'private_key' },
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
	 * Note that booleans are still raw UCI strings at this layer. */
	validate: (node) => {
		let problems = [];

		if (!node.type)
			problems = push(problems, 'missing type');
		if (!node.address)
			problems = push(problems, 'missing address');

		if (node.port == null || int(node.port) < 1 || int(node.port) > 65535)
			problems = push(problems, `invalid port '${node.port}'`);

		/* booleans are still raw UCI strings at this layer */
		if (node.tls.enabled === '1' && !node.tls.server_name && node.tls.reality.enabled !== '1')
			problems = push(problems, 'TLS enabled without server_name');

		return problems;
	},

	/* sing-box tag convention lives here, not scattered through the generator */
	tag: (node) => 'cfg-' + node.id + '-out',

	/* Flat UCI section -> Node. The generator used to call generate_outbound()
	 * with `uci.get_all()` (a flat dict prefixed by the protocol's own UCI
	 * names); after A3, every call site hands a Node to OutboundFactory. To
	 * keep the diff small in the meantime, this is the bridge: turn a flat
	 * section into a Node shaped the way the Loader would have produced it.
	 * The sub-objects are re-extracted here rather than going back through
	 * cursor(), which keeps generate_outbound(cfg) callable from any code
	 * path that still has only the flat dict. */
	from_section: (cfg) => {
		if (type(cfg) !== 'object' || isEmpty(cfg))
			return null;

		const get = (name) => cfg[name];

		/* Sub-object extraction, deliberately duplicating the per-field
		 * table the Loader uses (load_tls / load_transport / ...). Keeping
		 * them in sync is the A1.1 contract; tests/ucode/test_domain_model_
		 * skeleton.uc verifies the Loader side. */
		const tls = {
			enabled: get('tls'),
			server_name: get('tls_sni'),
			insecure: get('tls_insecure'),
			alpn: get('tls_alpn'),
			min_version: get('tls_min_version'),
			max_version: get('tls_max_version'),
			handshake_timeout: get('tls_handshake_timeout'),
			cipher_suites: get('tls_cipher_suites'),
			cert_path: get('tls_cert_path'),
			utls: { fingerprint: get('tls_utls') },
			ech: { enabled: get('tls_ech'), config: get('tls_ech_config'), config_path: get('tls_ech_config_path') },
			reality: { enabled: get('tls_reality'), public_key: get('tls_reality_public_key'), short_id: get('tls_reality_short_id') }
		};
		const transport = {
			type: get('transport'),
			host: get('ws_host') || get('http_host') || get('httpupgrade_host'),
			path: get('ws_path') || get('http_path'),
			method: get('http_method'),
			headers: get('ws_host') ? { Host: get('ws_host') } : (get('http_host') ? { Host: get('http_host') } : null),
			max_early_data: get('websocket_early_data'),
			early_data_header_name: get('websocket_early_data_header'),
			service_name: get('grpc_servicename'),
			idle_timeout: get('http_idle_timeout'),
			ping_timeout: get('http_ping_timeout'),
			permit_without_stream: get('grpc_permit_without_stream')
		};
		const multiplex = {
			enabled: get('multiplex'),
			protocol: get('multiplex_protocol'),
			max_connections: get('multiplex_max_connections'),
			min_streams: get('multiplex_min_streams'),
			max_streams: get('multiplex_max_streams'),
			padding: get('multiplex_padding'),
			brutal: { enabled: get('multiplex_brutal'), up_mbps: get('multiplex_brutal_up'), down_mbps: get('multiplex_brutal_down') }
		};

		const credential_map = {
			vless:   { uuid: 'uuid' },
			vmess:   { uuid: 'uuid' },
			trojan:  { password: 'password' },
			hysteria2: { password: 'password' },
			tuic:    { uuid: 'uuid', password: 'password' },
			shadowsocks: { password: 'password', method: 'shadowsocks_encrypt_method' },
			socks:   { username: 'username', password: 'password' },
			http:    { username: 'username', password: 'password' },
			snell:   { psk: 'password', userkey: 'snell_userkey' },
			ssh:     { user: 'username', private_key: 'private_key' },
			anytls:  { password: 'password' },
			shadowtls: { password: 'password' },
			direct:  {}
		};
		const cred = {};
		const cmap = credential_map[get('type')] || {};
		for (let canonical, uci_name in cmap)
			cred[canonical] = get(uci_name);

		/* protocol_options: pass every common suffix the Adapter may want.
		 * Adapter's OPTION_FIELDS will pull out the canonical names; the rest
		 * sits unused but is cheap. */
		const protocol_options = {
			flow: get('vless_flow'),
			packet_encoding: get('packet_encoding'),
			udp_over_tcp: get('udp_over_tcp'),
			udp_over_tcp_version: get('udp_over_tcp_version'),
			tcp_fast_open: get('tcp_fast_open'),
			tcp_multi_path: get('tcp_multi_path'),
			udp_fragment: get('udp_fragment'),
			plugin: get('shadowsocks_plugin'),
			plugin_opts: get('shadowsocks_plugin_opts'),
			idle_session_check_interval: get('anytls_idle_session_check_interval'),
			idle_session_timeout: get('anytls_idle_session_timeout'),
			min_idle_session: get('anytls_min_idle_session'),
			version: get('socks_version') || get('shadowtls_version') || get('snell_version'),
			reuse: get('snell_reuse'),
			obfs_mode: get('snell_obfs_mode'),
			obfs_host: get('snell_obfs_host'),
			mode: get('snell_mode'),
			congestion_control: get('tuic_congestion_control'),
			udp_relay_mode: get('tuic_udp_relay_mode'),
			udp_over_stream: get('tuic_udp_over_stream'),
			zero_rtt_handshake: get('tuic_enable_zero_rtt'),
			heartbeat: get('tuic_heartbeat'),
			auth_type: get('hysteria_auth_type'),
			auth_payload: get('hysteria_auth_payload'),
			up_mbps: get('hysteria_up_mbps'),
			down_mbps: get('hysteria_down_mbps'),
			obfs_type: get('hysteria_obfs_type'),
			obfs_password: get('hysteria_obfs_password'),
			hopping_port: get('hysteria_hopping_port'),
			hop_interval: get('hysteria_hop_interval'),
			hop_interval_max: get('hysteria_hop_interval_max'),
			bbr_profile: get('hysteria_bbr_profile'),
			disable_chrome_parrot: get('hysteria_disable_chrome_parrot'),
			alter_id: get('vmess_alterid'),
			security: get('vmess_encrypt'),
			global_padding: get('vmess_global_padding')
		};

		return {
			/* identity */
			id: cfg['.name'],
			name: get('label') || cfg['.name'],
			type: get('type'),

			/* endpoint */
			address: get('address'),
			port: get('port'),

			credentials: cred,
			tls,
			transport,
			multiplex,
			protocol_options,
			raw: cfg
		};
	}
};

/* --- Config helpers ----------------------------------------------------- */

export const ConfigQuery = {
	node_by_id: (config, id) => {
		for (let node in config.nodes)
			if (node.id === id)
				return node;

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
