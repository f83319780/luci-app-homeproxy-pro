#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2023 ImmortalWrt.org
 *
 * PR-03 (Subscription Transaction Boundary): the orchestrator no
 * longer touches UCI directly. All UCI writes live in
 * subscription/repository.uc. The pipeline is:
 *
 *   Loader.load()           -> read subscription + main_node refs
 *   parse_uri()             -> flat UCI keys (the parser's output)
 *   apply_policy()          -> flat UCI tweaks (tls_insecure,
 *                              packet_encoding). Kept on the flat
 *                              side so tests/ucode/test_subscription_filter.uc
 *                              does not have to construct canonical
 *                              fixtures.
 *   normalize()             -> canonical Node (parser/normalize.uc).
 *   Repository.apply_nodes  -> writes UCI for subscription nodes
 *                              (internally flatten()s the canonical
 *                              nodes, so the orchestrator never
 *                              touches UCI).
 *   Repository.apply_main_node_refs -> writes UCI for main_node /
 *                              main_udp_node / urltest cleanup.
 *   Repository.scrub_stale_urltest_refs -> one-shot pass over UCI
 *                              routing_nodes for stale urltest_nodes
 *                              entries.
 *
 * Every UCI write the run performs is therefore in
 * subscription/repository.uc. The orchestrator's only UCI side
 * effect is passing its cursor to the Repository methods.
 */

'use strict';

import { md5 } from 'digest';
import { open, readfile, writefile } from 'fs';
import { connect } from 'ubus';
import { cursor } from 'uci';

import {
	executeCommand, getTime, isEmpty, HP_DIR, RUN_DIR, redactUrl
} from 'homeproxy';

import { parse_uri } from './parser/uri.uc';
import { normalize } from './parser/normalize.uc';

import { check as filter_check, apply_policy } from './subscription/filter.uc';
import { decode as decode_subscription } from './subscription/decoder.uc';
import { fetch as fetch_subscription } from './subscription/fetcher.uc';
import { Repository } from './subscription/repository.uc';

import { Loader } from './config/loader.uc';

/* UCI config start: a single cursor that every Repository method
 * shares. Loader uses its own cursor for the read at the top of
 * main(); both cursors target /etc/config/homeproxy so writes go
 * through the same on-disk file. The snapshot below is taken
 * BEFORE any commit, so a failure part-way through this run can
 * restore the previous file and leave the running service on its
 * current config. */
const CONFIG_FILE = '/etc/config/homeproxy';
const uciconfig = 'homeproxy';

const uci = cursor();
uci.load(uciconfig);

const ucimain = 'config',
      ucinode = 'node',
      ucisubscription = 'subscription';

/* PR-03 §2.5 #3: the orchestrator used to hold its own
 * uci.cursor() and re-read subscription.* / config.* one field at
 * a time. Now it goes through Loader.load(), which is read-only
 * and exposes the canonical sub-objects
 * (`config.access_control.subscription`). The Repository methods
 * continue to take the raw cursor for the writes because the
 * cursor is the UCI writer contract. */
const loaded = Loader.load();
const sub = loaded.access_control.subscription;
const routing_mode = loaded.general.routing_mode;

const allow_insecure = sub.allow_insecure || '0';
const filter_mode = sub.filter_nodes || 'disabled';
/* subscription_urls and filter_keywords are siblings of `subscription`,
 * not members of it: load_access_control() puts them straight on
 * access_control (loader.uc:303-304), and test_domain_model_skeleton.uc
 * asserts that shape.  Reading them through `sub.` yielded [] forever, so
 * the guard below never called main() and the updater exited 0 having done
 * nothing - the LuCI button and the cron entry were both silent no-ops. */
const filter_keywords = loaded.access_control.filter_keywords || [];
const packet_encoding = sub.packet_encoding || 'xudp';
const subscription_urls = loaded.access_control.subscription_urls || [];
const user_agent = sub.user_agent;

let main_node, main_udp_node;
if (routing_mode !== 'custom') {
	main_node = loaded.general.main_node;
	main_udp_node = loaded.general.main_udp_node;
}

const config_backup = readfile(CONFIG_FILE);

function log(...args) {
	const logfile = open(`${RUN_DIR}/homeproxy.log`, 'a');
	logfile.write(`${getTime()} [SUBSCRIBE] ${join(' ', args)}\n`);
	logfile.close();
}

function main() {
	const node_cache = {};
	const node_result = [];

	const ubus = connect();
	/* ubus is unreachable when no ubusd is running (dev host)
	 * and the feature query is optional: fall back to the same
	 * empty feature set the code below already handles. */
	const sing_features = (ubus?.call('luci.homeproxy', 'singbox_get_features', {})) || {};
	if (isEmpty(sing_features))
		log('Warning: Failed to query sing-box features via ubus, assuming defaults.');

	/* Fetch, decode, parse and filter everything BEFORE touching
	 * the service or UCI. The previous version stopped the proxy
	 * first, so a slow or failing subscription left the router
	 * without a proxy for the whole fetch - the stop -> modify
	 * -> discover-an-error pattern the refactor guide forbids.
	 * Nothing below runs until a full candidate set exists in
	 * memory. */
	for (let url in subscription_urls) {
		url = replace(url, /#.*$/, '');
		const groupHash = md5(url);
		node_cache[groupHash] = {};

		const fetched = fetch_subscription(url, user_agent, log);
		if (fetched.content === null)
			continue;

		const nodes = decode_subscription(fetched.content, log, url);

		let count = 0;
		for (let node in nodes) {
			let flat;
			if (!isEmpty(node))
				flat = parse_uri(node, sing_features, log);
			if (isEmpty(flat))
				continue;

			const label = flat.label;
			flat.label = null;
			const confHash = md5(sprintf('%J', flat)),
			      nameHash = md5(groupHash + label);
			flat.label = label;

			if (filter_check(flat.label, filter_mode, filter_keywords, log))
				log(sprintf('Skipping blacklist node: %s.', flat.label));
			else if (node_cache[groupHash][confHash] || node_cache[groupHash][nameHash])
				log(sprintf('Skipping duplicate node: %s.', flat.label));
			else {
				apply_policy(flat, { allow_insecure, packet_encoding });

				/* PR-03: parse -> apply_policy -> normalize
				 * builds the canonical Node the Repository
				 * takes. flat stays in scope for the
				 * fingerprinting above; the canonical
				 * Node carries the same data plus the
				 * metadata the orchestrator attaches
				 * (grouphash + label). */
				const node_canonical = normalize(flat);
				node_canonical.grouphash = groupHash;

				/* normalize() exposes the source label as `name`; the
				 * Repository identifies a node by
				 * md5(grouphash + label), so without this every node in
				 * one subscription hashes to the SAME section name and
				 * they overwrite each other - a 4-node subscription
				 * collapsed into a single section carrying one protocol's
				 * `type` with several protocols' options mixed in.
				 * The cache is keyed by the same hash, so this also makes
				 * an unchanged node match on the next run instead of
				 * being deleted and re-added every time. */
				node_canonical.label = flat.label;

				push(node_result, []);
				push(node_result[length(node_result)-1], node_canonical);
				node_cache[groupHash][confHash] = node_canonical;
				node_cache[groupHash][nameHash] = node_canonical;

				count++;
			}
		}

		if (count === 0)
			log(sprintf('No valid node found in %s.', redactUrl(url)));
		else
			log(sprintf('Successfully fetched %s nodes of total %s from %s.', count, length(nodes), redactUrl(url)));
	}

	if (isEmpty(node_result)) {
		/* Nothing was touched yet (the fetch phase never writes),
		 * so the running service and the stored configuration
		 * stay as they are. */
		log('Failed to update subscriptions: no valid node found.');
		return false;
	}

	/* B1.2 / PR-03: the add / update / remove walk and the
	 * final commit now live in subscription/repository.uc. The
	 * orchestrator just hands it the canonical Node cache +
	 * result built during the fetch phase and uses the
	 * { added, removed } counts for the end-of-run log. */
	const repository_result = Repository.apply_nodes(
		uci, uciconfig, ucinode, node_cache, node_result, log
	);
	const added = repository_result.added,
	      removed = repository_result.removed;

	/* PR-03 §2.5 #1: the 6 inline uci.set/commit sites
	 * (main_urltest_nodes cleanup, main_node switch on missing
	 * target, main_udp_urltest_nodes cleanup, main_udp_node
	 * switch, reset-to-'nil', routing_node urltest scrub) moved
	 * into subscription/repository.uc. The orchestrator now
	 * drives three Repository methods and replays the log lines
	 * the Repository attached to its result. */
	if (!isEmpty(main_node)) {
		const main_refs = Repository.apply_main_node_refs(
			uci, uciconfig, ucimain, ucinode,
			{ main_node, main_udp_node, has_nodes: added > 0 },
			log
		);
		for (let line in main_refs.log)
			log(line);
	}

	Repository.scrub_stale_urltest_refs(uci, uciconfig, log);

	/* Reload once, after the whole candidate set is committed
	 * and stale references are scrubbed. The old code stopped
	 * the service before fetching and then did stop+start; the
	 * reload path now validates the new configuration and rolls
	 * back if an instance fails to come up, so the service is
	 * only ever restarted onto a config that passed `sing-box
	 * check`. */
	log('Reloading service...');

	/* Run the init script directly. The previous code called
	 * `init_action('homeproxy', 'reload')` imported from luci.sys, but
	 * neither openwrt/luci nor immortalwrt/luci exports an `init_action`
	 * from that module (it has process_list / conntrack_list /
	 * init_list / init_index / init_enabled), so the import failed to
	 * resolve and this script could not load on a router at all.
	 *
	 * executeCommand() is the package's own runner (homeproxy.uc); unlike
	 * a bare system() call it returns the exit status and the captured
	 * stderr, so a failed reload is recorded instead of disappearing. */
	const reload = executeCommand('/etc/init.d/homeproxy', 'reload');
	if (reload.exitcode !== 0)
		log(sprintf('Warning: reload exited with status %d: %s',
			reload.exitcode, trim(reload.stderr || '')));

	log(sprintf('%s nodes added, %s removed.', added, removed));
	log('Successfully updated subscriptions.');
}

if (!isEmpty(subscription_urls))
	try {
		call(main);
	} catch(e) {
		log('[FATAL ERROR] An error occurred during updating subscriptions:');
		log(sprintf('%s: %s', e.type, e.message));
		log(e.stacktrace[0].context);

		if (config_backup != null) {
			writefile(CONFIG_FILE, config_backup);
			log('Restored the previous configuration; the running service was not stopped.');
		}
	}