/*
 * cobalt-diff: drive dn_sched_cake's and sch_cake's COBALT with the same
 * random event sequences and compare every decision and the whole state
 * after each event.
 *
 *   cobalt-diff [runs [events [seed]]]
 *
 * Each run picks parameters (target, interval, MTU time, BLUE steps, bulk
 * flows) and plays a flow whose queue delay wanders between below, around
 * and far above the target, with ECN and non-ECN packets, overflows
 * (queue_full), drains (queue_empty) and idle gaps up to seconds.
 *
 * Mode "aligned" starts both at 1/sqrt(1), as dn_sched_cake does; every
 * result must match. Mode "upstream-init" gives sch_cake its own zeroed
 * start and counts the runs whose first signal comes earlier there.
 */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cobalt.h"

static uint64_t g;

static uint64_t
rnd(void)
{
	uint64_t z = (g += 0x9e3779b97f4a7c15ULL);

	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
	z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
	return (z ^ (z >> 31));
}

/* uniform in [lo, hi] */
static uint64_t
range(uint64_t lo, uint64_t hi)
{
	return (lo + rnd() % (hi - lo + 1));
}

static int
chance(int percent)
{
	return ((int)(rnd() % 100) < percent);
}

struct totals {
	uint64_t events, drops, marks, newton, blue, mismatches;
	uint32_t max_count;
};

static void
print_state(const char *name, const struct cd_state *s, int drop, int mark)
{
	printf("  %-14s drop %d mark %d count %" PRIu32 " inv %" PRIu32
	    " dropping %d drop_next %" PRIu64 " blue_timer %" PRIu64
	    " p_drop %" PRIu32 "\n", name, drop, mark, s->count,
	    s->rec_inv_sqrt, s->dropping, s->drop_next, s->blue_timer,
	    s->p_drop);
}

/*
 * One run. Returns the event index of the first mismatch, or -1. With
 * first_signal, store the event index of each side's first signal.
 */
static long
run(uint64_t seed, long events, int upstream_init, struct totals *t,
	long first_signal[2])
{
	const struct cobalt_impl *impl[2] = { &ours_impl, &linux_impl };
	struct cd_params p;
	struct cd_state s[2];
	uint64_t now, sojourn;
	uint32_t bulk;
	long e;
	int i, phase, kind, ecn, drop[2], mark[2];

	g = seed;
	p.target = chance(50) ? 5000 : range(500, 20000);
	p.interval = chance(50) ? 100000 : p.target * range(2, 40);
	p.mtu_time = chance(30) ? 0 : range(1, p.target / 2);
	p.p_inc = chance(70) ? 1U << 24 : (uint32_t)range(1, 1U << 30);
	p.p_dec = chance(70) ? 1U << 20 : (uint32_t)range(1, 1U << 28);
	bulk = chance(60) ? 0 : (uint32_t)range(1, 64);
	now = range(1000000, 1ULL << 40);
	phase = 0;

	for (i = 0; i < 2; i++) {
		impl[i]->init(upstream_init);
		impl[i]->seed(seed ^ 0x5eed);
	}
	first_signal[0] = first_signal[1] = -1;

	for (e = 0; e < events; e++) {
		/* time moves on; sometimes the flow idles for a long time */
		if (chance(2))
			now += range(p.interval, 20 * p.interval);
		else
			now += chance(80) ? range(1, 200) : range(200, 20000);

		/* the queue delay drifts between phases */
		if (chance(3))
			phase = (int)range(0, 3);
		switch (phase) {
		case 0:
			sojourn = range(0, p.target);
			break;
		case 1:
			sojourn = range(p.target / 2, 2 * p.target);
			break;
		case 2:
			sojourn = range(p.target, 10 * p.target);
			break;
		default:
			sojourn = range(10 * p.target, 50 * p.target);
			break;
		}
		if (sojourn > now)
			sojourn = now;

		kind = (int)range(0, 99);
		ecn = chance(50);
		for (i = 0; i < 2; i++) {
			drop[i] = mark[i] = 0;
			/* overflows are rare and only far over target, so
			 * most signals come from CoDel, not BLUE */
			if (phase == 3 && kind < 2)
				mark[i] = 2 * impl[i]->queue_full(&p, now);
			else if (kind >= 97)
				mark[i] = 2 * impl[i]->queue_empty(&p, now);
			else
				drop[i] = impl[i]->should_drop(&p, now,
				    now - sojourn, ecn, bulk, &mark[i]);
			impl[i]->state(&s[i]);
			if ((drop[i] || mark[i] == 1) && first_signal[i] < 0)
				first_signal[i] = e;
		}

		t->events++;
		t->drops += drop[0];
		t->marks += mark[0] == 1;
		if (s[0].count >= 16)
			t->newton++;
		if (s[0].p_drop)
			t->blue++;
		if (s[0].count > t->max_count)
			t->max_count = s[0].count;

		if (upstream_init)
			continue;
		if (drop[0] != drop[1] || mark[0] != mark[1] ||
		    memcmp(&s[0], &s[1], sizeof(s[0])) != 0) {
			printf("mismatch: seed %" PRIu64 " event %ld now %" PRIu64
			    " sojourn %" PRIu64 " kind %d ecn %d\n", seed, e,
			    now, sojourn, kind, ecn);
			print_state(impl[0]->name, &s[0], drop[0], mark[0]);
			print_state(impl[1]->name, &s[1], drop[1], mark[1]);
			return (e);
		}
	}
	return (-1);
}

int
main(int argc, char **argv)
{
	struct totals t;
	long runs = argc > 1 ? atol(argv[1]) : 2000;
	long events = argc > 2 ? atol(argv[2]) : 5000;
	uint64_t seed = argc > 3 ? strtoull(argv[3], NULL, 0) : 1;
	long r, first[2], earlier = 0, later = 0, same = 0;
	uint64_t gap = 0;

	/* mode aligned: every event must match */
	memset(&t, 0, sizeof(t));
	for (r = 0; r < runs; r++)
		if (run(seed + r, events, 0, &t, first) >= 0)
			t.mismatches++;
	printf("aligned: %ld runs, %" PRIu64 " events, %" PRIu64 " drops, %"
	    PRIu64 " marks, %" PRIu64 " events with count >= 16 (Newton), "
	    "%" PRIu64 " with BLUE active, max count %" PRIu32 ": %" PRIu64
	    " mismatching runs\n", runs, t.events, t.drops, t.marks, t.newton,
	    t.blue, t.max_count, t.mismatches);

	/* mode upstream-init: how sch_cake's zeroed start differs */
	memset(&t, 0, sizeof(t));
	for (r = 0; r < runs; r++) {
		run(seed + r, events, 1, &t, first);
		if (first[1] >= 0 && (first[0] < 0 || first[1] < first[0])) {
			earlier++;
			if (first[0] >= 0)
				gap += (uint64_t)(first[0] - first[1]);
		} else if (first[0] == first[1])
			same++;
		else
			later++;
	}
	printf("upstream-init: first signal earlier in sch_cake in %ld runs "
	    "(by %.1f events on average), same in %ld, later in %ld\n",
	    earlier, earlier ? (double)gap / earlier : 0.0, same, later);

	return (t.mismatches != 0);
}
