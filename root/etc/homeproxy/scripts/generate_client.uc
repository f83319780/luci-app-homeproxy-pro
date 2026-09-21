#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Stage PHASE 4 of the architecture refactor:
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

import { mkdtemp, writefile } from 'fs';
import { Loader } from './config/loader.uc';
import { generate } from './generator/client.uc';
import { removeBlankAttrs, RUN_DIR, shellQuote, UCICONFIG_DIR } from './homeproxy.uc';

const dm = Loader.load(UCICONFIG_DIR);
const config = removeBlankAttrs(generate(dm));

system('mkdir -p ' + shellQuote(RUN_DIR));

/* A private scratch directory rather than a fixed `<out>.tmp`.
 *
 * reload_service generates the client and then start_service generates it
 * again, so two runs can overlap (a LuCI apply while the cron entry reloads,
 * or the two ucode invocations inside one reload). With a fixed name both wrote
 * the same file, and `sing-box check` could be validating a file the other run
 * was still writing - the winner then installed a half-written config.
 *
 * mkdtemp() is this package's existing primitive for that (executeCommand()
 * uses it) and gives a 0700 directory under /tmp.  The path here comes from
 * mkdtemp() so it is safe today, but it goes through shellQuote() anyway:
 * review M6's "all shell args quoted" rule is the machine-checkable
 * invariant, not a comment about today's safety. */
const work_dir = mkdtemp();
const tmp = work_dir + '/sing-box-c.json';
writefile(tmp, sprintf('%.J\n', config));

if (system('sing-box check --config ' + shellQuote(tmp)) !== 0) {
	system('rm -rf ' + shellQuote(work_dir));
	exit(1);
}

if (system('mv -f ' + shellQuote(tmp) + ' ' + shellQuote(RUN_DIR) + '/sing-box-c.json') !== 0) {
	system('rm -rf ' + shellQuote(work_dir));
	exit(1);
}

/* The generated config carries every node credential - passwords, UUIDs,
 * private keys - and writefile() has no mode argument, so it lands with the
 * process umask (world-readable at the usual 022).  sing-box runs as its own
 * user and reads the file directly, so 0600 is enough. */
system('chmod 600 ' + shellQuote(RUN_DIR) + '/sing-box-c.json');

system('rm -rf ' + shellQuote(work_dir));