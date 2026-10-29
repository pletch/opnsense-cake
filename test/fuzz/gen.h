/*
 * The packets test/fuzz sends dn_sched_cake, shared by the userland fuzzer
 * (fuzz.c) and the kernel one (test/kfuzz): TCP connections over IPv4,
 * IPv6 and 6in4 with options, SACKs and timestamps, UDP, ICMP, fragments
 * and random bytes, and the ways mutate() corrupts them. The includer
 * provides fuzz_random(), memset(), memcpy(), MIN() and the IP and TCP
 * constants.
 */

#define	PKT_MAX	256

static unsigned long kinds[16], mutated;

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
