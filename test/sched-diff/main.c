/*
 * sched-diff: drive sch_cake's and dn_sched_cake's scheduling cores with
 * the same trace of already-classified packets and compare, packet by
 * packet, which one each sends, from which tin, and which it drops.
 *
 *   sched-diff [runs [seconds [seed]]]
 *   sched-diff link [runs [seconds [seed]]]
 *   sched-diff pace [seconds [hz ...]]
 *   sched-diff pace-random [hz [runs [seconds [seed]]]]
 *
 * link: the same comparison with dn_sched_cake's link clock on. The clock
 * goes from event to event, each arrival and each moment sch_cake's
 * shaper lets a packet out, rather than in steps: so sch_cake decides at
 * the times the link clock computes, and the two must still match.
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

/* diffserv modes (dn_sched_cake's numbers) and the DSCPs to use */
static const struct {
	const char *name;
	int mode;
	uint8_t dscp[5];
} modes[] = {
	{ "besteffort", 0, { 0, 0, 0, 0, 0 } },
	{ "diffserv3", 1, { 0, 8, 46, 0, 0 } },
	{ "diffserv4", 2, { 0, 8, 34, 46, 0 } },
};

/* overhead presets: name, overhead, mpu, atm (as tc-cake(8)'s keywords) */
static const struct { const char *name; int overhead, mpu, atm; } links[] = {
	{ "raw", 0, 0, 0 }, { "ethernet", 38, 84, 0 }, { "docsis", 18, 64, 0 },
	{ "pppoe-ptm", 30, 0, 2 }, { "atm", 0, 0, 1 }, { "random", 0, 0, 0 },
};

static void
put16(uint8_t *b, uint16_t v)
{
	b[0] = v >> 8;
	b[1] = v;
}

static void
put32(uint8_t *b, uint32_t v)
{
	put16(b, v >> 16);
	put16(b + 2, v);
}
static const struct { const char *name; int mode; } flow_modes[] = {
	{ "flows", 4 }, { "dual-srchost", 5 }, { "dual-dsthost", 6 },
	{ "triple-isolate", 7 },
};

enum { FLOW_DATA, FLOW_SPARSE, FLOW_ACKS };

struct gen_flow {
	struct trace_pkt proto;
	int kind;
	uint64_t next_ns, gap_ns;	/* next arrival, mean gap */
	uint16_t len_lo, len_hi;
	uint32_t seq, ack, tsval;	/* TCP state */
	uint16_t window;
	int ts;				/* sends timestamps */
};

/*
 * The packet's IPv4 and TCP (or UDP) headers and length: data segments
 * for bulk flows, datagrams for sparse ones, and for ACK streams mostly
 * pure ACKs with growing ack numbers, timestamps, SACK blocks, duplicate
 * ACKs, ECN flags and the odd window change or data segment, so that the
 * ACK filter has every case to decide.
 */
static void
build(struct trace_pkt *p, struct gen_flow *f)
{
	uint8_t *ip = p->hdr, *th = p->hdr + 20, *o = th + 20;
	int olen = 0, payload = 0, flags = 0x10, i, n;

	memset(p->hdr, 0, sizeof(p->hdr));
	ip[0] = 0x45;
	ip[1] = (uint8_t)(p->dscp << 2 | (p->ecn ? 2 : 0));
	put16(ip + 6, 0x4000);
	ip[8] = 64;
	put32(ip + 12, 0x0a000000 | p->src);
	put32(ip + 16, 0x0a010000 | p->dst);
	put16(th, (uint16_t)(10000 + p->flow));
	put16(th + 2, 443);

	if (f->kind == FLOW_SPARSE) {
		ip[9] = 17;
		p->len = (uint16_t)range(f->len_lo, f->len_hi);
		put16(th + 4, p->len - 20);
		put16(ip + 2, p->len);
		return;
	}
	ip[9] = 6;
	if (f->ts) {
		o[0] = o[1] = 1;
		o[2] = 8;
		o[3] = 10;
		f->tsval += (uint32_t)range(0, 2);
		put32(o + 4, f->tsval);
		put32(o + 8, f->tsval - 40);
		olen = 12;
	}
	if (f->kind == FLOW_DATA) {
		flags |= 0x08;
		payload = (int)range(f->len_lo, f->len_hi) - 40 - olen;
		if (payload < 1)
			payload = 1;
	} else {
		if (range(0, 9) == 0)
			n = 0;			/* duplicate ACK */
		else
			n = (int)range(1, 4);
		f->ack += (uint32_t)n * 1448;
		if ((n == 0 || range(0, 9) == 0) && olen + 2 + 8 <= 40) {
			int blocks = (int)range(1, (40 - olen - 4) / 8);

			o[olen] = o[olen + 1] = 1;
			o[olen + 2] = 5;
			o[olen + 3] = (uint8_t)(2 + 8 * blocks);
			for (i = 0; i < blocks; i++) {
				uint32_t l = f->ack + 1448 * (uint32_t)range(1, 20);

				put32(o + olen + 4 + 8 * i, l);
				put32(o + olen + 8 + 8 * i, l + 1448 *
				    (uint32_t)range(1, 4));
			}
			olen += 4 + 8 * blocks;
		}
		if (range(0, 9) == 0)
			flags |= 0x40;			/* ECE */
		if (range(0, 49) == 0)
			flags |= 0x80;			/* CWR */
		if (range(0, 29) == 0) {
			flags |= 0x08;
			payload = (int)range(1, 1000);
		}
		if (range(0, 49) == 0)
			f->window = (uint16_t)range(1000, 65535);
	}
	put32(th + 4, f->seq);
	put32(th + 8, f->ack);
	th[12] = (uint8_t)((5 + olen / 4) << 4);
	th[13] = (uint8_t)flags;
	put16(th + 14, f->window);
	f->seq += (uint32_t)payload;
	p->len = (uint16_t)(20 + 20 + olen + payload);
	put16(ip + 2, p->len);
}

struct totals {
	uint64_t sent, drops, steps;
	uint64_t mismatches;
	int ingress_runs, ingress_mismatches;
	uint64_t ingress_sent;		/* packets matched before diverging */
};

static int run_ingress;			/* the current run is in ingress mode */
static int pace_hz;		/* pace mode: dummynet's ticks, not lockstep */
static int link_mode;		/* link mode: event to event, link clock on */
static int pace_late;		/* pace-random: % of ticks that come late */
static uint64_t rng_late = 0x5eed;
uint64_t linux_next_release(void);
void ours_link_stats(unsigned *, unsigned *, unsigned *, unsigned *,
    unsigned *);

/* pace modes: the link clock's clamp, as a suffix to the run's line */
static void
print_link_stats(void)
{
	unsigned r, b, bm, a, am;

	ours_link_stats(&r, &b, &bm, &a, &am);
	if (r == 0)
		return;
	printf("    link clock: %u reads, %.3f%% pulled forward (max %u us),"
	    " %.3f%% pulled back (max %u us)\n", r, 100.0 * b / r, bm,
	    100.0 * a / r, am);
}
static uint64_t tin_bytes[2][8];	/* pace mode: [side][tin] sent */
static void pace_tin_sent(struct trace_pkt *p, int tin)
{
	tin_bytes[1][tin] += p->len;
}
void ours_set_hz(int);
void ours_set_link_clock(int);
int ours_serve(void (*)(struct trace_pkt *, int));


/* SD_PKT=id: the packets of id's flow around it, with each side's fate */
static void
dump_flow(struct trace_pkt *pkts, size_t npkts)
{
	const char *e = getenv("SD_PKT");
	uint32_t id, i, flow;

	if (e == NULL || (id = (uint32_t)atoi(e)) == 0 || id > npkts)
		return;
	flow = pkts[id - 1].flow;
	for (i = id > 150 ? id - 150 : 1; i <= id + 100 && i <= npkts; i++) {
		struct trace_pkt *p = &pkts[i - 1];
		const uint8_t *th = p->hdr + 20;
		int hl = (th[12] >> 4) * 4, o, k;

		if (p->flow != flow)
			continue;
		printf("    %6u len %4u ack %10u flags %02x win %5u %s %s opts:",
		    p->id, p->len, (th[8] << 24 | th[9] << 16 | th[10] << 8 | th[11]),
		    th[13], th[14] << 8 | th[15],
		    p->linux_state == 2 ? "L-drop" : p->linux_state == 1 ? "L-sent" : "L-q   ",
		    p->ours_state == 2 ? "O-drop" : p->ours_state == 1 ? "O-sent" : "O-q   ");
		for (o = 20; o < hl; ) {
			k = th[o];
			if (k == 0) break;
			if (k == 1) { o++; continue; }
			printf(" %d/%d", k, th[o + 1]);
			if (k == 8) printf("(%u)", th[o+2] << 24 | th[o+3] << 16 | th[o+4] << 8 | th[o+5]);
			o += th[o + 1] < 2 ? 2 : th[o + 1];
		}
		printf("\n");
	}
}

/* link mode: the next arrival or sch_cake release, whichever is first */
static uint64_t
next_event(struct gen_flow *fl, int nflows, int arrivals)
{
	uint64_t t = linux_next_release();
	int i;

	for (i = 0; arrivals && i < nflows; i++)
		if (fl[i].next_ns < t)
			t = fl[i].next_ns;
	/* never stand still: a release due now was just made */
	return (t > trace_now_ns ? t : trace_now_ns + 1);
}

/* one run; returns 0 if every decision matched */
static int
run(uint64_t seed, int secs, struct totals *t, int verbose)
{
	const int nflows_max = 48;
	struct gen_flow fl[48];
	struct sd_config c;
	struct trace_pkt *pkts;
	size_t npkts = 0, cap = 600000;
	uint64_t end, step = 10000;
	int nflows, m, fm, lk, acks, i, tl, to, load;
	uint32_t id = 0;
	struct trace_pkt *pl;

	rng_gen = seed;
	rng_linux = rng_ours = seed ^ 0xabcdef;
	ndrops_linux = ndrops_ours = 0;
	memset(&c, 0, sizeof(c));
	m = (int)range(0, 2);
	fm = (int)range(0, 3);
	c.diffserv = modes[m].mode;
	c.flow_mode = flow_modes[fm].mode;
	c.rate = range(50, 200) * 1000000ULL;
	lk = (int)range(0, 5);
	c.overhead = links[lk].overhead;
	c.mpu = links[lk].mpu;
	c.atm = links[lk].atm;
	if (lk == 5) {
		c.overhead = (int)range(0, 70) - 10;
		c.mpu = (int)range(0, 96);
	}
	c.ingress = range(0, 9) < 3;
	run_ingress = c.ingress;
	t->ingress_runs += c.ingress;
	c.ack_filter = (int)range(0, 2);
	if (range(0, 9) < 4)	/* a small byte limit, so overflow drops happen */
		c.memlimit = (uint32_t)range(32, 512) * 1024;
	load = (int)range(10, 16);		/* offered load, tenths of the rate */
	acks = range(0, 1) ? (int)range(1, 6) : 0;
	nflows = (int)range(1 + acks, nflows_max);
	pkts = calloc(cap, sizeof(*pkts));

	for (i = 0; i < nflows; i++) {
		struct gen_flow *f = &fl[i];
		uint64_t share;

		memset(f, 0, sizeof(*f));
		f->proto.flow = 1000 + i;
		f->proto.src = 1 + (uint32_t)range(0, 3);
		f->proto.dst = 101 + (uint32_t)range(0, 3);
		f->proto.dscp = modes[m].dscp[range(0, 4)];
		f->proto.ecn = range(0, 1);
		f->seq = (uint32_t)mix(&rng_gen);
		f->ack = (uint32_t)mix(&rng_gen);
		f->tsval = (uint32_t)mix(&rng_gen);
		f->window = 65535;
		f->ts = range(0, 3) != 0;
		if (i < acks) {			/* an ACK stream, a few % */
			f->kind = FLOW_ACKS;
			f->gap_ns = 8 * 70 * 1000000000ULL /
			    (c.rate * range(1, 5) / 100);
		} else if (range(0, 3) == 0) {	/* sparse datagrams */
			f->kind = FLOW_SPARSE;
			f->len_lo = 64;
			f->len_hi = 300;
			f->gap_ns = range(2, 40) * 1000000ULL;
		} else {			/* bulk data */
			f->kind = FLOW_DATA;
			f->len_lo = range(0, 1) ? 1514 : 64;
			f->len_hi = 1514;
			share = c.rate * load / 10 / nflows;
			f->gap_ns = (uint64_t)(f->len_lo + f->len_hi) / 2 * 8 *
			    1000000000ULL / (share ? share : 1);
		}
		f->next_ns = range(0, f->gap_ns);
	}

	linux_impl.init(&c);
	ours_impl.init(&c);
	if (link_mode)
		ours_set_link_clock(1);
	if (pace_hz) {
		unsigned x;

		ours_link_stats(&x, &x, &x, &x, &x);
		trace_now_ns = 1000000;
		ours_set_hz(pace_hz);
		ours_set_link_clock(getenv("SD_LINK_CLOCK") != NULL &&
		    atoi(getenv("SD_LINK_CLOCK")) != 0);
		memset(tin_bytes, 0, sizeof(tin_bytes));
	}

	end = (uint64_t)secs * 1000000000ULL;
	for (trace_now_ns = 1000000; trace_now_ns < end;
	    trace_now_ns = link_mode ? next_event(fl, nflows, npkts < cap) :
	    trace_now_ns + step) {
		/* arrivals up to now, into both */
		for (i = 0; i < nflows; i++) {
			struct gen_flow *f = &fl[i];

			while (f->next_ns <= trace_now_ns && npkts < cap) {
				struct trace_pkt *p = &pkts[npkts++];

				*p = f->proto;
				p->id = ++id;
				build(p, f);
				linux_impl.enqueue(p);
				ours_impl.enqueue(p);
				if (getenv("SD_ACKDBG") &&
				    p->id == (uint32_t)atoi(getenv("SD_ACKDBG"))) {
					printf("  after enqueueing %u:\n", p->id);
					linux_impl.debug_flow(p->flow);
					ours_impl.debug_flow(p->flow);
				}
				f->next_ns += f->gap_ns / 2 + range(0, f->gap_ns);
			}
		}
		if (pace_hz) {
			while ((pl = linux_impl.dequeue(&tl)) != NULL)
				tin_bytes[0][tl] += pl->len;
			/* SD_LATE=n: n% of ticks come late, as dummynet's do
			 * under load; the next one catches up their credit */
			if (trace_now_ns * pace_hz / 1000000000 !=
			    (trace_now_ns - step) * pace_hz / 1000000000 &&
			    (pace_late == 0 || mix(&rng_late) % 100 >=
			    (uint64_t)pace_late))
				ours_serve(pace_tin_sent);
			continue;
		}
		/* everything sch_cake's shaper lets out now */
		for (;;) {
			struct trace_pkt *po;

			pl = linux_impl.dequeue(&tl);
			if (pl == NULL)
				break;
			po = ours_impl.dequeue(&to);
			pl->linux_state = 1;
			if (po != NULL)
				po->ours_state = 1;
			if (getenv("SD_TRACE") && t->sent >= (uint64_t)atoi(getenv("SD_TRACE"))) {
				printf("  %.6f s: sch_cake %u (flow %u tin %d), dn_sched_cake %u (flow %u tin %d)\n",
				    trace_now_ns / 1e9, pl->id, pl->flow, tl, po ? po->id : 0,
				    po ? po->flow : 0, to);
				linux_impl.debug();
				ours_impl.debug();
				linux_impl.debug_flow(pl->flow);
				ours_impl.debug_flow(pl->flow);
			}
			t->sent++;
			if (po != pl || tl != to || ndrops_linux != ndrops_ours ||
			    memcmp(drops_linux, drops_ours,
			    ndrops_linux * sizeof(uint32_t)) != 0) {
				if (verbose || !c.ingress) {
					printf("mismatch: seed %" PRIu64 " %s %s %" PRIu64
					    " Mbit/s %s%s ack-filter %d memlimit %u, %d flows"
					    " (%d ACK streams), at %.6f s after %" PRIu64
					    " packets\n", seed, modes[m].name,
					    flow_modes[fm].name, c.rate / 1000000,
					    links[lk].name, c.ingress ? " ingress" : "",
					    c.ack_filter, c.memlimit, nflows, acks,
					    trace_now_ns / 1e9, t->sent);
					printf("  sch_cake      sent %u (flow %u tin %d), drops %d\n",
					    pl->id, pl->flow, tl, ndrops_linux);
					printf("  dn_sched_cake sent %u (flow %u tin %d), drops %d\n",
					    po ? po->id : 0, po ? po->flow : 0, to, ndrops_ours);
					for (i = 0; i < ndrops_linux && i < ndrops_ours &&
					    drops_linux[i] == drops_ours[i]; i++)
						;
					if (i < ndrops_linux || i < ndrops_ours)
						printf("  drops differ from #%d: sch_cake %u (flow %u), dn_sched_cake %u (flow %u)\n",
						    i, i < ndrops_linux ? drops_linux[i] : 0,
						    i < ndrops_linux ? pkts[drops_linux[i] - 1].flow : 0,
						    i < ndrops_ours ? drops_ours[i] : 0,
						    i < ndrops_ours ? pkts[drops_ours[i] - 1].flow : 0);
					printf("  last drops sch_cake:");
					for (i = ndrops_linux > 4 ? ndrops_linux - 4 : 0; i < ndrops_linux; i++)
						printf(" %u (flow %u)", drops_linux[i], pkts[drops_linux[i] - 1].flow);
					printf("\n  last drops dn_sched_cake:");
					for (i = ndrops_ours > 4 ? ndrops_ours - 4 : 0; i < ndrops_ours; i++)
						printf(" %u (flow %u)", drops_ours[i], pkts[drops_ours[i] - 1].flow);
					printf("\n");
				}
				t->mismatches++;
				dump_flow(pkts, npkts);
				free(pkts);
				return (1);
			}
		}
		/*
		 * In ingress mode a drop charges sch_cake's own shaper too,
		 * so a dequeue can drop and then send nothing; dn_sched_cake,
		 * paced by the pipe's credit instead, makes that drop on its
		 * next call. The drop lists are compared, in order, at every
		 * packet sent; the queue lengths only while no such drop is
		 * pending.
		 */
		if (ndrops_linux == ndrops_ours &&
		    linux_impl.qlen() != ours_impl.qlen()) {
			if (verbose || !c.ingress) {
				printf("mismatch: seed %" PRIu64 " %s %s %" PRIu64
				    " Mbit/s %s%s ack-filter %d memlimit %u, %d flows"
				    " (%d ACK streams): queue lengths %u and %u at %.6f s\n",
				    seed, modes[m].name, flow_modes[fm].name,
				    c.rate / 1000000, links[lk].name,
				    c.ingress ? " ingress" : "", c.ack_filter, c.memlimit,
				    nflows, acks, linux_impl.qlen(), ours_impl.qlen(),
				    trace_now_ns / 1e9);
				printf("  last drops sch_cake:");
				for (i = ndrops_linux > 4 ? ndrops_linux - 4 : 0; i < ndrops_linux; i++)
					printf(" %u (flow %u)", drops_linux[i], pkts[drops_linux[i] - 1].flow);
				printf("\n  last drops dn_sched_cake:");
				for (i = ndrops_ours > 4 ? ndrops_ours - 4 : 0; i < ndrops_ours; i++)
					printf(" %u (flow %u)", drops_ours[i], pkts[drops_ours[i] - 1].flow);
				printf("\n");
			}
			t->mismatches++;
			dump_flow(pkts, npkts);
			free(pkts);
			return (1);
		}
		t->steps++;
	}
	t->drops += ndrops_linux;
	if (pace_hz) {
		/* each tin's share of the link, as fractions of the rate */
		double worst = 0, d, secs_run = (end - 1000000) / 1e9;
		int wt = 0;

		for (i = 0; i < 8; i++) {
			d = ((double)tin_bytes[1][i] - tin_bytes[0][i]) * 8 /
			    secs_run / c.rate;
			if (d < 0 ? -d > worst : d > worst) {
				worst = d < 0 ? -d : d;
				wt = i;
			}
		}
		printf("pace %4" PRIu64 " %-10s %3" PRIu64 " Mbit/s%s: worst tin %d"
		    " %+.2f%% of the rate (sch_cake %.2f, dn_sched_cake %.2f Mbit/s;"
		    " drops %d, %d)\n",
		    seed, modes[m].name, c.rate / 1000000, c.ingress ? " ingress" : "",
		    wt, 100.0 * ((double)tin_bytes[1][wt] - tin_bytes[0][wt]) * 8 /
		    secs_run / c.rate, tin_bytes[0][wt] * 8 / secs_run / 1e6,
		    tin_bytes[1][wt] * 8 / secs_run / 1e6, ndrops_linux, ndrops_ours);
		print_link_stats();
	}
	free(pkts);
	return (0);
}

/*
 * pace: how the release mechanism alone changes the tins' shares, with
 * contention.sh's bulk+voice scenario: a 5 Mbit/s isochronous Bulk flow
 * (1278-byte datagrams every 2 ms) against more Voice (full-size TCP
 * segments) than the 50 Mbit/s link takes, in diffserv4. sch_cake sends
 * whenever its shaper allows, as on Linux; dn_sched_cake is asked for
 * packets on each tick of kern.hz, as by a dummynet pipe. Each side gets
 * its own copy of the trace.
 */
static uint64_t pace_bytes[2][2];	/* [side][flow] */

static void
pace_sent(struct trace_pkt *p, int tin)
{
	(void)tin;
	pace_bytes[1][p->flow - 1000] += p->len;
}

static void
pace(int secs, int khz)
{
	struct gen_flow fl[2];
	struct sd_config c;
	struct trace_pkt *lp, *op, *p;
	size_t npkts = 0, cap = 400000;
	uint64_t end = (uint64_t)secs * 1000000000ULL, warm = 1000000000ULL;
	uint32_t id = 0;
	int i, t;

	rng_gen = 1;
	rng_linux = rng_ours = 1 ^ 0xabcdef;
	ndrops_linux = ndrops_ours = 0;
	memset(pace_bytes, 0, sizeof(pace_bytes));
	memset(&c, 0, sizeof(c));
	c.diffserv = 2;
	c.flow_mode = 7;
	c.rate = 50000000;
	memset(fl, 0, sizeof(fl));
	for (i = 0; i < 2; i++) {
		fl[i].proto.flow = 1000 + i;
		fl[i].proto.src = 1;
		fl[i].proto.dst = 101;
		fl[i].window = 65535;
	}
	fl[0].kind = FLOW_SPARSE;
	fl[0].proto.dscp = 8;			/* CS1: Bulk */
	fl[0].len_lo = fl[0].len_hi = 1278;
	fl[0].gap_ns = 2000000;
	fl[1].kind = FLOW_DATA;
	fl[1].proto.dscp = 46;			/* EF: Voice */
	fl[1].len_lo = fl[1].len_hi = 1500;
	fl[1].gap_ns = 1500ULL * 8 * 1000000000 / 60000000;
	lp = calloc(cap, sizeof(*lp));
	op = calloc(cap, sizeof(*op));

	trace_now_ns = 1000000;
	linux_impl.init(&c);
	ours_impl.init(&c);
	ours_set_hz(khz);
	ours_set_link_clock(getenv("SD_LINK_CLOCK") != NULL &&
	    atoi(getenv("SD_LINK_CLOCK")) != 0);
	for (; trace_now_ns < end; trace_now_ns += 10000) {
		for (i = 0; i < 2; i++) {
			struct gen_flow *f = &fl[i];

			while (f->next_ns <= trace_now_ns && npkts < cap) {
				p = &lp[npkts];
				*p = f->proto;
				p->id = ++id;
				build(p, f);
				op[npkts++] = *p;
				linux_impl.enqueue(p);
				ours_impl.enqueue(&op[npkts - 1]);
				f->next_ns += f->gap_ns;
			}
		}
		while ((p = linux_impl.dequeue(&t)) != NULL)
			if (trace_now_ns >= warm)
				pace_bytes[0][p->flow - 1000] += p->len;
		/* dummynet's tick: from the start of each tick on */
		if (trace_now_ns * khz / 1000000000 !=
		    (trace_now_ns - 10000) * khz / 1000000000) {
			if (trace_now_ns >= warm)
				ours_serve(pace_sent);
			else {
				uint64_t keep[2] = { pace_bytes[1][0], pace_bytes[1][1] };

				ours_serve(pace_sent);
				pace_bytes[1][0] = keep[0];
				pace_bytes[1][1] = keep[1];
			}
		}
	}
	printf("hz %6d: Bulk sch_cake %.2f, dn_sched_cake %.2f Mbit/s;"
	    " Voice sch_cake %.2f, dn_sched_cake %.2f Mbit/s\n", khz,
	    pace_bytes[0][0] * 8 / ((end - warm) / 1e3),
	    pace_bytes[1][0] * 8 / ((end - warm) / 1e3),
	    pace_bytes[0][1] * 8 / ((end - warm) / 1e3),
	    pace_bytes[1][1] * 8 / ((end - warm) / 1e3));
	print_link_stats();
	free(lp);
	free(op);
}

/*
 * Ingress mode is compared but not required to match: a drop charges
 * sch_cake's own shaper, which it checks again when DRR finds an empty
 * flow, so a dequeue can end after a drop without sending; dn_sched_cake
 * is paced from outside by the pipe's credit, and finishes the call. The
 * two then drift apart by their release mechanisms, not their decisions.
 */
int
main(int argc, char **argv)
{
	struct totals t;
	int runs = argc > 1 ? atoi(argv[1]) : 50;
	int secs = argc > 2 ? atoi(argv[2]) : 2;
	uint64_t seed = argc > 3 ? strtoull(argv[3], NULL, 0) : 1;
	int r, bad = 0, verbose = getenv("SD_VERBOSE") != NULL;
	uint64_t before;

	if (argc > 1 && strcmp(argv[1], "link") == 0) {
		link_mode = 1;
		argv++;
		argc--;
		runs = argc > 1 ? atoi(argv[1]) : 50;
		secs = argc > 2 ? atoi(argv[2]) : 2;
		seed = argc > 3 ? strtoull(argv[3], NULL, 0) : 1;
	}
	if (argc > 1 && strcmp(argv[1], "pace-random") == 0) {
		/* sched-diff pace-random hz [runs [seconds [seed]]] */
		pace_hz = argc > 2 ? atoi(argv[2]) : 1000;
		pace_late = getenv("SD_LATE") ? atoi(getenv("SD_LATE")) : 0;
		runs = argc > 3 ? atoi(argv[3]) : 50;
		secs = argc > 4 ? atoi(argv[4]) : 2;
		seed = argc > 5 ? strtoull(argv[5], NULL, 0) : 1;
		memset(&t, 0, sizeof(t));
		for (r = 0; r < runs; r++)
			run(seed + r, secs, &t, verbose);
		return (0);
	}
	if (argc > 1 && strcmp(argv[1], "pace") == 0) {
		secs = argc > 2 ? atoi(argv[2]) : 10;
		if (argc <= 3)
			pace(secs, 1000);
		for (r = 3; r < argc; r++)
			pace(secs, atoi(argv[r]));
		return (0);
	}
	memset(&t, 0, sizeof(t));
	for (r = 0; r < runs; r++) {
		before = t.sent;
		if (run(seed + r, secs, &t, verbose) != 0) {
			if (run_ingress) {
				t.ingress_mismatches++;
				t.ingress_sent += t.sent - before;
			} else
				bad++;
		}
	}
	printf("%d runs of %d s: %" PRIu64 " packets sent and %" PRIu64
	    " dropped in step: %d runs mismatched\n", runs, secs, t.sent,
	    t.drops, bad);
	printf("ingress mode (not required to match): %d runs, %d drifted"
	    " apart after %.0f matching packets on average\n", t.ingress_runs,
	    t.ingress_mismatches, t.ingress_mismatches ?
	    (double)t.ingress_sent / t.ingress_mismatches : 0.0);
#ifdef CAKE_DEBUG
	printf("dn_sched_cake consistency errors: %u\n", ours_check_errors());
	bad += ours_check_errors() != 0;
#endif
	return (bad != 0);
}
