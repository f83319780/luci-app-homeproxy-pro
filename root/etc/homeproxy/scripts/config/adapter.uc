/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Stage A1.1 of the architecture refactor (see
 * homeproxy_architecture_refactor_agent_guide.md):
 *
 *     Node -> Protocol Adapter -> SingBox Outbound
 *
 * Promoted from demo/architecture/adapter.uc. The copy in demo/architecture/
 * is the runnable reference. The two copies must stay in lockstep.
 *
 * This replaces the single 110-line `generate_outbound()` whose protocol
 * branches are expressed as ~60 ternaries inside one object literal. Two
 * properties are deliberately kept and one is deliberately dropped:
 *
 *   kept     the shared TLS/transport/multiplex code is still shared, and is
 *            the *existing* production builders - the adapter only supplies
 *            them a Node-shaped view instead of a flat UCI dict.
 *   kept     the emitted JSON is per-field identical to the old builder; the
 *            diff test in tests/ucode/test_demo_architecture.sh is what
 *            guarantees it.
 *   dropped  a per-protocol Adapter class hierarchy. The protocols differ by
 *            which *fields* they carry, not by behaviour, so the honest
 *            extension point is the field tables below, not eleven classes.
 *
 * Adding a protocol means adding three entries: CREDENTIALS (model.uc),
 * PROTOCOL_OPTIONS (loader.uc) and OPTION_FIELDS here.
 *
 * Stage A1.1 status: only vless and snell are wired in. The other nine
 * protocols keep using the production generate_outbound() until their
 * OPTION_FIELDS / CLAIM_FIELDS entries land in A4.1 - A4.11.
 */

'use strict';

import {
	strToBool, strToInt, strToTime, removeBlankAttrs,
	buildTLSObject, buildTransportObject
} from 'homeproxy';

import { Node } from './model.uc';

/* --- field transforms --------------------------------------------------- */

/* A table value is either a transform name, a literal, a function of the
 * Node, or a descriptor { from, when } selecting an option conditionally. */
const TRANSFORMS = {
	raw: (value) => value,
	bool: (value) => strToBool(value),
	int: (value) => strToInt(value),
	time: (value) => strToTime(value)
};

function resolve(spec, node) {
	if (type(spec) === 'function')
		return spec(node);

	if (type(spec) === 'object' && spec !== null && 'from' in spec) {
		/* `when` is the protocol the option belongs to; anything else yields
		 * null so removeBlankAttrs() drops the field, exactly like the old
		 * ternaries did. */
		if (spec.when !== node.type)
			return null;

		return TRANSFORMS[spec.transform || 'raw'](node.raw[spec.from]);
	}

	if (type(spec) === 'string' && spec in TRANSFORMS)
		return null;

	return spec;
}

/* --- field tables ------------------------------------------------------- */

/* Fields every protocol emits. Each is null when absent, and nulls are
 * stripped once, at the end, by removeBlankAttrs(). */
const COMMON_FIELDS = {
	server: (node) => node.address,
	server_port: (node) => strToInt(node.port),
	// set by the runtime, not by the model
	routing_mark: null,
	proxy_protocol: (node) => strToInt(node.raw.proxy_protocol),
	tcp_fast_open: (node) => strToBool(node.raw.tcp_fast_open),
	tcp_multi_path: (node) => strToBool(node.raw.tcp_multi_path),
	udp_fragment: (node) => strToBool(node.raw.udp_fragment),
	packet_encoding: (node) => node.protocol_options.packet_encoding || null
};

/* Credential fields: one canonical set, emitted under the name each protocol
 * wants. This is where the old builder repeated itself. */
function CLAIM_FIELDS(node) {
	switch (node.type) {
	case 'snell':
		return {
			psk: node.credentials.psk,
			userkey: node.credentials.userkey,
			reuse: strToBool(node.raw.snell_reuse)
		};
	case 'ssh':
		return {
			user: node.credentials.user,
			private_key: node.credentials.private_key
		};
	case 'hysteria':
		return {
			auth: (node.raw.hysteria_auth_type === 'base64') ? node.raw.hysteria_auth_payload : null,
			auth_str: (node.raw.hysteria_auth_type === 'string') ? node.raw.hysteria_auth_payload : null
		};
	default:
		return {
			username: node.credentials.username,
			uuid: node.credentials.uuid,
			password: node.credentials.password,
			method: node.credentials.method
		};
	}
}

/* Per-protocol option fields, keyed by the same canonical names the model
 * exposes. Anything absent here still travels in `node.raw`, which is what
 * makes the migration incremental. */
const OPTION_FIELDS = {
	vless: {
		flow: (node) => node.protocol_options.flow,
		udp_over_tcp: (node) => (node.protocol_options.udp_over_tcp === '1') ? {
			enabled: true,
			version: strToInt(node.protocol_options.udp_over_tcp_version)
		} : null
	},
	snell: {
		version: (node) => strToInt(node.protocol_options.version) || 4,
		obfs_mode: (node) => node.protocol_options.obfs_mode || null,
		obfs_host: (node) => node.protocol_options.obfs_host || null,
		mode: (node) => node.protocol_options.mode || null
	},
	/* A4.1: shadowsocks. SIP002 plugin support is emitted only when both
	 * plugin and plugin_opts are present, matching the generator's ternary
	 * that emits `plugin: ...` unconditionally and lets removeBlankAttrs
	 * drop empties. `udp_over_tcp` mirrors the vless shape. */
	shadowsocks: {
		plugin: (node) => node.protocol_options.plugin || null,
		plugin_opts: (node) => node.protocol_options.plugin_opts || null,
		udp_over_tcp: (node) => (node.protocol_options.udp_over_tcp === '1') ? {
			enabled: true,
			version: strToInt(node.protocol_options.udp_over_tcp_version)
		} : null
	},
	/* A4.2: anytls idle session tuning (sing-box 1.14 lets the client probe
	 * upstream sessions and proactively close stuck ones). */
	anytls: {
		idle_session_check_interval: (node) => strToTime(node.protocol_options.idle_session_check_interval),
		idle_session_timeout: (node) => strToTime(node.protocol_options.idle_session_timeout),
		min_idle_session: (node) => strToInt(node.protocol_options.min_idle_session)
	},
	/* A4.3: http - no protocol-specific options; transport / tls / multiplex
	 * are shared. */
	http: {},
	/* A4.4: socks */
	socks: {
		version: (node) => node.protocol_options.version
	},
	/* A4.5: tuic */
	tuic: {
		congestion_control: (node) => node.protocol_options.congestion_control,
		udp_relay_mode: (node) => node.protocol_options.udp_relay_mode,
		udp_over_stream: (node) => strToBool(node.protocol_options.udp_over_stream),
		zero_rtt_handshake: (node) => strToBool(node.protocol_options.zero_rtt_handshake),
		heartbeat: (node) => strToTime(node.protocol_options.heartbeat)
	},
	/* A4.6: trojan - no protocol-specific options. */
	trojan: {},
	/* A4.7: shadowtls */
	shadowtls: {
		version: (node) => strToInt(node.protocol_options.version)
	},
	/* A4.8: hysteria (v1). The generator emits two fields: `auth` when the
	 * payload is base64, `auth_str` when it is a string. Node.validate()
	 * only catches the obvious case; the conditional keeps the table-driven
	 * shape. */
	hysteria: {
		auth: (node) => (node.protocol_options.auth_type === 'base64') ? node.protocol_options.auth_payload : null,
		auth_str: (node) => (node.protocol_options.auth_type === 'string') ? node.protocol_options.auth_payload : null,
		up_mbps: (node) => strToInt(node.protocol_options.up_mbps),
		down_mbps: (node) => strToInt(node.protocol_options.down_mbps),
		hop_interval: (node) => strToTime(node.protocol_options.hop_interval),
		obfs: (node) => node.protocol_options.obfs_type ? {
			type: node.protocol_options.obfs_type,
			password: node.protocol_options.obfs_password
		} : null
	},
	/* A4.9: hysteria2 - extends hysteria with hop_interval_max /
	 * server_ports / bbr_profile / disable_chrome_parrot. The obfs
	 * shape is the same. Note sing-box 1.14 uses `server_ports`
	 * (port hopping list), not `hopping_port` - the latter is the
	 * UCI option name, so the rename happens here. */
	hysteria2: {
		auth: (node) => (node.protocol_options.auth_type === 'base64') ? node.protocol_options.auth_payload : null,
		auth_str: (node) => (node.protocol_options.auth_type === 'string') ? node.protocol_options.auth_payload : null,
		up_mbps: (node) => strToInt(node.protocol_options.up_mbps),
		down_mbps: (node) => strToInt(node.protocol_options.down_mbps),
		hop_interval: (node) => strToTime(node.protocol_options.hop_interval),
		hop_interval_max: (node) => strToTime(node.protocol_options.hop_interval_max),
		server_ports: (node) => node.protocol_options.hopping_port,
		obfs: (node) => node.protocol_options.obfs_type ? {
			type: node.protocol_options.obfs_type,
			password: node.protocol_options.obfs_password
		} : null,
		bbr_profile: (node) => node.protocol_options.bbr_profile || null,
		disable_chrome_parrot: (node) => (node.protocol_options.disable_chrome_parrot === '1') ? true : null
	},
	/* A4.10: vmess */
	vmess: {
		alter_id: (node) => strToInt(node.protocol_options.alter_id),
		security: (node) => node.protocol_options.security,
		global_padding: (node) => strToBool(node.protocol_options.global_padding)
	}
};

/* --- shared builders ---------------------------------------------------- */

/* The production builders still read flat, prefixed UCI keys, so the adapter
 * hands them a compatibility view of the Node. This shim disappears once the
 * builders take sub-objects; keeping it here (and not in the model) is the
 * point - the model stays free of sing-box/legacy shapes. */
function legacy_view(node) {
	/* buildTransportObject() expects the flat UCI keys the pre-refactor
	 * code used; in particular it reads `http_host` (or
	 * `httpupgrade_host`) for `transport.host` and `ws_host` for
	 * `transport.headers.Host`. Mapping every transport.host into all
	 * three flat fields sends ws outbounds with a `transport.host`
	 * value sing-box 1.14 rejects. The shim is type-aware so each
	 * transport kind only emits the flat key the builder looks at. */
	const t = node.transport.type;
	const host = node.transport.host;
	const headers_host = node.transport.headers && node.transport.headers.Host;
	const view = {
		tls: node.tls.enabled,
		tls_sni: node.tls.server_name,
		tls_insecure: node.tls.insecure,
		tls_alpn: node.tls.alpn,
		tls_min_version: node.tls.min_version,
		tls_max_version: node.tls.max_version,
		tls_handshake_timeout: node.tls.handshake_timeout,
		tls_cipher_suites: node.tls.cipher_suites,
		tls_cert_path: node.tls.cert_path,
		tls_ech: node.tls.ech.enabled,
		tls_ech_config: node.tls.ech.config,
		tls_ech_config_path: node.tls.ech.config_path,
		tls_utls: node.tls.utls.fingerprint,
		tls_reality: node.tls.reality.enabled,
		tls_reality_public_key: node.tls.reality.public_key,
		tls_reality_short_id: node.tls.reality.short_id,
		transport: t,
		http_host:        (t === 'http')        ? host : null,
		httpupgrade_host: (t === 'httpupgrade' || t === 'http2') ? host : null,
		http_path: (t === 'http' || t === 'httpupgrade' || t === 'http2') ? node.transport.path : null,
		ws_path:   (t === 'ws')  ? node.transport.path : null,
		ws_host:   (t === 'ws')  ? headers_host : null,
		http_method: (t === 'http' || t === 'httpupgrade' || t === 'http2') ? node.transport.method : null,
		websocket_early_data: (t === 'ws') ? node.transport.max_early_data : null,
		websocket_early_data_header: (t === 'ws') ? node.transport.early_data_header_name : null,
		grpc_servicename: (t === 'grpc') ? node.transport.service_name : null,
		http_idle_timeout: (t === 'http' || t === 'httpupgrade') ? node.transport.idle_timeout : null,
		http_ping_timeout: (t === 'http' || t === 'httpupgrade') ? node.transport.ping_timeout : null,
		grpc_permit_without_stream: (t === 'grpc') ? node.transport.permit_without_stream : null
	};

	return view;
}

function build_multiplex(mux) {
	if (mux.enabled !== '1')
		return null;

	return {
		enabled: true,
		protocol: mux.protocol,
		max_connections: strToInt(mux.max_connections),
		min_streams: strToInt(mux.min_streams),
		max_streams: strToInt(mux.max_streams),
		padding: strToBool(mux.padding),
		brutal: (mux.brutal.enabled === '1') ? {
			enabled: true,
			up_mbps: strToInt(mux.brutal.up_mbps),
			down_mbps: strToInt(mux.brutal.down_mbps)
		} : null
	};
}

/* --- adapter ------------------------------------------------------------ */

export const OutboundFactory = {
	/* Node -> sing-box outbound object. Pure: no UCI, no module state, no file
	 * access. `mark` is passed in instead of being read from a global. */
	create: (node, mark) => {
		const problems = Node.validate(node);

		if (length(problems))
			die(`node '${node.id}': ${join(', ', problems)}\n`);

		const legacy = legacy_view(node);
		const outbound = {
			type: node.type,
			tag: Node.tag(node),
			routing_mark: strToInt(mark)
		};

		for (let field, spec in COMMON_FIELDS)
			outbound[field] = resolve(spec, node);

		const claims = CLAIM_FIELDS(node);
		for (let field, value in claims)
			outbound[field] = value;

		const options = OPTION_FIELDS[node.type] || {};
		for (let field, spec in options)
			outbound[field] = resolve(spec, node);

		outbound.multiplex = build_multiplex(node.multiplex);
		outbound.tls = buildTLSObject(legacy, false);
		outbound.transport = buildTransportObject(legacy, false);

		if (node.type === 'direct')
			outbound.proxy_protocol = strToInt(node.raw.proxy_protocol);

		/* removeBlankAttrs() is what the generator applies before writing, and
		   it drops every null the field tables produced. Cleaning here means
		   this function returns the final artifact, so an equivalence test can
		   compare it against what sing-box would actually be handed. */
		return removeBlankAttrs(outbound);
	}
};
