#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * PR-03 (Subscription Transaction Boundary): integration test for
 * subscription/repository.uc. The repository writes to the UCI
 * cursor that is passed in, which means the test needs a sandboxed
 * config dir. tests/ucode/test_subscription_repository.sh stages
 * the dir + the pre-existing UCI file and points the cursor at the
 * staging root. The test then exercises the four paths the
 * orchestrator relies on:
 *
 *   - a user-created node (no grouphash) is preserved
 *   - a subscription node still in the cache is updated in place
 *   - a subscription node dropped from the cache is deleted
 *   - a new node in the cache but not in UCI is added under the
 *     md5(groupHash + label) section name
 *
 * PR-03 changes the input contract: Repository now accepts
 * canonical Node objects (post- parser/normalize), and flattens
 * them via parser/flatten internally. The orchestrator hands
 * Repository.normalize(parse_uri(uri)) directly; the test builds
 * the canonical shape explicitly.
 *
 * Returns 0 on success, 1 on any mismatch. Counts and section
 * names are checked with cursor.get_all() against the live cursor
 * so the test does not need to parse the UCI file by hand.
 */

'use strict';

import { cursor } from 'uci';
import { md5 } from 'digest';

import { Repository } from 'repository';

/* PR-03: helper for building canonical Node fixtures. The
 * orchestrator gets canonical Nodes from normalize(parse_uri(...));
 * the test feeds them by hand so the repository's input contract
 * (canonical Node, not flat UCI) is what gets exercised. */
function canonical_node(opts) {
	return {
		id: null,
		name: opts.label,
		type: opts.type,
		address: opts.address,
		port: opts.port || null,
		common: {},
		credentials: {},
		tls: { enabled: null, ech: {}, utls: {}, reality: {} },
		transport: { type: null },
		multiplex: { enabled: null, brutal: {} },
		protocol_options: {},
		grouphash: opts.grouphash,
		label: opts.label
	};
}

const CFG = 'homeproxy';
const TYPE = 'node';

const LOG = (..._args) => {};

let failures = 0;
let checks = 0;

function expect(name, actual, expected) {
	checks++;
	if (sprintf('%J', actual) !== sprintf('%J', expected)) {
		printf('FAIL %s: expected %J, got %J\n', name, expected, actual);
		failures++;
	}
}

const uci = cursor(ARGV[0]);
uci.load(CFG);

/* groupHash is what the orchestrator hands the repository. It
 * is a per-subscription-url identifier - any opaque string the
 * orchestrator likes, as long as it stays stable across fetches.
 * Two distinct URLs would get two distinct groupHash values, so
 * the test uses a single group to focus on the per-node logic. */
const groupHash = 'test-group';

/* Pre-existing UCI state: a user node, a subscription node that
 * the new cache will update, and a subscription node the new
 * cache will drop. The cursor.commit() below persists them so
 * the repository's foreach() sees them when it runs. */
const u_user = 'cfgUSER0001';
const u_keep = 'cfgKEEP00001';
const u_drop = 'cfgDROP00001';

uci.set(CFG, u_user, TYPE);
uci.set(CFG, u_user, 'label',  'user-only');
uci.set(CFG, u_user, 'type',   'vless');
uci.set(CFG, u_user, 'address', 'user.example.com');

uci.set(CFG, u_keep, TYPE);
uci.set(CFG, u_keep, 'label',      'kept-node');
uci.set(CFG, u_keep, 'grouphash',  groupHash);
uci.set(CFG, u_keep, 'type',       'vless');
uci.set(CFG, u_keep, 'address',    'old.example.com');
uci.set(CFG, u_keep, 'stale_field', 'remove-me');

uci.set(CFG, u_drop, TYPE);
uci.set(CFG, u_drop, 'label',     'dropped-node');
uci.set(CFG, u_drop, 'grouphash', groupHash);
uci.set(CFG, u_drop, 'type',      'vless');
uci.set(CFG, u_drop, 'address',   'gone.example.com');

uci.commit(CFG);

/* What the orchestrator would have built during the fetch phase
 * for a successful subscription update. Two canonical Nodes from
 * the cache:
 *   - the updated version of u_keep (with new address)
 *   - a brand-new node (will be added under md5(group+label))
 * u_drop is intentionally absent -> the repository must delete it. */
const kept_updated = canonical_node({
	grouphash: groupHash,
	label: 'kept-node',
	type: 'vless',
	address: 'new.example.com',
	port: '443'
});

const new_label = 'fresh-node';
const new_node = canonical_node({
	grouphash: groupHash,
	label: new_label,
	type: 'trojan',
	address: 'fresh.example.com',
	port: '8443'
});

const node_cache = {
	[groupHash]: {
		[u_keep]: kept_updated,
		[md5(groupHash + new_label)]: new_node
	}
};

const node_result = [[kept_updated, new_node]];

const result = Repository.apply_nodes(uci, CFG, TYPE, node_cache, node_result, LOG);
expect('counts: added',   result.added,   1);
expect('counts: removed', result.removed, 1);

/* Reload to see the on-disk state. */
uci.load(CFG);

/* User node preserved verbatim. */
{
	const cfg = uci.get_all(CFG, u_user);
	expect('user: section exists', 'address' in cfg, true);
	expect('user: address kept',  cfg.address,      'user.example.com');
	expect('user: no grouphash leaked in',
		'grouphash' in cfg, false);
}

/* Updated node: the new address is written, the field the new config
 * no longer carries is dropped, and a field that exists only in the
 * new config (port, in this fixture) is ADDED. The old
 * implementation walked only the stored section's keys, so a
 * subscription that started sending a new option could never update
 * an existing node; that behaviour was previously locked in here as a
 * "quirk" and is now asserted to be fixed. */
{
	const cfg = uci.get_all(CFG, u_keep);
	expect('kept: section exists',    'address' in cfg,  true);
	expect('kept: address updated',   cfg.address,       'new.example.com');
	expect('kept: stale_field gone',  'stale_field' in cfg, false);
	expect('kept: new field added',   cfg.port,          '443');
}

/* Dropped node is gone. */
{
	const cfg = uci.get_all(CFG, u_drop);
	/* get_all on a deleted section returns the section metadata
	 * (with .name) but no actual options. The cleanest check is
	 * that the label is no longer present. */
	expect('drop: section removed', 'label' in cfg, false);
}

/* New node added under the md5(group+label) name. */
{
	const nameHash = md5(groupHash + new_label);
	const cfg = uci.get_all(CFG, nameHash);
	expect('new: section added',  'address' in cfg, true);
	expect('new: address correct', cfg.address,      'fresh.example.com');
	expect('new: type correct',   cfg.type,         'trojan');
	expect('new: grouphash set',  cfg.grouphash,    groupHash);
}

/* --- PR-03: apply_main_node_refs ------------------------------------ */

/* Use a fresh sandbox cursor so the apply_nodes state above does
 * not pollute the urltest-list assertions below. */
const uci2 = cursor(ARGV[0]);
uci2.load(CFG);

/* Pre-populate a main_node = 'urltest' and a main_urltest_nodes
 * list that includes one alive node and one dead reference. After
 * the apply pass, the dead reference should be pruned; the alive
 * one should remain. */
const groupB = 'groupB';
const n_alive = 'cfgALIVE0001';
const n_dead  = 'cfgDEAD00001';

uci2.set(CFG, n_alive, TYPE);
uci2.set(CFG, n_alive, 'label',     'alive-node');
uci2.set(CFG, n_alive, 'grouphash', groupB);
uci2.set(CFG, n_alive, 'type',      'vless');
uci2.set(CFG, n_alive, 'address',   'alive.example.com');
uci2.set(CFG, n_dead, TYPE);
uci2.set(CFG, n_dead, 'label',     'dead-node');
uci2.set(CFG, n_dead, 'grouphash', groupB);
uci2.set(CFG, n_dead, 'type',      'vless');
uci2.set(CFG, n_dead, 'address',   'dead.example.com');

uci2.set(CFG, 'config', 'main_node', 'urltest');
uci2.set(CFG, 'config', 'main_urltest_nodes', [n_alive, n_dead]);
uci2.commit(CFG);

/* Re-load so the cursor picks up the new sections. */
uci2.load(CFG);

const main_refs = Repository.apply_main_node_refs(
	uci2, CFG, 'config', TYPE,
	{ main_node: 'urltest', main_udp_node: 'nil', has_nodes: true },
	LOG
);
expect('main_node_refs: main_node kept as urltest',
	main_refs.main_node, 'urltest');
uci2.load(CFG);
const main_urltest_nodes_after = uci2.get(CFG, 'config', 'main_urltest_nodes') || [];
expect('main_node_refs: dead reference pruned',
	sort(main_urltest_nodes_after), [n_alive]);
expect('main_node_refs: log line emitted for the prune',
	length(filter(main_refs.log, (l) => match(l, 'removing from urltest'))),
	1);

/* Now exercise the "main_node target is gone" path: point
 * main_node at a specific section that does not exist in UCI.
 * Repository should switch to the first surviving subscription
 * node. */
uci2.set(CFG, 'config', 'main_node', 'cfgNOPEEEEEE');
uci2.commit(CFG);
uci2.load(CFG);

const main_refs2 = Repository.apply_main_node_refs(
	uci2, CFG, 'config', TYPE,
	{ main_node: 'cfgNOPEEEEEE', main_udp_node: 'nil', has_nodes: true },
	LOG
);
expect('main_node_refs: missing target switched to first_server',
	main_refs2.main_node, n_alive);
expect('main_node_refs: switch logged',
	length(filter(main_refs2.log, (l) => match(l, 'switching to'))),
	1);

/* And the "no nodes at all" reset path. has_nodes=false with
 * main_node set should write 'nil' for both main_node and
 * main_udp_node. */
uci2.load(CFG);
uci2.set(CFG, 'config', 'main_node', 'urltest');
uci2.set(CFG, 'config', 'main_udp_node', 'urltest');
uci2.commit(CFG);
uci2.load(CFG);

const main_refs3 = Repository.apply_main_node_refs(
	uci2, CFG, 'config', TYPE,
	{ main_node: 'urltest', main_udp_node: 'urltest', has_nodes: false },
	LOG
);
expect('main_node_refs: no-nodes path resets main_node to nil',
	main_refs3.main_node, 'nil');
expect('main_node_refs: no-nodes path resets main_udp_node to nil',
	main_refs3.main_udp_node, 'nil');
uci2.load(CFG);
expect('main_node_refs: no-nodes path wrote nil to UCI',
	uci2.get(CFG, 'config', 'main_node'), 'nil');
expect('main_node_refs: no-nodes path wrote nil to UCI for udp',
	uci2.get(CFG, 'config', 'main_udp_node'), 'nil');

/* --- PR-03: scrub_stale_urltest_refs ------------------------------- */

/* Re-use the same sandbox: add a routing_node with an urltest_nodes
 * list that mixes a live and a dead node, then run the scrub. */
uci2.load(CFG);
const rn_x = 'rn_test';
uci2.set(CFG, rn_x, 'routing_node');
uci2.set(CFG, rn_x, 'node', 'urltest');
uci2.set(CFG, rn_x, 'urltest_nodes', [n_alive, n_dead]);
uci2.commit(CFG);
uci2.load(CFG);

const scrub = Repository.scrub_stale_urltest_refs(uci2, CFG, LOG);
expect('scrub: at least one commit', scrub.commits >= 1, true);
uci2.load(CFG);
const cleaned = uci2.get(CFG, rn_x, 'urltest_nodes') || [];
expect('scrub: live ref preserved', sort(cleaned), [n_alive]);

printf('%d checks, %d failures\n', checks, failures);
exit(failures ? 1 : 0);