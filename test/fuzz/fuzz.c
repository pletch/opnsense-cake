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

#define	PKT_MAX	256

static struct {
	struct dn_schk	s;
	struct cake_schk c;
} sched;
static struct cake_si *si;
static uint64_t sched_time;
static unsigned long sent, kinds[16], mutated, ack_drops;

static uint32_t
rnd(uint32_t n)
{
	return (n ? fuzz_random() % n : 0);
}

/* the connections of a round: few, so the ACK filter sees each one often */
struct conn {
	int		af;	/* 4, 6, or 64 for 6in4 */
	uint8_t		src[16], dst[16];
	uint16_t	sport, dport;
	uint32_t	ack, tsval, tsecr;
};
static struct conn conns[8];
static int nconns;

static void
put16(uint8_t *p, uint16_t v)
{
	p[0] = v >> 8;
	p[1] = v;
}

static void
put32(uint8_t *p, uint32_t v)
{
	p[0] = v >> 24;
	p[1] = v >> 16;
	p[2] = v >> 8;
	p[3] = v;
}

static void
new_conns(void)
{
	int i, j;

	nconns = 1 + rnd(8);
	for (i = 0; i < nconns; i++) {
		struct conn *c = &conns[i];

		c->af = (int[]){4, 4, 6, 64}[rnd(4)];
		for (j = 0; j < 16; j++) {
			c->src[j] = rnd(4);	/* few hosts: host isolation */
			c->dst[j] = rnd(4);
		}
		c->sport = 1024 + rnd(4);
		c->dport = 80 + rnd(2);
		c->ack = fuzz_random();
		c->tsval = fuzz_random();
		c->tsecr = fuzz_random();
	}
}

/* TCP options, valid and not, up to 'room' bytes; returns their length */
static int
tcp_options(uint8_t *p, int room, struct conn *c)
{
	int n = 0, k, i, len;

	while (n < room && rnd(3) != 0) {
		switch (rnd(9)) {
		case 0:
			p[n++] = TCPOPT_NOP;
			break;
		case 1:
			p[n++] = TCPOPT_EOL;
			break;
		case 2:		/* timestamps, sometimes the wrong length */
			len = rnd(8) ? TCPOLEN_TIMESTAMP : rnd(12);
			if (n + 2 + 8 > room)
				return (n);
			p[n] = TCPOPT_TIMESTAMP;
			p[n + 1] = len;
			put32(p + n + 2, c->tsval += rnd(3));
			put32(p + n + 6, c->tsecr += rnd(2));
			n += 10;
			break;
		case 3:		/* SACK blocks around the ack, some DSACKs */
			k = 1 + rnd(4);
			len = rnd(8) ? 2 + 8 * k : rnd(40);
			if (n + 2 + 8 * k > room)
				return (n);
			p[n] = TCPOPT_SACK;
			p[n + 1] = len;
			for (i = 0; i < k; i++) {
				uint32_t s = c->ack + rnd(20000) - 2000;

				put32(p + n + 2 + 8 * i, s);
				put32(p + n + 6 + 8 * i, s + rnd(3000));
			}
			n += 2 + 8 * k;
			break;
		case 4:
			if (n + 4 > room)
				return (n);
			p[n] = TCPOPT_MAXSEG;
			p[n + 1] = 4;
			put16(p + n + 2, 1460);
			n += 4;
			break;
		case 5:
			if (n + 18 > room)
				return (n);
			p[n] = TCPOPT_SIGNATURE;
			p[n + 1] = 18;
			n += 18;
			break;
		default:	/* any kind, any length, even past the header */
			if (n + 2 > room)
				return (n);
			p[n] = rnd(256);
			p[n + 1] = rnd(64);
			n += 2;
			break;
		}
	}
	return (n);
}

/*
 * A packet into p, its IP header at 'off'; returns its length. Lengths in
 * the headers are those of what was built; mutate() may change them.
 */
static int
build(uint8_t *p, int off)
{
	struct conn *c = &conns[rnd(nconns)];
	int kind = rnd(16), ipoff = off, hlen, optlen, payload, len, af;
	uint8_t proto;

	kinds[kind]++;
	if (kind >= 14) {	/* random bytes, sometimes looking like IP */
		len = off + rnd(PKT_MAX - off);
		for (int i = off; i < len; i++)
			p[i] = rnd(256);
		if (len > off && rnd(2))
			p[off] = (rnd(2) ? 0x40 : 0x60) | rnd(16);
		return (len);
	}

	af = c->af;
	proto = kind < 10 ? IPPROTO_TCP : kind < 12 ? IPPROTO_UDP :
	    kind < 13 ? (af == 4 ? IPPROTO_ICMP : IPPROTO_ICMPV6) :
	    IPPROTO_TCP;
	if (af == 4 || af == 64) {
		p[off] = 0x45;
		p[off + 1] = rnd(256);		/* DSCP and ECN */
		put16(p + off + 4, rnd(65536));
		put16(p + off + 6, kind == 13 ? (rnd(2) ? 0x2000 : rnd(8192)) : 0);
		p[off + 8] = 64;
		p[off + 9] = af == 64 ? IPPROTO_IPV6 : proto;
		memcpy(p + off + 12, c->src, 4);
		memcpy(p + off + 16, c->dst, 4);
		off += 20;
	}
	if (af == 6 || af == 64) {
		uint32_t flow = 6u << 28 | rnd(256) << 20 | rnd(1 << 20);

		put32(p + off, flow);
		p[off + 6] = kind == 13 ? IPPROTO_FRAGMENT : proto;
		p[off + 7] = 64;
		memcpy(p + off + 8, c->src, 16);
		memcpy(p + off + 24, c->dst, 16);
		off += 40;
	}

	if (proto == IPPROTO_TCP) {
		/* mostly pure ACKs, acking a little more each time */
		memset(p + off, 0, 20);
		put16(p + off, c->sport);
		put16(p + off + 2, c->dport);
		put32(p + off + 4, fuzz_random());
		c->ack += rnd(4) ? rnd(3000) : -rnd(3000);
		put32(p + off + 8, c->ack);
		optlen = tcp_options(p + off + 20,
		    MIN(40, PKT_MAX - off - 20), c);
		optlen = MIN((optlen + 3) & ~3, 40);
		optlen = MIN(optlen, PKT_MAX - off - 20) & ~3;
		hlen = 20 + optlen;
		p[off + 12] = (hlen / 4) << 4;
		p[off + 13] = rnd(4) ? TH_ACK | (rnd(4) ? 0 : rnd(4) << 6) :
		    rnd(256);
		off += hlen;
	} else if (proto == IPPROTO_UDP) {
		put16(p + off, c->sport);
		put16(p + off + 2, c->dport);
		off += 8;
	} else {
		p[off] = rnd(256);
		off += 8;
	}
	payload = rnd(3) ? 0 : rnd(PKT_MAX - off + 1);
	for (int i = 0; i < payload; i++)
		p[off + i] = rnd(256);
	len = off + payload;

	if (af == 4 || af == 64)
		put16(p + ipoff + 2, len - ipoff);
	if (af == 6)
		put16(p + ipoff + 4, len - ipoff - 40);
	if (af == 64)
		put16(p + ipoff + 24, len - ipoff - 60);
	return (len);
}

/* corrupt some of the packet */
static int
mutate(uint8_t *p, int len, int off)
{
	int n = 1 + rnd(4);

	mutated++;
	while (n-- > 0 && len > 0) {
		switch (rnd(8)) {
		case 0:		/* IPv4 header length, low and high */
			if (off < len)
				p[off] = (p[off] & 0xf0) | rnd(16);
			break;
		case 1:		/* IP version */
			if (off < len)
				p[off] = (p[off] & 0x0f) | rnd(16) << 4;
			break;
		case 2:		/* IP length fields */
			if (off + 6 <= len)
				put16(p + off + (rnd(2) ? 2 : 4), rnd(4) ?
				    rnd(80) : rnd(65536));
			break;
		case 3:		/* a TCP data offset, wherever it may be */
			{
				int at = off + 20 + rnd(3) * 20 + 12;

				if (at < len)
					p[at] = rnd(16) << 4;
			}
			break;
		case 4:		/* truncate */
			len = rnd(len + 1);
			break;
		case 5:		/* the next header */
			if (off + 10 <= len)
				p[off + (rnd(2) ? 9 : 6)] = rnd(4) ?
				    (uint8_t[]){IPPROTO_TCP, IPPROTO_IPV6,
				    IPPROTO_UDP, 0}[rnd(4)] : rnd(256);
			break;
		default:	/* any bytes */
			for (int i = 1 + rnd(4); i > 0; i--)
				p[rnd(len)] = rnd(256);
			break;
		}
	}
	return (len);
}

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
	m->dn_tag.iphdr_off = MIN(off, len);
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
