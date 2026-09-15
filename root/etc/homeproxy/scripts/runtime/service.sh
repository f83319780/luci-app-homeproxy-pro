# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2025 ImmortalWrt.org
#
# Service-side runtime helpers for homeproxy (PR-05: PHASE 7 extraction).
#
# These are the device-side orchestration pieces that used to be inlined in
# /etc/init.d/homeproxy: the sing-box version gate, the auto-update cron
# entry, the runtime-file preparation, the procd instance registrations and
# the "generate -> known-good" transaction that start_service runs for each
# side.
#
# Layering note (see docs/architecture-improvement-plan.md §2.10): unlike
# runtime/config.sh and runtime/health.sh - which are deliberately pure and
# only take explicit paths - the modules extracted by PR-05 are device-side
# by nature.  They call `log`, `config_get` and `procd_*`, so a caller must
# have run `config_load` and must be inside a procd init context.  That is
# exactly why they were moved out of init.d and not turned into pure helpers.
#
# Sourced by /etc/init.d/homeproxy.

# hp_require_singbox
# Refuse to start on a sing-box older than 1.14: the generated configuration
# uses 1.14-only fields, and an older binary would reject it at run time
# instead of failing here.  Returns 1 (and logs) when unusable.
#
# `sing-box` is looked up through PATH, exactly as the pre-PR-05 init script
# did - it is deliberately not PROG, so a PATH mismatch between the two is
# not silently introduced by this refactor.
hp_require_singbox() {
	local sb_ver sb_major sb_minor

	sb_ver="$(sing-box version -n 2>/dev/null)"
	if [ -z "$sb_ver" ]; then
		log "Error: cannot detect sing-box version, abort."
		return 1
	fi

	sb_major="${sb_ver%%.*}"
	sb_minor="${sb_ver#*.}"
	sb_minor="${sb_minor%%.*}"

	if [ "$sb_major" -lt 1 ] || { [ "$sb_major" -eq 1 ] && [ "$sb_minor" -lt 14 ]; }; then
		log "Error: sing-box >= 1.14.0 required, found ${sb_ver}."
		return 1
	fi

	return 0
}

# hp_crontab_drop <crontab>
# Remove the auto-update entry from <crontab>.
#
# Not `sed -i`: the bare `-i` form is a busybox/GNU extension, and on a host with
# BSD sed it fails ("invalid command code"), which silently left the stale entry
# behind with only a warning in the log.  Editing through a temporary file
# behaves identically on busybox, GNU and BSD sed, and it is what lets this
# module be exercised off-target at all
# (tests/runtime/test_runtime_extraction.sh stages and drives it).
hp_crontab_drop() {
	local crontab="$1"
	local tmp="${crontab}.hp-new"

	sed "/#${CONF}_autosetup/d" "$crontab" > "$tmp" 2>"/dev/null" || { rm -f "$tmp"; return 1; }
	mv -f "$tmp" "$crontab" 2>"/dev/null" || { rm -f "$tmp"; return 1; }

	return 0
}

# hp_sync_autoupdate_cron <enabled> <hour>
# Install (or drop) the subscription auto-update cron entry.  <enabled> is a
# config_get_bool result; the entry is only touched when it is "1".
hp_sync_autoupdate_cron() {
	local auto_update="$1"
	local auto_update_time="$2"

	[ "$auto_update" = "1" ] || return 0

	hp_crontab_drop "/etc/crontabs/root" \
		|| log "Warning: failed to drop the previous auto-update cron entry."
	echo -e "0 $auto_update_time * * * $HP_DIR/scripts/update_crond.sh #${CONF}_autosetup" >> "/etc/crontabs/root" \
		|| log "Warning: failed to install the auto-update cron entry."
	/etc/init.d/cron restart >"/dev/null" 2>&1 || log "Warning: failed to restart cron."
}

# hp_clear_autoupdate_cron
# Drop the auto-update cron entry and restart cron.  Used by stop_service.
hp_clear_autoupdate_cron() {
	hp_crontab_drop "/etc/crontabs/root" \
		|| log "Warning: failed to drop the auto-update cron entry."
	/etc/init.d/cron restart >"/dev/null" 2>&1 || log "Warning: failed to restart cron."
}

# hp_prepare_runtime_files <hp-dir> <run-dir> <routing-mode> <client> <server>
# Create the mode-specific working files, truncate the instance logs and hand
# every runtime file to the sing-box user.  <client>/<server> are "1"/"0".
hp_prepare_runtime_files() {
	local hp_dir="$1"
	local run_dir="$2"
	local routing_mode="$3"
	local client_enabled="$4"
	local server_enabled="$5"

	case "$routing_mode" in
	"bypass_mainland_china")
		[ -e "$hp_dir/cache.db" ] || touch "$hp_dir/cache.db" \
			|| log "Warning: failed to create ${hp_dir}/cache.db."
		;;
	"custom")
		[ -d "$hp_dir/ruleset" ] || mkdir -p "$hp_dir/ruleset" \
			|| log "Warning: failed to create ${hp_dir}/ruleset."
		;;
	esac

	[ "$client_enabled" = "1" ] && echo > "$run_dir/sing-box-c.log"
	if [ "$server_enabled" = "1" ]; then
		echo > "$run_dir/sing-box-s.log"
		mkdir -p "$hp_dir/certs" || log "Warning: failed to create ${hp_dir}/certs."
	fi

	chown sing-box:sing-box "$run_dir"/sing-box-*.json "$run_dir"/sing-box-*.log "$hp_dir"/cache.db 2>"/dev/null" \
		|| log "Warning: failed to change the ownership of the runtime files to sing-box."
}

# hp_procd_client_instance <prog> <hp-dir> <run-dir> <routing-mode> <disable-gso>
# Register the sing-box client instance.  The ujail gate is client-specific:
# a custom routing table or a wireguard/tun outbound needs filesystem paths a
# jail cannot provide.  The `procd_append_param command` text below is what
# runtime/health.sh's pgrep pattern matches - change both together.
hp_procd_client_instance() {
	local prog="$1"
	local hp_dir="$2"
	local run_dir="$3"
	local routing_mode="$4"
	local disable_gso="$5"

	procd_open_instance "sing-box-c"

	procd_set_param command "$prog"
	procd_append_param command run --config "$run_dir/sing-box-c.json"

	[ "$disable_gso" -eq "1" ] && procd_set_param env "QUIC_GO_DISABLE_GSO"="true"

	if [ -x "/sbin/ujail" ] && [ "$routing_mode" != "custom" ] && ! grep -Eq '"type": "(wireguard|tun)"' "$run_dir/sing-box-c.json"; then
		procd_add_jail "sing-box-c" log procfs
		procd_add_jail_mount "$run_dir/sing-box-c.json"
		procd_add_jail_mount_rw "$run_dir/sing-box-c.log"
		[ "$routing_mode" != "bypass_mainland_china" ] || procd_add_jail_mount_rw "$hp_dir/cache.db"
		procd_add_jail_mount "$hp_dir/certs/"
		procd_add_jail_mount "/etc/ssl/"
		procd_add_jail_mount "/etc/localtime"
		procd_add_jail_mount "/etc/TZ"
		procd_set_param capabilities "/etc/capabilities/homeproxy.json"
		procd_set_param no_new_privs 1
		procd_set_param user sing-box
		procd_set_param group sing-box
	fi

	procd_set_param limits core="unlimited"
	procd_set_param limits nofile="1000000 1000000"
	procd_set_param stderr 1
	procd_set_param respawn

	procd_close_instance
}

# hp_procd_server_instance <prog> <hp-dir> <run-dir> <disable-gso>
# Register the sing-box server instance.  The jail only depends on ujail
# being installed, and it needs the certificate/ACME material instead of the
# client's cache.db.
hp_procd_server_instance() {
	local prog="$1"
	local hp_dir="$2"
	local run_dir="$3"
	local disable_gso="$4"

	procd_open_instance "sing-box-s"

	procd_set_param command "$prog"
	procd_append_param command run --config "$run_dir/sing-box-s.json"

	[ "$disable_gso" -eq "1" ] && procd_set_param env "QUIC_GO_DISABLE_GSO"="true"

	if [ -x "/sbin/ujail" ]; then
		procd_add_jail "sing-box-s" log procfs
		procd_add_jail_mount "$run_dir/sing-box-s.json"
		procd_add_jail_mount_rw "$run_dir/sing-box-s.log"
		procd_add_jail_mount_rw "$hp_dir/certs/"
		procd_add_jail_mount "/etc/acme/"
		procd_add_jail_mount "/etc/ssl/"
		procd_add_jail_mount "/etc/localtime"
		procd_add_jail_mount "/etc/TZ"
		procd_set_param capabilities "/etc/capabilities/homeproxy.json"
		procd_set_param no_new_privs 1
		procd_set_param user sing-box
		procd_set_param group sing-box
	fi

	procd_set_param limits core="unlimited"
	procd_set_param limits nofile="1000000 1000000"
	procd_set_param stderr 1
	procd_set_param respawn

	procd_close_instance
}

# hp_procd_log_cleaner <hp-dir>
# Register the log-rotator instance.  It is unconditional: it also has to run
# when neither client nor server is enabled.
hp_procd_log_cleaner() {
	local hp_dir="$1"

	procd_open_instance "log-cleaner"
	procd_set_param command "$hp_dir/scripts/clean_log.sh"
	procd_set_param respawn
	procd_close_instance
}

# hp_start_generated_config <side> <hp-dir> <run-dir> <good-dir>
# The start-path transaction for one side ("c" or "s"):
#
#   HP_USE_KNOWN_GOOD=1 -> copy the recorded configuration over the live one
#                          instead of regenerating (the generator is a pure
#                          function of UCI, so it would rebuild the very file
#                          that just failed)
#   otherwise           -> generate, then make sure a live file exists,
#                          falling back to the known-good copy when it does not
#
# Returns 1 only when there is nothing to run at all (generation failed and
# no known-good copy exists), which is what made start_service bail out.
#
# It deliberately does NOT touch the known-good copy any more.  It used to
# record the freshly generated file immediately, which meant that by the time
# the health gate ran, the "previous" configuration the rollback would need had
# already been overwritten by the candidate - so a failed reload had nothing to
# roll back to.  Promotion is now a separate step, taken only after the gate
# has passed (hp_promote_known_good, called from start_service).
hp_start_generated_config() {
	local side="$1"
	local hp_dir="$2"
	local run_dir="$3"
	local good_dir="$4"
	local label generator live good

	case "$side" in
	c) label="client"; generator="$hp_dir/scripts/generate_client.uc" ;;
	s) label="server"; generator="$hp_dir/scripts/generate_server.uc" ;;
	*) log "Error: unknown configuration side '${side}'."; return 1 ;;
	esac

	live="$run_dir/sing-box-${side}.json"
	good="$good_dir/sing-box-${side}.json"

	if [ "${HP_USE_KNOWN_GOOD:-0}" = "1" ] && [ -s "$good" ]; then
		# Rollback path: start from the recorded configuration instead
		# of regenerating.  Regenerating would rebuild the very config
		# that just failed to come up, because the generator is a pure
		# function of UCI.
		log "Starting with the last known-good ${label} configuration."
		cp -f "$good" "$live"
		return 0
	fi

	ucode -S "$generator" 2>>"$LOG_PATH"

	# The generator is transactional on its own: it writes a temporary file
	# and only renames it over the live one once `sing-box check` accepted
	# it.  A failed generation therefore leaves the previous file untouched -
	# and that is the only `sing-box check` in this path (the runtime used to
	# run a second one on the same file).
	hp_ensure_live "$live" "$good"
	case "$?" in
	0)
		;;
	1)
		log "Error: failed to generate a valid ${label} configuration; falling back to the last known-good one." ;;
	*)
		log "Error: failed to generate ${label} configuration."
		return 1 ;;
	esac

	return 0
}

# hp_promote_known_good <side> <run-dir> <good-dir>
# Record the live configuration as the new known-good copy.  Called only after
# the health gate has proven that the configuration actually runs, so the
# rollback target is always something that came up.
hp_promote_known_good() {
	local side="$1"
	local run_dir="$2"
	local good_dir="$3"
	local label

	case "$side" in
	c) label="client" ;;
	s) label="server" ;;
	*) log "Error: unknown configuration side '${side}'."; return 1 ;;
	esac

	hp_known_good "$run_dir/sing-box-${side}.json" "$good_dir/sing-box-${side}.json" \
		|| log "Warning: could not refresh the known-good ${label} configuration."
}

