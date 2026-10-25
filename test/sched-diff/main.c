/*
 * sched-diff: drive sch_cake's and dn_sched_cake's scheduling cores with
 * the same trace of already-classified packets and compare, packet by
 * packet, which one each sends, from which tin, and which it drops.
 *
 *   sched-diff [runs [seconds [seed]]]
 *
 * Linux's cake_dequeue() contains the link shaper, dn_sched_cake leaves
 * that to the dummynet pipe; so the clock advances in 10 us steps, and
 * every time sch_cake releases a packet dn_sched_cake is asked for one.
 * Stage 1: no overhead compensation, ACK filter, ingress mode or
 * overflow (the offered load stays below the buffer limits).
 */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "trace.h"

uint64_t trace_now_ns;
uint32_t ours_check_errors(void);

static uint64_t
mix(uint64_t *s)
{
	uint64_t z = (*s += 0x9e3779b97f4a7c15ULL);

	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
	z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
	return (z ^ (z >> 31));
}

/* the flow dissector's hash, for both sides */
uint32_t
trace_hash(uint32_t src, uint32_t dst, uint32_t ports, uint8_t proto)
{
	uint64_t s = ((uint64_t)src << 32 | dst) ^ ((uint64_t)ports << 8 | proto) *
	    0x2545f4914f6cdd1dULL;

	return ((uint32_t)mix(&s));
}

static uint64_t rng_linux, rng_ours, rng_gen;
uint32_t trace_random_linux(void) { return ((uint32_t)mix(&rng_linux)); }
uint32_t trace_random_ours(void) { return ((uint32_t)mix(&rng_ours)); }

#define MAXDROPS	100000
static uint32_t drops_linux[MAXDROPS], drops_ours[MAXDROPS];
static int ndrops_linux, ndrops_ours;
void
trace_dropped_linux(struct trace_pkt *p)
{
	p->linux_state = 2;
	if (ndrops_linux < MAXDROPS)
		drops_linux[ndrops_linux++] = p->id;
}
void
trace_dropped_ours(struct trace_pkt *p)
{
	p->ours_state = 2;
	if (ndrops_ours < MAXDROPS)
		drops_ours[ndrops_ours++] = p->id;
}

static uint64_t
range(uint64_t lo, uint64_t hi)
{
	return (lo + mix(&rng_gen) % (hi - lo + 1));
}

/* diffserv modes: name, Linux's number, ours, the DSCPs to use */
static const struct {
	const char *name;
	int linux_mode, ours_mode;
	uint8_t dscp[5];
} modes[] = {
	{ "besteffort", 3, 0, { 0, 0, 0, 0, 0 } },
	{ "diffserv3", 0, 1, { 0, 8, 46, 0, 0 } },
	{ "diffserv4", 1, 2, { 0, 8, 34, 46, 0 } },
};
static const struct { const char *name; int mode; } flow_modes[] = {
	{ "flows", 4 }, { "dual-srchost", 5 }, { "dual-dsthost", 6 },
	{ "triple-isolate", 7 },
};

struct gen_flow {
	struct trace_pkt proto;
	uint64_t next_ns, gap_ns;	/* next arrival, mean gap */
	uint16_t len_lo, len_hi;
};

struct totals {
	uint64_t sent, drops, steps;
	uint64_t mismatches;
};

/* one run; returns 0 if every decision matched */
static int
run(uint64_t seed, int secs, struct totals *t, int verbose)
{
	const int nflows_max = 48;
	struct gen_flow fl[48];
	struct trace_pkt *pkts;
	size_t npkts = 0, cap = 400000;
	uint64_t rate, end, step = 10000;
	int nflows, m, fm, i, tl, to, cd = 0;
	uint32_t id = 0;

	rng_gen = seed;
	rng_linux = rng_ours = seed ^ 0xabcdef;
	ndrops_linux = ndrops_ours = 0;
	m = (int)range(0, 2);
	fm = (int)range(0, 3);
	rate = range(50, 200) * 1000000ULL;
	nflows = (int)range(1, nflows_max);
	pkts = calloc(cap, sizeof(*pkts));

	/* flows: mostly bulk at a share of the rate, some sparse */
	for (i = 0; i < nflows; i++) {
		struct gen_flow *f = &fl[i];
		uint64_t share;

		memset(f, 0, sizeof(*f));
		f->proto.flow = 1000 + i;
		f->proto.src = 1 + (uint32_t)range(0, 3);
		f->proto.dst = 101 + (uint32_t)range(0, 3);
		f->proto.dscp = modes[m].dscp[range(0, 4)];
		f->proto.ecn = range(0, 1);
		if (range(0, 3) == 0) {		/* sparse */
			f->len_lo = 64;
			f->len_hi = 300;
			f->gap_ns = range(2, 40) * 1000000ULL;
		} else {			/* bulk */
			f->len_lo = range(0, 1) ? 1514 : 64;
			f->len_hi = 1514;
			/* together the bulk flows offer up to 1.2x the rate */
			share = rate * 12 / 10 / nflows;
			f->gap_ns = (uint64_t)(f->len_lo + f->len_hi) / 2 * 8 *
			    1000000000ULL / (share ? share : 1);
		}
		f->next_ns = range(0, f->gap_ns);
	}

	linux_impl.init(modes[m].linux_mode, flow_modes[fm].mode, rate);
	ours_impl.init(modes[m].ours_mode, flow_modes[fm].mode, rate);

	end = (uint64_t)secs * 1000000000ULL;
	for (trace_now_ns = 1000000; trace_now_ns < end; trace_now_ns += step) {
		/* arrivals up to now, into both */
		for (i = 0; i < nflows; i++) {
			struct gen_flow *f = &fl[i];

			while (f->next_ns <= trace_now_ns && npkts < cap) {
				struct trace_pkt *p = &pkts[npkts++];

				*p = f->proto;
				p->id = ++id;
				p->len = (uint16_t)range(f->len_lo, f->len_hi);
				linux_impl.enqueue(p);
				ours_impl.enqueue(p);
				f->next_ns += f->gap_ns / 2 + range(0, f->gap_ns);
			}
		}
		/* everything sch_cake's shaper lets out now */
		for (;;) {
			struct trace_pkt *pl = linux_impl.dequeue(&tl), *po;

			if (pl == NULL)
				break;
			po = ours_impl.dequeue(&to);
			if (getenv("SD_TRACE") && t->sent >= (uint64_t)atoi(getenv("SD_TRACE"))) {
				printf("  %.6f s: sch_cake %u (flow %u tin %d), dn_sched_cake %u (flow %u tin %d)\n",
				    trace_now_ns / 1e9, pl->id, pl->flow, tl, po ? po->id : 0,
				    po ? po->flow : 0, to);
				linux_impl.debug();
				ours_impl.debug();
			}
			t->sent++;
			if (po != pl || tl != to || ndrops_linux != ndrops_ours ||
			    memcmp(drops_linux, drops_ours,
			    ndrops_linux * sizeof(uint32_t)) != 0) {
				if (verbose) {
					printf("mismatch: seed %" PRIu64 " %s %s %" PRIu64
					    " Mbit/s %d flows, at %.6f s after %" PRIu64
					    " packets\n", seed, modes[m].name,
					    flow_modes[fm].name, rate / 1000000, nflows,
					    trace_now_ns / 1e9, t->sent);
					printf("  sch_cake      sent %u (flow %u tin %d), drops %d\n",
					    pl->id, pl->flow, tl, ndrops_linux);
					printf("  dn_sched_cake sent %u (flow %u tin %d), drops %d\n",
					    po ? po->id : 0, po ? po->flow : 0, to, ndrops_ours);
				}
				t->mismatches++;
				free(pkts);
				return (1);
			}
			cd++;
		}
		t->steps++;
	}
	t->drops += ndrops_linux;
	free(pkts);
	(void)cd;
	return (0);
}

int
main(int argc, char **argv)
{
	struct totals t;
	int runs = argc > 1 ? atoi(argv[1]) : 50;
	int secs = argc > 2 ? atoi(argv[2]) : 2;
	uint64_t seed = argc > 3 ? strtoull(argv[3], NULL, 0) : 1;
	int r, bad = 0;

	memset(&t, 0, sizeof(t));
	for (r = 0; r < runs; r++)
		bad += run(seed + r, secs, &t, bad < 5);
	printf("%d runs of %d s: %" PRIu64 " packets sent and %" PRIu64
	    " dropped in step: %d runs mismatched\n", runs, secs, t.sent,
	    t.drops, bad);
#ifdef CAKE_DEBUG
	printf("dn_sched_cake consistency errors: %u\n", ours_check_errors());
	bad += ours_check_errors() != 0;
#endif
	return (bad != 0);
}
