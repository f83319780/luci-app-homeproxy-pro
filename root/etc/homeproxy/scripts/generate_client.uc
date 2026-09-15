#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Stage PHASE 4 of the architecture refactor (see
 * homeproxy_architecture_refactor_agent_guide.md):
 *
 *     scripts/generate_client.uc: 10-line CLI shell.
 *
 * The actual client generator is generator/client.uc; this script is the
 * thin entry point that init.d/homeproxy execve's. Responsibilities:
 *
 *   1. Load UCI into the HomeProxyConfig domain model.
 *   2. Call generate() to get the sing-box JSON object.
 *   3. Write atomically: candidate tmp -> `sing-box check` -> mv to live.
 *
 * The check is here (and not in the runtime, and not in the generator)
 * because the architecture guide mandates the generator produce
 * "atomic write candidate + serialization" and the runtime is already
 * structured around "a failing generation leaves the previous file in
 * place" (see runtime/config.sh's hp_ensure_live). Having the shell do
 * the check keeps that contract single-sourced.
 */

'use strict';

import { writefile } from 'fs';
import { Loader } from './config/loader.uc';
import { generate } from './generator/client.uc';
import { removeBlankAttrs, RUN_DIR, UCICONFIG_DIR } from 'homeproxy';

const dm = Loader.load(UCICONFIG_DIR);
const config = removeBlankAttrs(generate(dm));

system('mkdir -p ' + RUN_DIR);
const tmp = RUN_DIR + '/sing-box-c.json.tmp';
writefile(tmp, sprintf('%.J\n', config));

if (system('sing-box check --config ' + tmp) !== 0) {
	system('rm -f ' + tmp);
	exit(1);
}

system('mv -f ' + tmp + ' ' + RUN_DIR + '/sing-box-c.json');