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

import { writefile } from 'fs';
import { Loader } from './config/loader.uc';
import { generate_server } from './generator/server.uc';
import { removeBlankAttrs, RUN_DIR, UCICONFIG_DIR } from 'homeproxy';

const dm = Loader.load(UCICONFIG_DIR);
const config = generate_server(dm);
if (!config)
	exit(1);

const cleaned = removeBlankAttrs(config);
system('mkdir -p ' + RUN_DIR);
const tmp = RUN_DIR + '/sing-box-s.json.tmp';
writefile(tmp, sprintf('%.J\n', cleaned));

if (system('sing-box check --config ' + tmp) !== 0) {
	system('rm -f ' + tmp);
	exit(1);
}

system('mv -f ' + tmp + ' ' + RUN_DIR + '/sing-box-s.json');