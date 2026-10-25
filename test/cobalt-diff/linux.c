/*
 * Linux sch_cake's COBALT, extracted from net/sched/sch_cake.c by
 * cobalt-diff.sh into linux-cobalt.inc, built in userland with stand-ins
 * for the kernel helpers it uses.
 */
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "cobalt.h"

typedef uint32_t u32;
typedef uint64_t u64;
typedef int64_t s64;
typedef s64 ktime_t;

#define WRITE_ONCE(x, val)	((x) = (val))
#define ktime_sub(a, b)		((a) - (b))
#define ktime_add_ns(a, n)	((a) + (s64)(n))
#define ktime_to_ns(t)		(t)

enum qdisc_drop_reason {
	QDISC_DROP_UNSPEC,
	QDISC_DROP_CONGESTED,
	QDISC_DROP_FLOOD_PROTECTION
};

struct sk_buff {
	ktime_t	enqueue_time;
	int	ecn_capable;
};

/* include/linux/reciprocal_div.h */
static inline u32
reciprocal_scale(u32 val, u32 ep_ro)
{
	return (u32)(((u64)val * ep_ro) >> 32);
}

static uint64_t rng;

static u32
get_random_u32(void)
{
	uint64_t z = (rng += 0x9e3779b97f4a7c15ULL);

	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
	z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
	return ((u32)((z ^ (z >> 31)) >> 32));
}

static bool
INET_ECN_set_ce(struct sk_buff *skb)
{
	return (skb->ecn_capable);
}

static ktime_t
cobalt_get_enqueue_time(const struct sk_buff *skb)
{
	return (skb->enqueue_time);
}

#include "linux-cobalt.inc"

static struct cobalt_vars v;

static void
l_init(int upstream_init)
{
	cobalt_vars_init(&v);
	/* dn_sched_cake starts at 1/sqrt(1); see cobalt_vars_init() there */
	if (!upstream_init)
		v.rec_inv_sqrt = ~0U;
}

static void
l_seed(uint64_t seed)
{
	rng = seed;
}

static void
l_params(struct cobalt_params *p, const struct cd_params *c)
{
	p->target = c->target;
	p->interval = c->interval;
	p->mtu_time = c->mtu_time;
	p->p_inc = c->p_inc;
	p->p_dec = c->p_dec;
}

static int
l_should_drop(const struct cd_params *c, uint64_t now, uint64_t enq_ts,
	int ecn_capable, uint32_t bulk_flows, int *marked)
{
	struct cobalt_params p;
	struct sk_buff skb = { (ktime_t)enq_ts, ecn_capable };
	enum qdisc_drop_reason r;

	l_params(&p, c);
	r = cobalt_should_drop(&v, &p, (ktime_t)now, &skb, bulk_flows);
	*marked = v.ecn_marked;
	return (r != QDISC_DROP_UNSPEC);
}

static int
l_queue_full(const struct cd_params *c, uint64_t now)
{
	struct cobalt_params p;

	l_params(&p, c);
	return (cobalt_queue_full(&v, &p, (ktime_t)now));
}

static int
l_queue_empty(const struct cd_params *c, uint64_t now)
{
	struct cobalt_params p;

	l_params(&p, c);
	return (cobalt_queue_empty(&v, &p, (ktime_t)now));
}

static void
l_state(struct cd_state *s)
{
	s->count = v.count;
	s->rec_inv_sqrt = v.rec_inv_sqrt;
	s->drop_next = (uint64_t)v.drop_next;
	s->blue_timer = (uint64_t)v.blue_timer;
	s->p_drop = v.p_drop;
	s->dropping = v.dropping;
}

const struct cobalt_impl linux_impl = {
	"sch_cake", l_init, l_seed, l_should_drop, l_queue_full,
	l_queue_empty, l_state
};
