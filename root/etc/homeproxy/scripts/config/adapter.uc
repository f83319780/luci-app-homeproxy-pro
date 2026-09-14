/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Stage A1.1 of the architecture refactor (see
 * homeproxy_architecture_refactor_agent_guide.md):
 *
 *     Node -> Protocol Adapter -> SingBox Outbound
 *
 * This replaces the single 110-line `generate_outbound()` whose protocol
 * branches were expressed as ~60 ternaries inside one object literal. Three
 * properties are deliberate:
 *
 *   kept     the shared TLS/transport/multiplex code is still the existing
 *            production builders - the adapter only supplies them a
 *            Node-shaped view instead of a flat UCI dict.
 *   pinned   the emitted JSON is frozen by tests/snapshots/generator/
 *            outbounds.json, so a field change for any protocol is a
 *            reviewable diff (test_golden_outbounds.sh).
 *   dropped  a per-protocol Adapter class hierarchy. The protocols differ by
 *            which *fields* they carry, not by behaviour, so the honest
 *            extension point is the field tables below, not eleven classes.
 *
 * Adding a protocol means adding three entries: CREDENTIALS (model.uc),
 * PROTOCOL_OPTIONS (loader.uc) and OPTION_FIELDS here - and a node in
 * tests/fixtures/generators/outbounds.uci, which
 * tests/ucode/test_protocol_inventory.sh enforces.
 */

'use strict';

import {
	strToBool, strToInt, strToTime, removeBlankAttrs,
	buildTLSObject, buildTransportObject
} from 'homeproxy';

import { Node } from './model.uc';

/* Per-protocol required credential fields. Node.validate() covers the
 * cross-protocol rules (type/address/port/TLS); this table is the
 * per-protocol half - "vless needs uuid, vmess needs uuid, trojan needs
 * password, snell needs psk, ..." - and it is the Adapter's job because
 * the requirement is shaped by what the sing-box outbound for each
 * protocol will actually accept, not by anything the model knows about
 * UCI. The keys are the canonical credential names the Loader uses
 * (see CREDENTIALS in model.uc), so the check is data-driven and adding
 * a protocol is a one-line change. */
export const REQUIRED_CREDENTIALS = {
	vless:     ['uuid'],
	vmess:     ['uuid'],
	trojan:    ['password'],
	hysteria2: ['password'],
	tuic:      ['uuid', 'password'],
	shadowsocks: ['password'],
	snell:     ['psk'],
	anytls:    ['password'],
	shadowtls: ['password'],
	ssh:       ['user'],
	/* These three have no hard required credential - the protocol can
	 * run anonymously (http / socks) or the auth is delivered out of
	 * band (hysteria, direct). Node.validate()'s address/port check
	 * is enough. */
	hysteria:  [],
	http:      [],
	socks:     [],
	direct:    []
};

/* Run a Node through the per-protocol required-field check. Returns
 * the (possibly empty) list of human-readable problems.
 *
 * The same ucode quirk that bit Node.validate() bites here too: push()
 * returns the value pushed, not the new array, so we build the result
 * via spread instead of the obvious `problems = push(problems, X)`. */
function protocol_problems(node) {
	const required = REQUIRED_CREDENTIALS[node.type] || [];
	const creds = node.credentials || {};
	let problems = [];

	for (let field in required) {
		if (!creds[field])
			problems = [...problems, `${node.type} requires ${field}`];
	}

	/* WireGuard is the one protocol whose material does not live in
	 * `credentials`: the endpoint builder reads node.protocol_options.
	 * Checking it here means a broken WireGuard node is caught by the
	 * same "is this node buildable?" path as every other protocol, which
	 * is what lets a urltest list prune it instead of failing the whole
	 * configuration. */
	if (node.type === 'wireguard') {
		const opts = node.protocol_options || {};
		for (let field in ['local_address', 'private_key', 'peer_public_key'])
			if (!opts[field])
				problems = [...problems, `wireguard requires ${field}`];
	}

	return problems;
}

/* --- field transforms --------------------------------------------------- */

/* A table value is either a function of the Node, a literal, or a string
 * naming a transform (in which case the value is null - the spec is
 * present so the key still gets emitted, but the value will be stripped
 * by removeBlankAttrs()). */
const TRANSFORMS = {
	raw: (value) => value,
	bool: (value) => strToBool(value),
	int: (value) => strToInt(value),
	time: (value) => strToTime(value)
};

function resolve(spec, node) {
	if (type(spec) === 'function')
		return spec(node);

	if (type(spec) === 'string' && spec in TRANSFORMS)
		return null;

	return spec;
}

/* --- field tables ------------------------------------------------------- */

/* Fields every protocol emits. Each is null when absent, and nulls are
 * stripped once, at the end, by removeBlankAttrs(). Cross-protocol common
 * fields live in node.common (Loader's load_common); protocol-specific
 * canonical names live in node.protocol_options. The Adapter never reads
 * from node.raw - that bag is kept only for the Loader's not-yet-modelled
 * tail and is opaque to this layer. */
const COMMON_FIELDS = {
	server: (node) => node.address,
	server_port: (node) => strToInt(node.port),
	// set by the runtime, not by the model
	routing_mark: null,
	proxy_protocol: (node) => strToInt(node.common.proxy_protocol),
	tcp_fast_open: (node) => strToBool(node.common.tcp_fast_open),
	tcp_multi_path: (node) => strToBool(node.common.tcp_multi_path),
	udp_fragment: (node) => strToBool(node.common.udp_fragment),
	packet_encoding: (node) => node.protocol_options.packet_encoding || null
};

/* The node form stores an SSH private key in a DynamicList, i.e. one UCI
 * list entry per line of the OpenSSH/PEM blob (a UCI option cannot hold
 * newlines).  sing-box wants the whole key as one string, so re-join the
 * lines.  A single-entry value is passed through unchanged.
 *
 * Declared before CLAIM_FIELDS on purpose: ucode resolves module-level names
 * lexically, so a callee has to appear above its caller in the file. */
function ssh_private_key(value) {
	if (type(value) === 'array')
		return length(value) ? join('\n', value) : null;

	return value || null;
}

/* Credential fields: one canonical set, emitted under the name each protocol
 * wants. This is where the old builder repeated itself. */
function CLAIM_FIELDS(node) {
	switch (node.type) {
	case 'snell':
		return {
			psk: node.credentials.psk,
			userkey: node.credentials.userkey,
			reuse: strToBool(node.protocol_options.reuse)
		};
	case 'ssh':
		return {
			user: node.credentials.user,
			password: node.credentials.password,
			private_key: ssh_private_key(node.credentials.private_key),
			private_key_passphrase: node.credentials.private_key_passphrase
		};
	case 'hysteria':
		return {
			auth: (node.protocol_options.auth_type === 'base64') ? node.protocol_options.auth_payload : null,
			auth_str: (node.protocol_options.auth_type === 'string') ? node.protocol_options.auth_payload : null
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
 * exposes. Anything not modelled here is still in node.protocol_options
 * (which is itself populated from the protocol's PROTOCOL_OPTIONS row in
 * the Loader), so the Adapter never has to reach into `node.raw`. */
export const OPTION_FIELDS = {
	vless: {
		flow: (node) => node.protocol_options.flow
		/* No udp_over_tcp here: sing-box 1.14 rejects that field on a vless
		 * outbound ("json: unknown field").  It used to be emitted, so a
		 * node whose type was switched from shadowsocks to vless kept the
		 * stale UCI option and produced a config sing-box refused outright.
		 * The node form never offered the option for vless anyway. */
	},
	/* `mode` (snell v6 traffic shaping) is deliberately absent: sing-box
	 * 1.14 rejects it as an outbound field, and the node form only offered
	 * it for snell_version 6, which this sing-box does not support either. */
	snell: {
		version: (node) => strToInt(node.protocol_options.version) || 4,
		obfs_mode: (node) => node.protocol_options.obfs_mode || null,
		obfs_host: (node) => node.protocol_options.obfs_host || null
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
	/* A4.4: socks.  The node form offers UDP-over-TCP for socks and sing-box
	 * accepts it on the socks outbound, but the adapter never emitted it, so
	 * the setting was silently ignored. */
	socks: {
		version: (node) => node.protocol_options.version,
		udp_over_tcp: (node) => (node.protocol_options.udp_over_tcp === '1') ? {
			enabled: true,
			version: strToInt(node.protocol_options.udp_over_tcp_version)
		} : null
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
	 * shape.
	 *
	 * obfs is the plain obfuscation password string here.  The node form
	 * only offers the password for v1 (the type selector is hysteria2-only)
	 * and sing-box rejects the {type, password} object on a hysteria
	 * outbound - that shape belongs to hysteria2.  Emitting the object made
	 * any obfuscated hysteria node produce a config sing-box refused. */
	hysteria: {
		auth: (node) => (node.protocol_options.auth_type === 'base64') ? node.protocol_options.auth_payload : null,
		auth_str: (node) => (node.protocol_options.auth_type === 'string') ? node.protocol_options.auth_payload : null,
		up_mbps: (node) => strToInt(node.protocol_options.up_mbps),
		down_mbps: (node) => strToInt(node.protocol_options.down_mbps),
		hop_interval: (node) => strToTime(node.protocol_options.hop_interval),
		obfs: (node) => node.protocol_options.obfs_password || null
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
	},
	/* SSH: host-key pinning and the client banner, matching sing-box's ssh
	 * outbound field names. */
	ssh: {
		client_version: (node) => node.protocol_options.client_version || null,
		host_key: (node) => node.protocol_options.host_key || null,
		host_key_algorithms: (node) => node.protocol_options.host_key_algorithms || null
	}
};

/* --- shared builders ---------------------------------------------------- */

function build_multiplex(mux) {
	if (!mux || mux.enabled !== '1')
		return null;

	return {
		enabled: true,
		protocol: mux.protocol,
		max_connections: strToInt(mux.max_connections),
		min_streams: strToInt(mux.min_streams),
		max_streams: strToInt(mux.max_streams),
		padding: strToBool(mux.padding),
		brutal: (mux.brutal && mux.brutal.enabled === '1') ? {
			enabled: true,
			up_mbps: strToInt(mux.brutal.up_mbps),
			down_mbps: strToInt(mux.brutal.down_mbps)
		} : null
	};
}

/* --- adapter ------------------------------------------------------------ */

/* Both validation layers as one list. Standalone (not a method) because the
 * OutboundFactory literal below cannot reference itself during its own
 * initialisation: ucode resolves the binding lexically and throws
 * "Can't access lexical declaration before initialization". */
function outbound_problems(node) {
	return [
		...Node.validate(node),
		...protocol_problems(node)
	];
}

/* Node -> sing-box outbound object.  Pure: no UCI, no module state, no file
 * access; `mark` is passed in instead of read from a global.
 *
 * Standalone for the same reason outbound_problems() is: the literal below
 * cannot name OutboundFactory in any nested scope, not even inside an arrow
 * body, without tripping ucode's "Can't access lexical declaration before
 * initialization" check.  Validation is done by the callers. */
function build_outbound(node, mark) {
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
	outbound.tls = buildTLSObject(node.tls, false);
	outbound.transport = buildTransportObject(node.transport, false);

	if (node.type === 'direct')
		outbound.proxy_protocol = strToInt(node.common.proxy_protocol);

	/* removeBlankAttrs() is what the generator applies before writing, and
	   it drops every null the field tables produced. Cleaning here means
	   this function returns the final artifact, so a golden-snapshot test
	   can compare it against what sing-box would actually be handed. */
	return removeBlankAttrs(outbound);
}

export const OutboundFactory = {
	/* Validation split out of create() so a caller can decide whether a
	 * broken node is fatal.  Two-layer: Node.validate() covers
	 * cross-protocol rules, protocol_problems() the per-protocol ones. */
	problems: outbound_problems,

	/* True when create() would succeed.  Used to prune optional node lists
	 * (urltest candidates) so one misconfigured node cannot abort the
	 * entire configuration. */
	buildable: (node) => length(outbound_problems(node)) === 0,

	/* Node -> { outbound, problems }.  Same result as create() but never
	 * dies, for nodes the user only *may* route through. */
	tryCreate: (node, mark) => {
		const problems = outbound_problems(node);

		if (length(problems))
			return { outbound: null, problems: problems };

		return { outbound: build_outbound(node, mark), problems: [] };
	},

	/* Node -> sing-box outbound object, or die() when the node is not
	 * buildable.  Use problems()/buildable()/tryCreate() for nodes whose
	 * breakage must not be fatal (urltest candidates). */
	create: (node, mark) => {
		const problems = outbound_problems(node);

		if (length(problems))
			die(`node '${node.id}': ${join(', ', problems)}\n`);

		return build_outbound(node, mark);
	}
};
