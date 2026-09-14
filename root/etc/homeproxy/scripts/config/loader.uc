/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Stage A1.1 of the architecture refactor (see
 * homeproxy_architecture_refactor_agent_guide.md):
 *
 *     UCI -> Config Loader -> HomeProxyConfig
 *
 * This file originated as demo/architecture/loader.uc and was promoted into
 * the production tree. The copy in demo/architecture/ is kept as a runnable
 * reference (it powers demo/architecture/demo.uc and is exercised by
 * tests/ucode/test_demo_architecture.sh); both copies import the model from
 * a sibling file, so changing model.uc here changes it for the demo too.
 *
 * What is wired in as of this commit:
 *   - owns the only `uci.cursor()` in the client configuration path
 *   - reads general + infra + nodes from UCI
 *   - never emits sing-box JSON
 *   - never mutates/commits UCI
 *
 * What is NOT yet wired in (A1.2 follow-up):
 *   - dns, routing, endpoints, access_control, server sub-objects stay empty
 *     `{}` for now. The generator still reads them with the legacy
 *     `uci.get()` calls. The two views must agree byte-for-byte before
 *     A1.2 can replace the second set of calls.
 */

'use strict';

import { cursor } from 'uci';

import { Config, Node, CREDENTIALS } from './model.uc';

const UCICONFIG = 'homeproxy';

const SECTION = {
	main: 'config',
	infra: 'infra',
	node: 'node'
};

/* Booleans are UCI '0'/'1'; keep the conversion in one place. */
function bool(value) {
	return value === '1';
}

function opt(uci, section, name) {
	/* UCI returns null for an absent option; the old code papered over that
	 * with `|| ''` at every call site, losing the distinction between "not
	 * set" and "set to empty". The model keeps null instead. */
	return uci.get(UCICONFIG, SECTION[section], name);
}

function node_opt(uci, section_id, name) {
	return uci.get(UCICONFIG, section_id, name);
}

/* --- sub-object extraction --------------------------------------------- */

/* These three functions are the whole reason a Node is hierarchical: the
 * shared TLS/transport/multiplex builders (homeproxy.uc) take a flat,
 * prefixed dict today, so every caller has to hand them the right subset. A
 * sub-object makes the boundary explicit and testable. */

function load_tls(get) {
	return {
		enabled: get('tls'),
		server_name: get('tls_sni'),
		insecure: get('tls_insecure'),
		alpn: get('tls_alpn'),
		min_version: get('tls_min_version'),
		max_version: get('tls_max_version'),
		handshake_timeout: get('tls_handshake_timeout'),
		cipher_suites: get('tls_cipher_suites'),
		cert_path: get('tls_cert_path'),
		ech: {
			enabled: get('tls_ech'),
			config: get('tls_ech_config'),
			config_path: get('tls_ech_config_path')
		},
		utls: {
			fingerprint: get('tls_utls')
		},
		reality: {
			enabled: get('tls_reality'),
			public_key: get('tls_reality_public_key'),
			short_id: get('tls_reality_short_id')
		},
		/* kept verbatim: the server-side builder owns the key material format */
		raw: {
			tls_reality_public_key: get('tls_reality_public_key'),
			tls_reality_short_id: get('tls_reality_short_id'),
			tls_utls: get('tls_utls'),
			tls_sni: get('tls_sni'),
			tls_insecure: get('tls_insecure')
		}
	};
}

function load_transport(get) {
	const transport = get('transport');

	if (transport == null || transport === '')
		return { type: null };

	return {
		type: transport,
		host: get('http_host') || get('httpupgrade_host'),
		path: get('http_path') || get('ws_path'),
		headers: get('ws_host') ? { Host: get('ws_host') } : null,
		method: get('http_method'),
		max_early_data: get('websocket_early_data'),
		early_data_header_name: get('websocket_early_data_header'),
		service_name: get('grpc_servicename'),
		idle_timeout: get('http_idle_timeout'),
		ping_timeout: get('http_ping_timeout'),
		permit_without_stream: get('grpc_permit_without_stream')
	};
}

function load_multiplex(get) {
	return {
		enabled: get('multiplex'),
		protocol: get('multiplex_protocol'),
		max_connections: get('multiplex_max_connections'),
		min_streams: get('multiplex_min_streams'),
		max_streams: get('multiplex_max_streams'),
		padding: get('multiplex_padding'),
		brutal: {
			enabled: get('multiplex_brutal'),
			up_mbps: get('multiplex_brutal_up'),
			down_mbps: get('multiplex_brutal_down')
		}
	};
}

/* --- protocol options --------------------------------------------------- */

/* Maps canonical option name -> UCI option name. Anything not listed is not
 * part of the domain contract for that protocol. `raw` still carries the
 * unlisted tail, so the migration can stay incremental without losing data. */
const PROTOCOL_OPTIONS = {
	vless: {
		flow: 'vless_flow',
		packet_encoding: 'packet_encoding',
		udp_over_tcp_version: 'udp_over_tcp_version',
		udp_over_tcp: 'udp_over_tcp',
		tcp_fast_open: 'tcp_fast_open',
		tcp_multi_path: 'tcp_multi_path',
		udp_fragment: 'udp_fragment'
	},
	snell: {
		version: 'snell_version',
		reuse: 'snell_reuse',
		obfs_mode: 'snell_obfs_mode',
		obfs_host: 'snell_obfs_host',
		mode: 'snell_mode'
	}
};

function load_protocol_options(get, type) {
	const mapping = PROTOCOL_OPTIONS[type] || {};
	const options = {};

	for (let canonical, uci_name in mapping)
		options[canonical] = get(uci_name);

	return options;
}

/* Pull the protocol's credential fields out under canonical names, using the
 * single CREDENTIALS table from the model. This is the loader half of the
 * mapping that the old code spread across ~20 ternaries in generate_outbound().
 * Declared before Loader: ucode resolves module-level names at call time but
 * not before they are declared. */
function load_credentials(get, type) {
	const mapping = CREDENTIALS[type] || {};
	const credentials = {};

	for (let canonical, uci_name in mapping)
		credentials[canonical] = get(uci_name);

	return credentials;
}

/* --- loader ------------------------------------------------------------- */

export const Loader = {
	/* Load the client side of the configuration. `dir` defaults to the
	 * production UCI directory but can be overridden, which removes the need
	 * for the test suite's `sed` of `const uci = cursor();`. */
	load: (dir) => {
		const uci = dir ? cursor(dir) : cursor();

		uci.load(UCICONFIG);

		const config = Config.create('homeproxy');

		config.general = {
			routing_mode: opt(uci, 'main', 'routing_mode') || 'bypass_mainland_china',
			proxy_mode: opt(uci, 'main', 'proxy_mode') || 'redirect_tproxy',
			main_node: opt(uci, 'main', 'main_node') || 'nil',
			main_udp_node: opt(uci, 'main', 'main_udp_node') || 'nil',
			ipv6_support: bool(opt(uci, 'main', 'ipv6_support')),
			ipv6: bool(opt(uci, 'main', 'ipv6_support')),
			udp_timeout: opt(uci, 'infra', 'udp_timeout')
		};

		config.infra = {
			dns_port: opt(uci, 'infra', 'dns_port') || '5333',
			mixed_port: opt(uci, 'infra', 'mixed_port') || '5330',
			self_mark: opt(uci, 'infra', 'self_mark') || '100',
			ntp_server: opt(uci, 'infra', 'ntp_server'),
			tun_name: opt(uci, 'infra', 'tun_name')
		};

		uci.foreach(UCICONFIG, SECTION.node, (section) => {
			const get = (name) => node_opt(uci, section['.name'], name);

			push(config.nodes, Node.create({
				id: section['.name'],
				name: get('label') || section['.name'],
				type: get('type'),
				address: get('address'),
				port: get('port'),
				credentials: load_credentials(get, get('type')),
				tls: load_tls(get),
				transport: load_transport(get),
				multiplex: load_multiplex(get),
				protocol_options: load_protocol_options(get, get('type')),
				raw: section
			}));
		});

		return config;
	}
};
