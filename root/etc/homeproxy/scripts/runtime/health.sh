# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2025 ImmortalWrt.org
#
# Runtime health helpers for homeproxy.
#
# After a reload the service must be able to answer "did the instance
# actually come up with the new configuration?".  That answer decides whether
# the transaction in runtime/config.sh rolls back, so it is kept here instead
# of being inlined in init.d/homeproxy.
#
# A single "is a matching process alive?" probe is NOT a health check, and the
# first version of this file learned that the hard way (see
# docs/architecture-improvement-plan.md 2.14).  Measured on the test device
# with a configuration whose mixed_port was already taken:
#
#   * procd restarts the crashing instance about once a second, and a STALE
#     sing-box process from an earlier run kept matching `pgrep -f`, so the
#     process check returned success for the whole observation window while
#     the service was dead;
#   * `ubus service list` was correct throughout: `running` flipped false and
#     `exit_code` was 1 whenever it was down;
#   * the configured port WAS listening - owned by the process that had taken
#     it, not by sing-box.  Checking "the port is in the listen table" would
#     therefore have passed too; the listener has to be attributed to an owner.
#
# So the gate is: procd says running, procd does not report a failed exit
# code, the declared listeners are owned by sing-box, and that holds for
# several consecutive samples (a service that binds and then dies must not be
# able to pass on a single lucky poll).
#
# Sourced by /etc/init.d/homeproxy; testable off-target by stubbing pgrep /
# ubus / jsonfilter / netstat (see tests/runtime/).

: "${HP_SERVICE:=homeproxy}"

# How many consecutive healthy samples hp_wait_service requires, and how many
# seconds it may spend trying.
#
# Measured on the test device: procd waits out `procd_set_param respawn`'s
# timeout (5s) before restarting a dead instance, and after a crash-restart
# sequence has exhausted its retries the next start takes longer still.  A
# crash-restart loop produced at most one healthy sample in a row, so 3
# separates the two cases while a healthy start only costs ~3s; but the BUDGET
# has to cover procd's backoff, otherwise the gate gives up on an instance that
# is still coming up (observed with a 15s budget: the rollback restart was
# healthy moments after the gate had already declared failure).
: "${HP_HEALTH_STABLE:=3}"
: "${HP_HEALTH_BUDGET:=30}"

# The rollback restart runs right after a crash-restart sequence has exhausted
# procd's retries, so it gets a longer budget than a normal start.
: "${HP_HEALTH_ROLLBACK_BUDGET:=60}"

# The process name a listening socket must be attributed to.
: "${HP_HEALTH_OWNER:=sing-box}"

# hp_procd_available
# 0 when the procd/ubus state can be queried at all.
hp_procd_available() {
	command -v ubus > "/dev/null" 2>&1 && command -v jsonfilter > "/dev/null" 2>&1
}

# hp_procd_running <instance-name>
# 0 when procd reports the instance as running AND without a non-zero exit
# code.  Both halves matter: during a crash-restart loop `running` flickers
# and `exit_code` is set, and a `running: true` sample taken between two
# failures must not be read as success on its own.
hp_procd_running() {
	local name="$1"
	local state running exit_code

	hp_procd_available || return 1

	state="$(ubus call service list "{\"name\":\"$HP_SERVICE\"}" 2>"/dev/null" \
		| jsonfilter -e "@['$HP_SERVICE'].instances['$name']" 2>"/dev/null")"
	[ -n "$state" ] || return 1

	running="$(printf '%s' "$state" | jsonfilter -e '@.running' 2>"/dev/null")"
	[ "$running" = "true" ] || return 1

	exit_code="$(printf '%s' "$state" | jsonfilter -e '@.exit_code' 2>"/dev/null")"
	case "$exit_code" in
	""|"0") return 0 ;;
	*) return 1 ;;
	esac
}

# hp_instance_running <instance-name> <config-path>
# 0 when the instance is alive.
#
# procd's view comes first: it is the authority on whether the instance it
# supervises is up, and unlike a process scan it cannot be satisfied by a
# stale or orphaned process.  The process scan is only a fallback for hosts
# without ubus, and it is deliberately the weaker evidence.
hp_instance_running() {
	local name="$1"
	local config="$2"

	if hp_procd_running "$name"; then
		return 0
	fi

	# Fallback: accept a matching process only when procd could not be asked
	# at all.  When procd *was* asked and said "not running", that answer
	# wins - a stale process must not override it.
	if ! hp_procd_available; then
		if command -v pgrep > "/dev/null" 2>&1; then
			pgrep -f "run --config $config" > "/dev/null" 2>&1 && return 0
		fi
	fi

	return 1
}

# hp_listener_owned <owner> <port>...
# 0  every port is listening and attributed to <owner>
# 1  a port is missing, or is listening but belongs to something else
# 2  the check cannot be performed here (no netstat, or no owner column)
#
# Attribution is the whole point: in the failure this gate exists for, the
# port was listening - because the process that had taken it was still
# running.  "The port is in the listen table" would have reported success for
# a service that could not bind it.
hp_listener_owned() {
	local owner="$1"
	shift
	local table port

	command -v netstat > "/dev/null" 2>&1 || return 2

	# -p adds the owning pid/name; it needs root, which is how init.d runs.
	table="$(netstat -ltnup 2>"/dev/null")"
	[ -n "$table" ] || return 2
	# Without a "<pid>/<name>" column the attribution cannot be made at all.
	# The header row says "PID/Program name", so the probe has to require a
	# digit before the slash - matching a bare "/" would accept the header.
	case "$table" in
	*[0-9]/*) ;;
	*) return 2 ;;
	esac

	for port in "$@"; do
		[ -n "$port" ] || continue
		if ! printf '%s\n' "$table" | awk -v p="$port" -v o="$owner" '
			$1 ~ /^(tcp|udp)/ {
				# Local address is field 4; its last :/. component
				# is the port.  This reads both ":::5330" and
				# "127.0.0.1.5330".
				n = split($4, a, /[:.]/)
				if (a[n] != p)
					next
				if ($NF ~ ("/" o "$")) {
					found = 1
					exit
				}
			}
			END { exit(found ? 0 : 1) }
		'; then
			return 1
		fi
	done

	return 0
}

# hp_config_ports <config-file>
# Print the ports a generated configuration declares as listeners.
#
# The gate must validate the configuration that is ACTUALLY running, not the
# one UCI currently describes.  After a rollback the live file is the older
# known-good copy, and checking it against the candidate's ports made the gate
# wait forever for a port the restored configuration never binds - a rollback
# that had already brought the service back was reported as failed.
hp_config_ports() {
	grep -o '"listen_port"[[:space:]]*:[[:space:]]*[0-9]\+' "$1" 2>"/dev/null" \
		| grep -o '[0-9]\+$'
}

# hp_service_healthy <instance-name> <config-path> [port...]
# One sample of the gate.  Ports are optional (the server side has no fixed
# listening port worth checking).
hp_service_healthy() {
	local name="$1"
	local config="$2"
	shift 2

	hp_instance_running "$name" "$config" || return 1

	if [ "$#" -gt 0 ]; then
		hp_listener_owned "$HP_HEALTH_OWNER" "$@"
		case "$?" in
		0) ;;
		2)
			# No netstat owner column here.  Say so once instead of
			# silently pretending the listeners were verified.
			if [ -z "${HP_HEALTH_LISTENER_WARNED:-}" ]; then
				HP_HEALTH_LISTENER_WARNED=1
				export HP_HEALTH_LISTENER_WARNED
				log "Warning: cannot verify the listeners on this target (netstat -p unavailable); relying on the procd check only."
			fi
			;;
		*) return 1 ;;
		esac
	fi

	return 0
}

# hp_wait_service <instance-name> <config-path> [budget] [stable] [port...]
# 0 once the instance has been healthy for <stable> consecutive samples,
# within <budget> seconds.  1 on timeout.
hp_wait_service() {
	local name="$1"
	local config="$2"
	local budget="${3:-$HP_HEALTH_BUDGET}"
	local stable="${4:-$HP_HEALTH_STABLE}"
	local good=0 tries=0

	[ "$#" -ge 4 ] && shift 4 || shift "$#"

	while [ "$tries" -lt "$budget" ]; do
		if hp_service_healthy "$name" "$config" "$@"; then
			good=$((good + 1))
			[ "$good" -ge "$stable" ] && return 0
		else
			good=0
		fi

		tries=$((tries + 1))
		[ "$tries" -ge "$budget" ] && break
		sleep 1
	done

	return 1
}

# hp_wait_instance <instance-name> <config-path> [seconds]
# Kept for callers and tests that only want the plain liveness poll.  New code
# should use hp_wait_service: this one cannot tell a crash-restart loop from a
# healthy service.
hp_wait_instance() {
	local name="$1"
	local config="$2"
	local tries="${3:-10}"

	while [ "$tries" -gt 0 ]; do
		hp_instance_running "$name" "$config" && return 0
		sleep 1
		tries=$((tries - 1))
	done

	return 1
}
