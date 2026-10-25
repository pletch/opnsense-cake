/*
 * Common interface to one COBALT implementation, for cobalt-diff: each of
 * ours.c and linux.c wraps its implementation in these calls. Times are
 * in microseconds for both; sch_cake's arithmetic does not depend on the
 * unit, so with the same inputs both must compute the same state.
 */
#ifndef COBALT_DIFF_H
#define COBALT_DIFF_H

#include <stdint.h>

struct cd_params {
	uint64_t	target;
	uint64_t	interval;
	uint64_t	mtu_time;
	uint32_t	p_inc;
	uint32_t	p_dec;
};

struct cd_state {
	uint32_t	count;
	uint32_t	rec_inv_sqrt;
	uint64_t	drop_next;
	uint64_t	blue_timer;
	uint32_t	p_drop;
	int		dropping;
};

/* result of a dequeue: 0 deliver, 1 drop; *marked set for an ECN mark */
struct cobalt_impl {
	const char *name;
	void	(*init)(int upstream_init);
	void	(*seed)(uint64_t seed);
	int	(*should_drop)(const struct cd_params *, uint64_t now,
		    uint64_t enq_ts, int ecn_capable, uint32_t bulk_flows,
		    int *marked);
	/* both return whether BLUE turned on (full) or off (empty) */
	int	(*queue_full)(const struct cd_params *, uint64_t now);
	int	(*queue_empty)(const struct cd_params *, uint64_t now);
	void	(*state)(struct cd_state *);
};

extern const struct cobalt_impl ours_impl, linux_impl;

#endif
