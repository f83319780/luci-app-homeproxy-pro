#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Stage A1.1 skeleton test: assert that Loader.load(fixture) produces a
 * HomeProxyConfig that mirrors the UCI fixture's general / infra / nodes
 * sections. The other five sub-objects (dns, routing, endpoints,
 * access_control, server) are intentionally empty `{}` until A1.2 lands.
 *
 * Run from tests/ucode/run.sh, which stages this file next to a scratch
 * homeproxy.uc and config/loader.uc + config/model.uc.
 */

'use strict';

import { Loader } from './config/loader.uc';
import { Config, Node, ConfigQuery } from './config/model.uc';

let failures = 0;
let checks = 0;

function expect(name, actual, expected) {
	checks++;
	if (sprintf('%J', actual) !== sprintf('%J', expected)) {
		printf('FAIL %s: expected %J, got %J\n', name, expected, actual);
		failures++;
	}
}

function expect_null(name, value) {
	checks++;
	if (value !== null && value !== undefined) {
		printf('FAIL %s: expected null, got %J\n', name, value);
		failures++;
	}
}

const config = Loader.load('./config');

/* --- general --------------------------------------------------------- */
expect('general.routing_mode', config.general.routing_mode, 'bypass_mainland_china');
expect('general.proxy_mode', config.general.proxy_mode, 'tun');
expect('general.main_node', config.general.main_node, 'urltest');
expect('general.main_udp_node', config.general.main_udp_node, 'nil');

/* --- infra ----------------------------------------------------------- */
expect('infra.dns_port', config.infra.dns_port, '5333');
expect('infra.mixed_port', config.infra.mixed_port, '5330');
expect('infra.self_mark', config.infra.self_mark, '100');
expect('infra.tun_name', config.infra.tun_name, 'singtun0');

/* --- nodes count + identity ----------------------------------------- */
expect('nodes.length', length(config.nodes), 10);

/* uci.foreach order is implementation-defined; index by id instead */
function by_id(id) {
	for (let n in config.nodes)
		if (n.id === id)
			return n;
	return null;
}

const vless = by_id('n_vless_reality_ws');
const snell = by_id('n_snell');
const ss = by_id('n_ss');

if (!vless || !snell || !ss) {
	printf('FAIL: missing expected node id (vless=%J, snell=%J, ss=%J)\n',
		vless, snell, ss);
	failures++;
}

/* --- vless_reality_ws: typed view + sub-objects --------------------- */
expect('vless.type', vless?.type, 'vless');
expect('vless.address', vless?.address, 'b.example.com');
expect('vless.port', vless?.port, '443');
expect('vless.credentials.uuid', vless?.credentials?.uuid,
	'3af88561-9c69-4b19-8f7e-f08d580bc339');
expect('vless.tls.server_name', vless?.tls?.server_name, 'b.example.com');
expect('vless.tls.reality.public_key', vless?.tls?.reality?.public_key,
	'4UAg690QziXeelpUJoAmXiim0gfQESSiJkNfvF-o8Uw');
expect('vless.transport.type', vless?.transport?.type, 'ws');
expect('vless.transport.path', vless?.transport?.path, '/ws?ed=2048');

/* --- snell: renamed credential fields (password->psk, username->userkey) */
expect('snell.credentials.psk', snell?.credentials?.psk, 'psk123456789012');
expect('snell.credentials.userkey', snell?.credentials?.userkey, 'ukey');
expect_null('snell.credentials.username', snell?.credentials?.username);
expect_null('snell.credentials.password', snell?.credentials?.password);

/* --- shadowsocks: empty sub-objects are OK, raw still carries the rest */
expect('ss.type', ss?.type, 'shadowsocks');
expect('ss.credentials.method', ss?.credentials?.method, 'aes-256-gcm');
expect('ss.multiplex.enabled', ss?.multiplex?.enabled, '1');
expect('ss.protocol_options.packet_encoding', ss?.protocol_options?.packet_encoding, null);

/* --- raw keeps the unmodelled tail ---------------------------------- */
if (type(vless?.raw) !== 'object' || length(vless.raw) < 10) {
	printf('FAIL vless.raw: expected a substantial UCI dict, got %J\n', vless?.raw);
	failures++;
	checks++;
}

/* --- validate --------------------------------------------------------- */
const vless_problems = Node.validate(vless);
expect('validate(vless) problems', vless_problems, []);

const bad = Node.create({
	id: 'bad', type: 'vless', address: null, port: '0',
	credentials: {}, tls: {}, transport: {}, multiplex: {},
	protocol_options: {}, raw: {}
});
const bad_problems = Node.validate(bad);
if (length(bad_problems) === 0) {
	printf('FAIL validate(bad): expected at least one problem, got none\n');
	failures++;
	checks++;
} else {
	checks++;
}

/* --- tag helper ------------------------------------------------------- */
expect('tag(vless)', Node.tag(vless), 'cfg-n_vless_reality_ws-out');
expect('main_node_id', ConfigQuery.main_node_id(config), 'urltest');

/* --- the five unwired sub-objects are present and empty -------------- */
for (let name in ['dns', 'routing', 'endpoints', 'access_control', 'server']) {
	if (!(name in config) || type(config[name]) !== 'object') {
		printf('FAIL %s: expected an empty object placeholder, got %J\n', name, config[name]);
		failures++;
	}
	checks++;
}

printf('%d checks, %d failures\n', checks, failures);
exit(failures === 0 ? 0 : 1);
