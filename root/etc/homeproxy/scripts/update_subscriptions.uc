#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2023 ImmortalWrt.org
 */

'use strict';

import { md5 } from 'digest';
import { open } from 'fs';
import { connect } from 'ubus';
import { cursor } from 'uci';

import { init_action } from 'luci.sys';

import {
	wGETVerbose, getTime, isEmpty, HP_DIR, RUN_DIR
} from 'homeproxy';

import { parse_uri } from 'parse_uri';

import { check as filter_check, apply_policy } from './subscription/filter.uc';
import { decode as decode_subscription } from './subscription/decoder.uc';
import { fetch as fetch_subscription } from './subscription/fetcher.uc';
import { apply as repository_apply } from './subscription/repository.uc';

/* UCI config start */
const uci = cursor();

const uciconfig = 'homeproxy';
uci.load(uciconfig);

const ucimain = 'config',
      ucinode = 'node',
      ucisubscription = 'subscription';

const allow_insecure = uci.get(uciconfig, ucisubscription, 'allow_insecure') || '0',
      filter_mode = uci.get(uciconfig, ucisubscription, 'filter_nodes') || 'disabled',
      filter_keywords = uci.get(uciconfig, ucisubscription, 'filter_keywords') || [],
      packet_encoding = uci.get(uciconfig, ucisubscription, 'packet_encoding') || 'xudp',
      subscription_urls = uci.get(uciconfig, ucisubscription, 'subscription_url') || [],
      user_agent = uci.get(uciconfig, ucisubscription, 'user_agent'),
      via_proxy = uci.get(uciconfig, ucisubscription, 'update_via_proxy') || '0';

const routing_mode = uci.get(uciconfig, ucimain, 'routing_mode') || 'bypass_mainland_china';
let main_node, main_udp_node;
if (routing_mode !== 'custom') {
	main_node = uci.get(uciconfig, ucimain, 'main_node') || 'nil';
	main_udp_node = uci.get(uciconfig, ucimain, 'main_udp_node') || 'nil';
}
/* UCI config end */

/* String helper start */
/* B1.1: filter_check() moved to subscription/filter.uc; the
 * pure logic now takes mode + keywords + log as arguments so the
 * filter is testable without UCI access. The orchestrator keeps
 * the same call site shape - just adds the explicit args. */
/* String helper end */

/* Common var start */
const node_cache = {},
      node_result = [];

const ubus = connect();
/* ubus is unreachable when no ubusd is running (dev host) and the feature
   query is optional: fall back to the same empty feature set the code below
   already handles. */
const sing_features = (ubus?.call('luci.homeproxy', 'singbox_get_features', {})) || {};
if (isEmpty(sing_features))
	log('Warning: Failed to query sing-box features via ubus, assuming defaults.');
/* Common var end */

/* Log */
system(`mkdir -p ${RUN_DIR}`);
function log(...args) {
	const logfile = open(`${RUN_DIR}/homeproxy.log`, 'a');
	logfile.write(`${getTime()} [SUBSCRIBE] ${join(' ', args)}\n`);
	logfile.close();
}

function main() {
	if (via_proxy !== '1') {
		log('Stopping service...');
		init_action('homeproxy', 'stop');
	}

	for (let url in subscription_urls) {
		url = replace(url, /#.*$/, '');
		const groupHash = md5(url);
		node_cache[groupHash] = {};

		/* B1.2: fetch + decode pipeline. The fetcher logs its
		 * own failure (so the orchestrator does not need to know
		 * the wGETVerbose error shape) and returns null content
		 * on failure; the decoder handles JSON/SIP008/base64. */
		const fetched = fetch_subscription(url, user_agent, log);
		if (fetched.content === null)
			continue;

		const nodes = decode_subscription(fetched.content, log, url);

		let count = 0;
		for (let node in nodes) {
			let config;
			if (!isEmpty(node))
				config = parse_uri(node, sing_features, log);
			if (isEmpty(config))
				continue;

			const label = config.label;
			config.label = null;
			const confHash = md5(sprintf('%J', config)),
			      nameHash = md5(groupHash + label);
			config.label = label;

			if (filter_check(config.label, filter_mode, filter_keywords, log))
				log(sprintf('Skipping blacklist node: %s.', config.label));
			else if (node_cache[groupHash][confHash] || node_cache[groupHash][nameHash])
				log(sprintf('Skipping duplicate node: %s.', config.label));
			else {
				/* B1.1: tls_insecure override and vless/vmess
				 * packet_encoding injection moved to
				 * subscription/filter.uc. */
				apply_policy(config, { allow_insecure, packet_encoding });

				config.grouphash = groupHash;
				push(node_result, []);
				push(node_result[length(node_result)-1], config);
				node_cache[groupHash][confHash] = config;
				node_cache[groupHash][nameHash] = config;

				count++;
			}
		}

		if (count === 0)
			log(sprintf('No valid node found in %s.', url));
		else
			log(sprintf('Successfully fetched %s nodes of total %s from %s.', count, length(nodes), url));
	}

	if (isEmpty(node_result)) {
		log('Failed to update subscriptions: no valid node found.');

		if (via_proxy !== '1') {
			log('Starting service...');
			init_action('homeproxy', 'start');
		}

		return false;
	}

	/* B1.2: the add / update / remove walk and the final commit
	 * now live in subscription/repository.uc. The orchestrator
	 * just hands it the cache + result built during the fetch
	 * phase and uses the { added, removed } counts for the
	 * end-of-run log. */
	/* Object destructuring is not part of the dialect the ucode on the
	 * target accepts (ImmortalWrt ucode 2026.01.16 rejects
	 * `const { a, b } = ...` with "Expecting variable name"), so pull
	 * the two counts out by name instead. */
	const repository_result = repository_apply(
		uci, uciconfig, ucinode, node_cache, node_result, log
	);
	const added = repository_result.added,
	      removed = repository_result.removed;

	let need_restart = (via_proxy !== '1');
	if (!isEmpty(main_node)) {
		const first_server = uci.get_first(uciconfig, ucinode);
		if (first_server) {
			let main_urltest_nodes;
			if (main_node === 'urltest') {
				const old_urltest_nodes = uci.get(uciconfig, ucimain, 'main_urltest_nodes') || [];
				main_urltest_nodes = filter(old_urltest_nodes, (v) => {
					if (!uci.get(uciconfig, v)) {
						log(sprintf('Node %s is gone, removing from urltest list.', v));
						return false;
					}
					return true;
				});
				if (length(main_urltest_nodes) !== length(old_urltest_nodes)) {
					uci.set(uciconfig, ucimain, 'main_urltest_nodes', main_urltest_nodes);
					uci.commit(uciconfig);
					need_restart = true;
				}
			}

			if ((main_node === 'urltest') ? !length(main_urltest_nodes) : !uci.get(uciconfig, main_node)) {
				uci.set(uciconfig, ucimain, 'main_node', first_server);
				uci.commit(uciconfig);
				need_restart = true;

				log('Main node is gone, switching to the first node.');
			}

			if (!isEmpty(main_udp_node) && main_udp_node !== 'same') {
				let main_udp_urltest_nodes;
				if (main_udp_node === 'urltest') {
					const old_udp_urltest_nodes = uci.get(uciconfig, ucimain, 'main_udp_urltest_nodes') || [];
					main_udp_urltest_nodes = filter(old_udp_urltest_nodes, (v) => {
						if (!uci.get(uciconfig, v)) {
							log(sprintf('Node %s is gone, removing from urltest list.', v));
							return false;
						}
						return true;
					});
					if (length(main_udp_urltest_nodes) !== length(old_udp_urltest_nodes)) {
						uci.set(uciconfig, ucimain, 'main_udp_urltest_nodes', main_udp_urltest_nodes);
						uci.commit(uciconfig);
						need_restart = true;
					}
				}

				if ((main_udp_node === 'urltest') ? !length(main_udp_urltest_nodes) : !uci.get(uciconfig, main_udp_node)) {
					uci.set(uciconfig, ucimain, 'main_udp_node', first_server);
					uci.commit(uciconfig);
					need_restart = true;

					log('Main UDP node is gone, switching to the first node.');
				}
			}
		} else {
			uci.set(uciconfig, ucimain, 'main_node', 'nil');
			uci.set(uciconfig, ucimain, 'main_udp_node', 'nil');
			uci.commit(uciconfig);
			need_restart = true;

			log('No available node, disable tproxy.');
		}
	}

	/* Scrub stale urltest member references in custom routing nodes */
	uci.foreach(uciconfig, 'routing_node', (cfg) => {
		if (cfg.node !== 'urltest' || isEmpty(cfg.urltest_nodes))
			return null;

		const cleaned_nodes = filter(cfg.urltest_nodes, (v) => uci.get(uciconfig, v));
		if (length(cleaned_nodes) !== length(cfg.urltest_nodes)) {
			uci.set(uciconfig, cfg['.name'], 'urltest_nodes', cleaned_nodes);
			uci.commit(uciconfig);
			need_restart = true;

			log(sprintf('Routing node %s: removed gone nodes from urltest list.', cfg['.name']));
		}
	});

	if (need_restart) {
		log('Restarting service...');
		init_action('homeproxy', 'stop');
		init_action('homeproxy', 'start');
	}

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

		log('Restarting service...');
		init_action('homeproxy', 'stop');
		init_action('homeproxy', 'start');
	}
