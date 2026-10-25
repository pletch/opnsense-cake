/*
 * dn_sched_cake's COBALT, extracted from sys/netpfil/ipfw/dn_sched_cake.[ch]
 * by cobalt-diff.sh into ours-cobalt.inc, built in userland.
 */
#include <stdint.h>
#include <string.h>

#include "cobalt.h"

struct mbuf {
	int	ecn_capable;
};

static uint64_t rng;

static uint32_t
arc4random(void)
{
	/* splitmix64; the same generator stands in for get_random_u32() */
	uint64_t z = (rng += 0x9e3779b97f4a7c15ULL);

	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
	z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
	return ((uint32_t)((z ^ (z >> 31)) >> 32));
}

static int
ecn_mark(struct mbuf *m)
{
	return (m->ecn_capable);
}

#include "ours-cobalt.inc"

static struct cobalt_vars v;

/* always its own start; upstream_init only changes sch_cake's */
static void
o_init(int upstream_init)
{
	(void)upstream_init;
	cobalt_vars_init(&v);
}

static void
o_seed(uint64_t seed)
{
	rng = seed;
}

static void
o_params(struct cobalt_params *p, const struct cd_params *c)
{
	p->target = c->target;
	p->interval = c->interval;
	p->mtu_time = c->mtu_time;
	p->p_inc = c->p_inc;
	p->p_dec = c->p_dec;
}

static int
o_should_drop(const struct cd_params *c, uint64_t now, uint64_t enq_ts,
	int ecn_capable, uint32_t bulk_flows, int *marked)
{
	struct cobalt_params p;
	struct mbuf m = { ecn_capable };

	o_params(&p, c);
	return (cobalt_should_drop(&v, &p, now, enq_ts, &m, 1, marked,
	    bulk_flows));
}

static int
o_queue_full(const struct cd_params *c, uint64_t now)
{
	struct cobalt_params p;

	o_params(&p, c);
	return (cobalt_queue_full(&v, &p, now));
}

static int
o_queue_empty(const struct cd_params *c, uint64_t now)
{
	struct cobalt_params p;

	o_params(&p, c);
	return (cobalt_queue_empty(&v, &p, now));
}

static void
o_state(struct cd_state *s)
{
	s->count = v.count;
	s->rec_inv_sqrt = v.rec_inv_sqrt;
	s->drop_next = v.drop_next;
	s->blue_timer = v.blue_timer;
	s->p_drop = v.p_drop;
	s->dropping = v.dropping != 0;
}

const struct cobalt_impl ours_impl = {
	"dn_sched_cake", o_init, o_seed, o_should_drop, o_queue_full,
	o_queue_empty, o_state
};
