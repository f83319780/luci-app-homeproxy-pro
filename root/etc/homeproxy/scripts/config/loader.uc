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
 *   - reads general + infra + nodes + dns + routing + access_control + server
 *   - never emits sing-box JSON
 *   - never mutates/commits UCI
 *
 * What is NOT yet wired in:
 *   - endpoints: derived at the application/service layer (it is what
 *     `main_node` / `routing.default_outbound` resolve to, not a UCI
 *     section). Stays an empty `{}` placeholder until A3.
 */

'use strict';

import { cursor } from 'uci';

import { Config, Node, CREDENTIALS } from './model.uc';

const UCICONFIG = 'homeproxy';

const SECTION = {
	main: 'config',
	infra: 'infra',
	node: 'node',
	dns: 'dns',
	dns_server: 'dns_server',
	dns_rule: 'dns_rule',
	routing: 'routing',
	routing_node: 'routing_node',
	routing_rule: 'routing_rule',
	ruleset: 'ruleset',
	control: 'control',
	subscription: 'subscription',
	server: 'server'
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
 * sub-object makes the boundary explicit and testable.
 *
 * load_tls and load_transport are exported so the server generator can
 * shape its UCI inbound sections the same way; only the multiplex shape is
 * Loader-internal because no caller outside the client node path needs it. */

export function load_tls(get) {
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
};

export function load_transport(get) {
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
};

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

/* Cross-protocol common fields (every outbound protocol carries them, not
 * just one). Lives as its own sub-object instead of being repeated in
 * every PROTOCOL_OPTIONS row, and the Adapter reads from `node.common` so
 * the Adapter never has to reach back to `node.raw` for these. */
function load_common(get) {
	return {
		proxy_protocol: get('proxy_protocol'),
		tcp_fast_open: get('tcp_fast_open'),
		tcp_multi_path: get('tcp_multi_path'),
		udp_fragment: get('udp_fragment')
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
		udp_over_tcp: 'udp_over_tcp'
		/* tcp_fast_open / tcp_multi_path / udp_fragment used to live here
		 * but they are common to every protocol, not vless-specific; they
		 * are now in node.common via load_common() above. */
	},
	snell: {
		version: 'snell_version',
		reuse: 'snell_reuse',
		obfs_mode: 'snell_obfs_mode',
		obfs_host: 'snell_obfs_host',
		mode: 'snell_mode'
	},
	/* A4.1: shadowsocks uses shadowsocks_* UCI option names (matching the
	 * generator's pre-refactor reads). */
	shadowsocks: {
		plugin: 'shadowsocks_plugin',
		plugin_opts: 'shadowsocks_plugin_opts',
		udp_over_tcp: 'udp_over_tcp',
		udp_over_tcp_version: 'udp_over_tcp_version'
	},
	/* A4.2: anytls idle session tuning. */
	anytls: {
		idle_session_check_interval: 'anytls_idle_session_check_interval',
		idle_session_timeout: 'anytls_idle_session_timeout',
		min_idle_session: 'anytls_min_idle_session'
	},
	/* A4.3: http */
	http: {},
	/* A4.4: socks */
	socks: {
		version: 'socks_version'
	},
	/* A4.5: tuic */
	tuic: {
		congestion_control: 'tuic_congestion_control',
		udp_relay_mode: 'tuic_udp_relay_mode',
		udp_over_stream: 'tuic_udp_over_stream',
		zero_rtt_handshake: 'tuic_enable_zero_rtt',
		heartbeat: 'tuic_heartbeat'
	},
	/* A4.6: trojan / vmess share no protocol-specific UCI keys beyond
	 * what the shared TLS/transport/multiplex builders already read. */
	trojan: {},
	/* A4.7: shadowtls */
	shadowtls: {
		version: 'shadowtls_version'
	},
	/* A4.8 / A4.9: hysteria + hysteria2 */
	hysteria: {
		auth_type: 'hysteria_auth_type',
		auth_payload: 'hysteria_auth_payload',
		up_mbps: 'hysteria_up_mbps',
		down_mbps: 'hysteria_down_mbps',
		obfs_type: 'hysteria_obfs_type',
		obfs_password: 'hysteria_obfs_password',
		hopping_port: 'hysteria_hopping_port',
		hop_interval: 'hysteria_hop_interval'
	},
	hysteria2: {
		obfs_type: 'hysteria_obfs_type',
		obfs_password: 'hysteria_obfs_password',
		up_mbps: 'hysteria_up_mbps',
		down_mbps: 'hysteria_down_mbps',
		hop_interval: 'hysteria_hop_interval',
		hop_interval_max: 'hysteria_hop_interval_max',
		hopping_port: 'hysteria_hopping_port',
		auth_payload: 'hysteria_auth_payload',
		bbr_profile: 'hysteria_bbr_profile',
		disable_chrome_parrot: 'hysteria_disable_chrome_parrot'
	},
	/* A4.10: vmess */
	vmess: {
		alter_id: 'vmess_alterid',
		security: 'vmess_encrypt',
		global_padding: 'vmess_global_padding',
		auth_payload: 'vmess_auth_payload'
	},
	/* P3-E: direct nodes carry override_address/override_port, which the
	 * Generator uses to populate the direct_overrides table for the
	 * routing path. Reading them from node.protocol_options keeps the
	 * Adapter (and the Generator) off node.raw. */
	direct: {
		override_address: 'override_address',
		override_port: 'override_port'
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

/* --- domain sub-objects ------------------------------------------------ */

/* Settings: only the keys that exist in UCI are kept (null is dropped), so
 * the consumer can tell "not set" from "set to empty". A3 (Generator split)
 * will own the actual key list - this loader just preserves what UCI has. */
function load_settings(uci, section, keys) {
	const settings = {};

	for (let key in keys) {
		const v = uci.get(UCICONFIG, section, key);
		if (v != null)
			settings[key] = v;
	}

	return settings;
}

/* Single-section + list sections grouped under a domain sub-object. Each
 * list is the raw UCI section dict (`type` in {'array'/'object'}), and
 * downstream code is responsible for shaping it into the sing-box field
 * names. `enabled` flags stay as raw UCI strings here, same as Node. */
function load_sections(uci, type) {
	const items = [];

	uci.foreach(UCICONFIG, type, (cfg) => push(items, cfg));

	return items;
}

function load_dns(uci) {
	return {
		settings: load_settings(uci, SECTION.dns, [
			'default_strategy', 'default_server',
			'disable_cache', 'disable_cache_expire',
			'client_subnet',
			'optimistic_cache', 'optimistic_timeout',
			'dns_timeout', 'cache_file_store_dns'
		]),
		servers: load_sections(uci, SECTION.dns_server),
		rules: load_sections(uci, SECTION.dns_rule)
	};
}

function load_routing(uci) {
	return {
		settings: load_settings(uci, SECTION.routing, [
			'default_outbound', 'default_outbound_dns',
			'domain_strategy', 'find_neighbor',
			'udp_timeout', 'tcpip_stack', 'endpoint_independent_nat'
		]),
		nodes: load_sections(uci, SECTION.routing_node),
		rules: load_sections(uci, SECTION.routing_rule),
		rulesets: load_sections(uci, SECTION.ruleset)
	};
}

/* access_control is two single sections: `control` (lan_proxy_mode,
 * wan_proxy_*_ips) and `subscription` (auto_update, filter, urls). */
function load_access_control(uci) {
	return {
		control: load_settings(uci, SECTION.control, [
			'bind_interface', 'lan_proxy_mode'
		]),
		/* wan_proxy_*_ips are list options on the control section; collect
		   them in their canonical form. */
		wan_proxy_ipv4_ips: uci.get(UCICONFIG, SECTION.control, 'wan_proxy_ipv4_ips') || [],
		wan_proxy_ipv6_ips: uci.get(UCICONFIG, SECTION.control, 'wan_proxy_ipv6_ips') || [],
		subscription: load_settings(uci, SECTION.subscription, [
			'auto_update', 'allow_insecure',
			'packet_encoding', 'update_via_proxy',
			'filter_nodes', 'user_agent'
		]),
		subscription_urls: uci.get(UCICONFIG, SECTION.subscription, 'subscription_url') || [],
		filter_keywords: uci.get(UCICONFIG, SECTION.subscription, 'filter_keywords') || []
	};
}

/* server has one enabled/log_level single section + N inbound sections
 * (each with a `type` of vless / trojan / shadowsocks / ...). The full
 * inbound list is preserved verbatim; A3 reshapes it into the sing-box
 * inbounds. */
function load_server(uci) {
	return {
		settings: load_settings(uci, SECTION.server, [
			'enabled', 'log_level'
		]),
		inbounds: load_sections(uci, SECTION.server)
	};
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
			/* Booleans stay as raw UCI strings here, same as Node. The
			   Adapter (A3) is the one that calls strToBool(); coercing in
			   the Loader and again in the Adapter produced two different
			   defaults for absent / garbage values during A1.1. */
			ipv6_support: opt(uci, 'main', 'ipv6_support'),

			/* A2.1: scalar + list fields on the `config` section. */
			dns_server: opt(uci, 'main', 'dns_server'),
			china_dns_server: opt(uci, 'main', 'china_dns_server'),
			log_level: opt(uci, 'main', 'log_level') || 'warn',
			tun_dns_mode: opt(uci, 'main', 'tun_dns_mode'),
			tun_dns_address: opt(uci, 'main', 'tun_dns_address'),
			udp_mapping: opt(uci, 'main', 'udp_mapping'),
			udp_filtering: opt(uci, 'main', 'udp_filtering'),
			udp_nat_max: opt(uci, 'main', 'udp_nat_max'),
			cn_ip_fallback: opt(uci, 'main', 'cn_ip_fallback'),
			main_urltest_nodes: opt(uci, 'main', 'main_urltest_nodes') || [],
			main_urltest_interval: opt(uci, 'main', 'main_urltest_interval'),
			main_urltest_tolerance: opt(uci, 'main', 'main_urltest_tolerance'),
			main_udp_urltest_nodes: opt(uci, 'main', 'main_udp_urltest_nodes') || [],
			main_udp_urltest_interval: opt(uci, 'main', 'main_udp_urltest_interval'),
			main_udp_urltest_tolerance: opt(uci, 'main', 'main_udp_urltest_tolerance')
		};

		/* udp_timeout lives on two UCI sections: routing.udp_timeout
		 * (custom mode) and infra.udp_timeout (everything else). Mirror
		 * that split here so A2 can read either path without falling back
		 * to uci.get(). */
		config.infra = load_settings(uci, SECTION.infra, [
			'common_port', 'mixed_port', 'redirect_port', 'tproxy_port',
			'dns_port', 'dns_redirect',
			'tun_name', 'tun_addr4', 'tun_addr6', 'tun_mtu',
			'table_mark', 'self_mark', 'tproxy_mark', 'tun_mark',
			'ntp_server', 'udp_timeout'
		]);

		uci.foreach(UCICONFIG, SECTION.node, (section) => {
			const get = (name) => node_opt(uci, section['.name'], name);

			push(config.nodes, Node.create({
				id: section['.name'],
				name: get('label') || section['.name'],
				type: get('type'),
				address: get('address'),
				port: get('port'),
				common: load_common(get),
				credentials: load_credentials(get, get('type')),
				tls: load_tls(get),
				transport: load_transport(get),
				multiplex: load_multiplex(get),
				protocol_options: load_protocol_options(get, get('type')),
				raw: section
			}));
		});

		config.dns = load_dns(uci);
		config.routing = load_routing(uci);
		config.access_control = load_access_control(uci);
		config.server = load_server(uci);

		return config;
	}
};
