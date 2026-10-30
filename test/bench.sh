# test/bench.sh: sourced by the bench test scripts. The bench is an
# OPNsense test VM (root over ssh) and a client VM whose two test NICs sit
# in network namespaces cli (cli0, 10.10.1.2) and srv (srv0, 10.10.2.2),
# routed through the OPNsense VM (vtnet2 10.10.1.1, vtnet3 10.10.2.1; see
# lul-netns.sh, which the client runs at boot, and lul-setup.sh). Set:
#
#   OPN=root@192.0.2.10       the OPNsense VM
#   OPN_KEY=~/.ssh/bench      its ssh key, and OPN_KNOWN, a known_hosts file
#   CLI=debian@192.0.2.11     the client VM (passwordless sudo)
#   CLI_KEY, CLI_KNOWN        the same for it
#   PROX=root@proxmox PROX_VMID=210
#                             optional: the Proxmox host and the OPNsense
#                             VM's id, for tests that suspend the VM
#
# for example in a file that is sourced before the tests and kept outside
# the repository.

: "${OPN:?OPN: ssh destination of the OPNsense test VM, e.g. root@192.0.2.10}"
: "${CLI:?CLI: ssh destination of the client VM, e.g. debian@192.0.2.11}"

# ssh options for one VM: key and known_hosts, when set
_bench_ssh() { # key known_hosts
	printf -- '-o BatchMode=yes -o ConnectTimeout=10'
	[ -n "$1" ] && printf ' -i %s -o IdentitiesOnly=yes' "$1"
	[ -n "$2" ] && printf ' -o UserKnownHostsFile=%s' "$2"
}
_BENCH_OPN_SSH=$(_bench_ssh "${OPN_KEY:-}" "${OPN_KNOWN:-}")
_BENCH_CLI_SSH=$(_bench_ssh "${CLI_KEY:-}" "${CLI_KNOWN:-}")

# run a command on OPNsense (sh; root's login shell is not), print its
# output and errors, return its exit status; the second argument is a
# time limit in seconds (default 120)
opn() {
	# shellcheck disable=SC2086
	printf '( %s ) 2>&1\n' "$1" |
	    timeout "${2:-120}" ssh -q $_BENCH_OPN_SSH "$OPN" sh -s
}

# run a command on the client VM (its own shell, as ssh runs it)
cli() {
	# shellcheck disable=SC2086
	ssh -n -q $_BENCH_CLI_SSH "$CLI" "$@"
}

# copy local files to a directory (or a file) on OPNsense
put() { # file... destination
	_dst=$(eval "printf %s \"\${$#}\"")
	_n=$#
	_i=1
	for _f in "$@"; do
		[ $_i -lt $_n ] || break
		# shellcheck disable=SC2086
		scp -q $_BENCH_OPN_SSH "$_f" "$OPN:$_dst" || return 1
		_i=$((_i + 1))
	done
}

# copy a file from the client VM to a local path
cli_get() { # remote local
	# shellcheck disable=SC2086
	scp -q $_BENCH_CLI_SSH "$CLI:$1" "$2"
}

# the CPU time the OPNsense VM's process has used on the Proxmox host, in
# the host's clock ticks, then the host's ticks per second; returns 77
# when PROX and PROX_VMID are not set
vm_host_cpu() {
	[ -n "${PROX:-}" ] && [ -n "${PROX_VMID:-}" ] || return 77
	ssh -o BatchMode=yes "$PROX" "awk '{ print \$14 + \$15 }' \
	    /proc/\$(cat /var/run/qemu-server/$PROX_VMID.pid)/stat; getconf CLK_TCK" |
	    tr '\n' ' '
}

# suspend the OPNsense VM for N seconds, as a stopped or suspended VM is;
# returns 77 when PROX and PROX_VMID are not set (the caller skips)
vm_pause() { # seconds
	[ -n "${PROX:-}" ] && [ -n "${PROX_VMID:-}" ] || return 77
	ssh -o BatchMode=yes "$PROX" \
	    "qm suspend $PROX_VMID && sleep $1 && qm resume $PROX_VMID"
}
