# Sourced by the bench scripts: how late dummynet's tick ran on the router
# during a measurement. When its task runs late, dummynet moves its clock
# forward by the ticks it missed (net.inet.ip.dummynet.tick_diff); over a
# run, those as a share of all ticks is the share of time packets waited
# for a late tick: under 1% on a quiet bench with TCP traffic. It reaches
# tens of percent when the router's CPU is busy: with its own work under
# an unpaced UDP flood (expected, 13-28% on the bench), or when its vCPU
# loses the host CPU to other work. Then COBALT sees the extra delay and
# drops more, and TCP throughput and latency results are not comparable
# with a quiet run (README, OPNsense in a VM).
#
#   ticks_mark            remember the counters
#   ticks_late            "ticks late N%" since ticks_mark, flagged at 10%
#                         as "(CPU busy?)"
#
# Reads the router with bench.sh's opn(), which the caller has sourced.

_ticks_read() {
	opn 'echo $(date +%s) $(sysctl -n kern.hz net.inet.ip.dummynet.tick_diff)' 30 | tail -1
}

ticks_mark() {
	_ticks0=$(_ticks_read)
}

ticks_late() {
	set -- $_ticks0 $(_ticks_read)
	if [ $# -ne 6 ]; then
		echo "ticks late ?"
		return
	fi
	awk -v t0="$1" -v hz="$2" -v d0="$3" -v t1="$4" -v d1="$6" 'BEGIN {
		n = (t1 - t0) * hz
		p = (n > 0) ? 100 * (d1 - d0) / n : 0
		printf "ticks late %.1f%%%s\n", p, (p >= 10) ? " (CPU busy?)" : ""
	}'
}
