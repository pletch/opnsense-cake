/*
 * Malformed packets through dn_sched_cake's scheduling core and packet
 * parsers (flow hashing, DSCP and wash, ECN marking, the ACK filter's
 * TCP and option parsing, overhead compensation), built with the
 * sanitizers by test/fuzz.sh.
 *
 * Each round configures an instance at random (diffserv mode, isolation,
 * ACK filter, wash, ingress, overhead, rate, limits) and sends it a mix
 * of TCP connections over IPv4, IPv6 and 6in4 with options, SACKs and
 * timestamps, UDP, ICMP, fragments and random bytes, many of them then
 * corrupted: header lengths, data offsets, IP lengths, versions,
 * truncation, random bytes. The packet's first mbuf is cut at a random
 * point, the IP header at a layer 2 offset or none, and the header is
 * sometimes not writable. Dequeues are driven by a dummynet-like tick,
 * and some rounds reconfigure the instance, with failed allocations,
 * while packets are queued. At the end of a round every packet must have
 * been freed, and the CAKE_DEBUG consistency checker must have found no
 * error.
 *
 *   fuzz [packets [seed]]
 */
#include "fuzz_shim.h"
#include "dn_sched_cake.h"
#include "ours-cake.inc"

static struct {
	struct dn_schk	s;
	struct cake_schk c;
} sched;
static struct cake_si *si;
static uint64_t sched_time;
static unsigned long sent, ack_drops;

#include "gen.h"

static struct mbuf *
packet(void)
{
	uint8_t p[PKT_MAX];
	struct mbuf *m;
	int off, len, pad;

	/* the IP header: layer 3, layer 2 (Ethernet, VLAN), or anywhere */
	off = (int[]){0, 0, 0, 14, 18, -1}[rnd(6)];
	if (off < 0)
		off = rnd(64);
	memset(p, 0, sizeof(p));
	for (int i = 0; i < off; i++)
		p[i] = rnd(256);
	len = build(p, off);
	if (rnd(3) == 0)
		len = mutate(p, len, off);

	m = calloc(1, sizeof(*m));
	fuzz_mbufs++;
	m->m_pkthdr.len = len;
	m->m_len = rnd(2) ? len : rnd(len + 1);
	/* malloc() aligns to 16: pad so the IP header is 4-byte aligned,
	 * and the buffer still ends exactly at m_len */
	pad = (4 - off % 4) % 4;
	m->base = (malloc)(pad + m->m_len);
	m->m_data = m->base + pad;
	m->rest = (malloc)(len - m->m_len);
	memcpy(m->m_data, p, m->m_len);
	memcpy(m->rest, p + m->m_len, len - m->m_len);
	m->writable = rnd(8) != 0;
	dn_tag_add(m, MIN(off, len));
	return (m);
}

/* a random configuration; 'gen' marks it new for running instances */
static void
configure(void)
{
	struct dn_sch_cake_parms *cfg = &sched.c.cfg;
	static const uint32_t rates[] = {0, 1000, 200000, 10000000,
	    100000000, 1000000000, 4000000000u};

	*cfg = cake_sysctl;
	cfg->diffserv = rnd(CAKE_DIFFSERV_MAX + 1);
	cfg->flow_mode = rnd(CAKE_FLOW_MAX + 1);
	/* small tables: the checker walks them on every operation */
	cfg->flows_cnt = (uint32_t[]){CAKE_SET_WAYS, 64, 256}[rnd(3)];
	cfg->flags = 0;
	if (rnd(2))
		cfg->flags |= CAKE_ECN_ENABLED;
	if (rnd(2))
		cfg->flags |= CAKE_WASH;
	if (rnd(2))
		cfg->flags |= CAKE_ACK_FILTER;
	if (rnd(2))
		cfg->flags |= CAKE_ACK_AGGRESSIVE;
	if (rnd(3) == 0)
		cfg->flags |= CAKE_INGRESS;
	cfg->overhead = rnd(2) ? 0 : (int32_t)rnd(321) - 64;
	cfg->mpu = rnd(2) ? 0 : rnd(257);
	cfg->atm = rnd(CAKE_ATM_MAX + 1);
	cfg->memlimit = rnd(2) ? 0 : 1 + rnd(256);
	cfg->limit = (uint32_t[]){10240, 1, 16, 1000}[rnd(4)];
	cfg->quantum = (uint32_t[]){1514, 300, 64, 9000}[rnd(4)];
	cfg->target = (uint64_t[]){5000, 1, 100000}[rnd(3)];
	cfg->interval = cfg->target * (1 + rnd(40));
	sched.s.link.bandwidth = rates[rnd(sizeof(rates) / sizeof(rates[0]))];
	sched.c.gen++;
}

/* dummynet's serve_sched() on each tick, as sched-diff's ours_serve() */
static void
serve(void)
{
	uint64_t now = fuzz_now_ns * hz / 1000000000;
	struct mbuf *m;

	si->_si.credit += (int64_t)(now - sched_time) *
	    (sched.s.link.bandwidth ? sched.s.link.bandwidth : 1000000000);
	sched_time = si->_si.sched_time = now;
	while (si->_si.credit >= 0 && (m = cake_dequeue(&si->_si)) != NULL) {
		si->_si.credit -= (int64_t)hz * m->m_pkthdr.len * 8;
		sent++;
		m_freem(m);
	}
	if (si->_si.credit >= 0)
		si->_si.credit = 0;
}

static void
round_run(int npkts)
{
	int i;

	configure();
	new_conns();
	si = calloc(1, sizeof(*si));
	si->_si.sched = &sched.s;
	set_oid(&si->main_q.ni.oid, DN_QUEUE, sizeof(si->main_q));
	si->main_q._si = &si->_si;
	if (cake_new_tables(si, &sched.c) != 0)
		fuzz_fail("cake_new_tables");
	sched_time = fuzz_now_ns * hz / 1000000000;

	for (i = 0; i < npkts; i++) {
		cake_enqueue(&si->_si, NULL, packet());
		if (rnd(4) == 0) {
			fuzz_now_ns += rnd(4) ? rnd(200000) : rnd(20000000);
			serve();
		}
		if (rnd(5000) == 0) {	/* reconfigure, maybe without memory */
			if (rnd(2))
				cake_fail_alloc = rnd(8);
			configure();
		}
	}
	cake_fail_alloc = 0;
	/* drain some, then drop the rest with the tables */
	for (i = 0; i < 50; i++) {
		fuzz_now_ns += 1000000;
		serve();
	}
	for (i = 0; i < (int)si->tin_cnt; i++)
		ack_drops += si->tins[i].ack_drops;
	cake_free_tables(si, si->flows, si->hosts, si->overflow_heap,
	    si->tin_cnt * si->flows_cnt);
	(free)(si);
	if (fuzz_mbufs != 0) {
		fprintf(stderr, "fuzz: %ld packets not freed\n", fuzz_mbufs);
		abort();
	}
}

int
main(int argc, char **argv)
{
	long total = argc > 1 ? atol(argv[1]) : 1000000, done = 0;
	uint64_t seed = argc > 2 ? strtoull(argv[2], NULL, 0) : 1;
	int rounds = 0, n;

	fuzz_rng = seed ? seed : 1;
	fuzz_now_ns = 1000000000ULL;
	while (done < total) {
		n = 1000 + (long)rnd(20000);
		n = MIN(n, total - done);
		round_run(n);
		done += n;
		rounds++;
	}
	printf("%ld packets in %d rounds (seed %llu): %lu sent, %lu mutated, "
	    "%lu ACKs filtered, check_errors %u\n", done, rounds,
	    (unsigned long long)seed, sent, mutated, ack_drops,
	    cake_check_errors);
	printf("  kinds tcp %lu udp %lu icmp %lu fragment %lu random %lu\n",
	    kinds[0] + kinds[1] + kinds[2] + kinds[3] + kinds[4] + kinds[5] +
	    kinds[6] + kinds[7] + kinds[8] + kinds[9], kinds[10] + kinds[11],
	    kinds[12], kinds[13], kinds[14] + kinds[15]);
	return (cake_check_errors != 0);
}
