#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Stage PHASE 4 of the architecture refactor (see
 * homeproxy_architecture_refactor_agent_guide.md):
 *
 *     scripts/generate_server.uc: 10-line CLI shell.
 *
 * Mirror of scripts/generate_client.uc for the server instance. The
 * server generator (generator/server.uc) returns null when no inbound
 * is enabled; the shell then exits 1 so init.d can detect
 * "server disabled" without a separate UCI check.
 */

'use strict';

import { mkdtemp, writefile } from 'fs';
import { Loader } from './config/loader.uc';
import { generate_server } from './generator/server.uc';
import { removeBlankAttrs, RUN_DIR, UCICONFIG_DIR } from './homeproxy.uc';

const dm = Loader.load(UCICONFIG_DIR);
const config = generate_server(dm);
if (!config)
	exit(1);

const cleaned = removeBlankAttrs(config);
system('mkdir -p ' + RUN_DIR);

/* A private scratch directory rather than a fixed `<out>.tmp`.
 *
 * reload_service generates the client and then start_service generates it
 * again, so two runs can overlap (a LuCI apply while the cron entry reloads,
 * or the two ucode invocations inside one reload). With a fixed name both wrote
 * the same file, and `sing-box check` could be validating a file the other run
 * was still writing - the winner then installed a half-written config.
 *
 * mkdtemp() is this package's existing primitive for that (executeCommand()
 * uses it) and gives a 0700 directory under /tmp. */
const work_dir = mkdtemp();
const tmp = work_dir + '/sing-box-s.json';
writefile(tmp, sprintf('%.J\n', cleaned));

if (system('sing-box check --config ' + tmp) !== 0) {
	system('rm -rf ' + work_dir);
	exit(1);
}

if (system('mv -f ' + tmp + ' ' + RUN_DIR + '/sing-box-s.json') !== 0) {
	system('rm -rf ' + work_dir);
	exit(1);
}

system('rm -rf ' + work_dir);