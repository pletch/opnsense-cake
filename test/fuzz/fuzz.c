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
 * First, fixed checks: after every change of diffserv mode on a live
 * instance, each DSCP is queued in the new mode's tin (reconfig_dscp()),
 * IPv6 extension headers are looked through for the ports (hash_ext6()),
 * and a packet to be segmented is charged as its segments (tso_bytes()).
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
	/* sometimes marked for segmentation, whatever it holds */
	if (rnd(8) == 0) {
		m->m_pkthdr.csum_flags = CSUM_TSO;
		m->m_pkthdr.tso_segsz = rnd(4) ? 1 + rnd(200) : rnd(3) - 1;
	}
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

	*cfg = cake_defaults;
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
#ifndef CAKE_UPSTREAM
	if (rnd(3) == 0)
		cfg->flags |= CAKE_INGRESS;
#else
	(void)rnd(3);
#endif
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

/* a packet of the given bytes in one writable mbuf, its IP header first */
static struct mbuf *
raw_packet(const uint8_t *p, int len)
{
	struct mbuf *m;

	m = calloc(1, sizeof(*m));
	fuzz_mbufs++;
	m->m_pkthdr.len = m->m_len = len;
	m->base = (malloc)(len);
	m->m_data = m->base;
	m->rest = (malloc)(0);
	memcpy(m->m_data, p, len);
	m->writable = 1;
	dn_tag_add(m, 0);
	return (m);
}

/* a well-formed IPv4 UDP datagram with the given DSCP, at layer 3 */
static struct mbuf *
dscp_packet(int dscp)
{
	uint8_t p[28] = { 0x45, dscp << 2, 0, 28, 0, 0, 0, 0, 64, 17, 0, 0,
	    10, 0, 0, 1, 10, 0, 0, 2, 0x30, 0x39, 0, 53, 0, 8, 0, 0 };

	return (raw_packet(p, sizeof(p)));
}

/*
 * The flow hash of an IPv6 UDP datagram from source port 'sport', behind
 * the extension headers 'ext' (each 8 bytes, the last a fragment header
 * if 'frag'; a later fragment, without the UDP header, if frag is 2).
 */
static uint32_t
hash6(const uint8_t *ext, int next, int frag, int sport)
{
	uint8_t p[40 + 8 * 4 + 8], dscp;
	uint32_t srch, dsth, h;
	struct mbuf *m;
	int off = 40, i;

	memset(p, 0, sizeof(p));
	p[0] = 0x60;
	p[6] = next ? ext[0] : IPPROTO_UDP;
	p[7] = 64;
	p[8] = 0xfd;
	p[23] = 1;		/* fd00::1 */
	p[24] = 0xfd;
	p[39] = 2;		/* fd00::2 */
	for (i = 0; i < next; i++, off += 8)
		p[off] = i + 1 < next ? ext[i + 1] : IPPROTO_UDP;
	if (frag == 2)		/* fragment offset 8, not the last */
		p[off - 5] = 0x09;
	if (frag != 2) {
		p[off] = sport >> 8;
		p[off + 1] = sport;
		p[off + 3] = 53;
		p[off + 5] = 8;
		off += 8;
	}
	p[5] = off - 40;
	m = raw_packet(p, off);
	h = cake_hash_flow(m, 0x1234, CAKE_FLOW_FLOWS, &dscp, &srch, &dsth);
	m_freem(m);
	return (h);
}

/*
 * IPv6 extension headers are looked through for the ports: a datagram
 * behind them hashes to the flow of the same datagram without them, and
 * to another flow from another port; all fragments of a datagram hash
 * alike, whatever their ports.
 */
static void
hash_ext6(void)
{
	static const uint8_t opts[] = { IPPROTO_HOPOPTS, IPPROTO_ROUTING,
	    IPPROTO_DSTOPTS };
	static const uint8_t fragd[] = { IPPROTO_DSTOPTS, IPPROTO_FRAGMENT };
	uint32_t plain = hash6(NULL, 0, 0, 1000);
	int n;

	if (plain == hash6(NULL, 0, 0, 1001))
		fuzz_fail("hash_ext6: ports not hashed");
	for (n = 1; n <= 3; n++) {
		if (hash6(opts, n, 0, 1000) != plain)
			fuzz_fail("hash_ext6: extension headers change the flow");
		if (hash6(opts, n, 0, 1001) == plain)
			fuzz_fail("hash_ext6: ports behind extension headers");
	}
	if (hash6(fragd, 2, 1, 1000) != hash6(fragd, 2, 2, 0) ||
	    hash6(fragd, 2, 1, 1000) != hash6(fragd, 2, 1, 1001))
		fuzz_fail("hash_ext6: fragments hash apart");
	if (hash6(fragd, 2, 1, 1000) == plain)
		fuzz_fail("hash_ext6: a fragment hashed with ports");
	if (fuzz_mbufs != 0)
		fuzz_fail("hash_ext6: packets not freed");
}

/*
 * A packet the interface is to segment (TSO) is charged as its segments,
 * each with the headers and the overhead, as sch_cake's cake_overhead()
 * charges a GSO packet: 4000 bytes of TCP payload in segments of 1448
 * are two of 1488 bytes and one of 1144.
 */
static void
tso_bytes(void)
{
	static uint8_t p[4040] = { 0x45, 0, 0, 0, 0, 0, 0x40, 0, 64, 6, 0, 0,
	    10, 0, 0, 1, 10, 0, 0, 2 };
	struct dn_sch_cake_parms cfg = cake_defaults;
	struct mbuf *m;

	p[20 + 12] = 5 << 4;		/* TCP header of 20 bytes */
	m = raw_packet(p, sizeof(p));
	if (cake_wire_bytes(&cfg, m) != 4040)
		fuzz_fail("tso_bytes: a plain packet");
	m->m_pkthdr.csum_flags = CSUM_TSO;
	m->m_pkthdr.tso_segsz = 1448;
	if (cake_wire_bytes(&cfg, m) != 2 * 1488 + 1144)
		fuzz_fail("tso_bytes: segments without compensation");
	cfg.overhead = 38;		/* ethernet */
	cfg.mpu = 84;
	if (cake_wire_bytes(&cfg, m) != 2 * (1488 + 38) + 1144 + 38)
		fuzz_fail("tso_bytes: segments with overhead");
	cfg.overhead = 48;		/* conservative: ATM cells */
	cfg.mpu = 0;
	cfg.atm = CAKE_ATM_ATM;
	if (cake_wire_bytes(&cfg, m) != 2 * 32 * 53 + 25 * 53)
		fuzz_fail("tso_bytes: segments in ATM cells");
	/* one segment, or not TCP: as it is */
	cfg = cake_defaults;
	m->m_pkthdr.tso_segsz = 4000;
	if (cake_wire_bytes(&cfg, m) != 4040)
		fuzz_fail("tso_bytes: a single segment");
	m->m_pkthdr.tso_segsz = 1448;
	m->m_data[9] = 17;
	if (cake_wire_bytes(&cfg, m) != 4040)
		fuzz_fail("tso_bytes: not TCP");
	m_freem(m);
}

/*
 * A live instance classifies by its scheduler's new diffserv mode: for
 * every change of mode with a packet queued, a packet of each DSCP must
 * then go to the new mode's tin. Most changes build new tables; diffserv8
 * and precedence have the same tin count, so that one is applied in place
 * (where the old DSCP map once stayed).
 */
static void
reconfig_dscp(void)
{
	struct dn_sch_cake_parms *cfg = &sched.c.cfg;
	uint32_t before[CAKE_MAX_TINS], from, to, t, want, got;
	int dscp;

	for (from = 0; from <= CAKE_DIFFSERV_MAX; from++)
	for (to = 0; to <= CAKE_DIFFSERV_MAX; to++) {
		if (from == to)
			continue;
		*cfg = cake_defaults;
		cfg->diffserv = from;
		cfg->flows_cnt = 64;
		cfg->flags = 0;		/* no wash: the DSCP stays */
		sched.s.link.bandwidth = 10000000;
		sched.c.gen++;
		si = calloc(1, sizeof(*si));
		si->_si.sched = &sched.s;
		set_oid(&si->main_q.ni.oid, DN_QUEUE, sizeof(si->main_q));
		si->main_q._si = &si->_si;
		if (cake_new_tables(si, &sched.c) != 0)
			fuzz_fail("cake_new_tables");
		cake_enqueue(&si->_si, NULL, dscp_packet(0));

		cfg->diffserv = to;
		sched.c.gen++;
		/* the next packet applies the change */
		cake_enqueue(&si->_si, NULL, dscp_packet(0));
		if (si->tin_cnt != cake_tin_cnt[to] || si->cfg.diffserv != to)
			fuzz_fail("diffserv mode not applied");
		for (dscp = 0; dscp < 64; dscp++) {
			for (t = 0; t < CAKE_MAX_TINS; t++)
				before[t] = t < si->tin_cnt ?
				    si->tins[t].backlog : 0;
			cake_enqueue(&si->_si, NULL, dscp_packet(dscp));
			want = cake_dscp_maps[to][dscp];
			got = CAKE_MAX_TINS;
			for (t = 0; t < si->tin_cnt; t++)
				if (si->tins[t].backlog == before[t] + 1)
					got = t;
			if (got != want) {
				fprintf(stderr, "fuzz: diffserv mode %u -> %u: "
				    "DSCP %d queued in tin %u, not %u\n",
				    from, to, dscp, got, want);
				abort();
			}
		}
		cake_free_tables(si, si->flows, si->hosts, si->overflow_heap,
		    si->tin_cnt * si->flows_cnt);
		(free)(si);
		if (fuzz_mbufs != 0)
			fuzz_fail("reconfig_dscp: packets not freed");
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
	reconfig_dscp();
	hash_ext6();
	tso_bytes();
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
