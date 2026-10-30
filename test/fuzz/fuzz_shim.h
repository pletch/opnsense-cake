/*
 * Just enough of FreeBSD's kernel and dummynet for dn_sched_cake's
 * scheduling core, packet parsers included, to build in userland for
 * test/fuzz.sh. An mbuf is two exactly sized buffers: the first mbuf's
 * data (m_len bytes) and the rest of the packet, so that the sanitizers
 * catch any access past the first mbuf or the packet, and m_copydata()
 * fails on a range outside the packet as the kernel's KASSERT does. The
 * IP header is 4-byte aligned, as drivers align it (ETHER_ALIGN).
 */
#ifndef FUZZ_SHIM_H
#define FUZZ_SHIM_H

#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/param.h>
#include <sys/queue.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <netinet/ip6.h>
#include <netinet/tcp.h>

#ifndef IPTOS_ECN_NOTECT
#define IPTOS_ECN_NOTECT	IPTOS_ECN_NOT_ECT
#endif
#ifndef TCPOPT_SIGNATURE
#define TCPOPT_SIGNATURE	19
#endif
static inline uint16_t be16dec(const void *p)
{ const uint8_t *b = p; return (uint16_t)((b[0] << 8) | b[1]); }
static inline uint32_t be32dec(const void *p)
{ const uint8_t *b = p; return ((uint32_t)b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]; }
#define __predict_false(x)	(x)
#define __predict_true(x)	(x)
#define __inline	inline
#define D(fmt, ...)	do { } while (0)
#define SEQ_LT(a, b)	((int32_t)((a) - (b)) < 0)
#define SEQ_LEQ(a, b)	((int32_t)((a) - (b)) <= 0)
#define SEQ_GT(a, b)	((int32_t)((a) - (b)) > 0)
#define SEQ_GEQ(a, b)	((int32_t)((a) - (b)) >= 0)
#define HASHINIT	5381
/* FNV-1a: any hash reading exactly 'l' bytes will do */
static inline uint32_t jenkins_hash(const void *k, size_t l, uint32_t i)
{
	const uint8_t *p = k;

	while (l-- > 0)
		i = (i ^ *p++) * 16777619u;
	return (i);
}

/* kernel malloc(9): userland calls go through (free)() and calloc() */
#define M_DUMMYNET	0
#define M_TEMP		0
#define M_NOWAIT	0
#define M_WAITOK	0
#define M_ZERO		0
#define mallocarray(n, s, t, f)	calloc((n), (s))
#define malloc(s, t, f)		calloc(1, (s))
#define free(p, t)		(free)(p)

#define SYSCTL_UINT(...)
#define ppsratecheck(t, c, m)	0
static int hz = 1000;
static int tick = 1000;

struct m_tag {
	SLIST_ENTRY(m_tag) m_tag_link;
	uint32_t	cookie;
	uint16_t	type, len;
};
#define MTAG_ABI_COMPAT	0
#define PACKET_TAG_DUMMYNET	15
struct dn_pkt_tag { int iphdr_off; };
struct mbuf {
	struct mbuf	*m_nextpkt;
	int		m_len;
	char		*m_data;	/* m_len bytes */
	char		*base;		/* their allocation, from 0-3 bytes before */
	char		*rest;		/* m_pkthdr.len - m_len bytes */
	int		writable;
	struct { int len; void *rcvif; } m_pkthdr;
	struct m_tag	*tags;
};
#define mtod(m, t)	((t)((m)->m_data))
#define mtodo(m, o)	((void *)((m)->m_data + (o)))
#define M_WRITABLE(m)	((m)->writable)

static void
fuzz_fail(const char *what)
{
	fprintf(stderr, "fuzz: %s\n", what);
	abort();
}

static inline void m_copydata(const struct mbuf *m, int off, int len, void *b)
{
	int n;

	if (off < 0 || len < 0 || off + len > m->m_pkthdr.len)
		fuzz_fail("m_copydata outside the packet");
	n = off < m->m_len ? MIN(len, m->m_len - off) : 0;
	memcpy(b, m->m_data + off, n);
	if (len > n)
		memcpy((char *)b + n, m->rest + (off + n - m->m_len), len - n);
}
static inline struct m_tag *m_tag_locate(struct mbuf *m, uint32_t c,
	int t, struct m_tag *s)
{
	struct m_tag *g;

	(void)s;
	for (g = m->tags; g != NULL; g = SLIST_NEXT(g, m_tag_link))
		if (g->cookie == c && g->type == t)
			return (g);
	return (NULL);
}
static inline struct m_tag *m_tag_alloc(uint32_t c, int t, int l, int f)
{
	struct m_tag *g = calloc(1, sizeof(*g) + l);

	(void)f;
	g->cookie = c;
	g->type = t;
	g->len = l;
	return (g);
}
static inline void m_tag_prepend(struct mbuf *m, struct m_tag *g)
{ SLIST_NEXT(g, m_tag_link) = m->tags; m->tags = g; }
static inline void m_tag_delete(struct mbuf *m, struct m_tag *g)
{
	struct m_tag **p;

	for (p = &m->tags; *p != NULL; p = &SLIST_NEXT(*p, m_tag_link))
		if (*p == g) {
			*p = SLIST_NEXT(g, m_tag_link);
			(free)(g);
			return;
		}
}
#define m_tag_first(m)	((m)->tags)
/* dummynet's tag, which dummynet_io() puts first and dn_tag_get() wants first */
static inline void dn_tag_add(struct mbuf *m, int iphdr_off)
{
	struct m_tag *g = m_tag_alloc(MTAG_ABI_COMPAT, PACKET_TAG_DUMMYNET,
	    sizeof(struct dn_pkt_tag), 0);

	((struct dn_pkt_tag *)(g + 1))->iphdr_off = iphdr_off;
	m_tag_prepend(m, g);
}
static inline struct dn_pkt_tag *dn_tag_get(struct mbuf *m)
{
	if (m->tags == NULL || m->tags->type != PACKET_TAG_DUMMYNET) {
		fprintf(stderr, "packet on dummynet queue w/o dummynet tag!\n");
		abort();
	}
	return ((struct dn_pkt_tag *)(m->tags + 1));
}

/* mbufs alive, for the leak check */
static long fuzz_mbufs;
static inline void m_freem(struct mbuf *m)
{
	while (m->tags != NULL)
		m_tag_delete(m, m->tags);
	(free)(m->base);
	(free)(m->rest);
	(free)(m);
	fuzz_mbufs--;
}
#define FREE_PKT(m)	m_freem(m)
#define m_rcvif_serialize(m)	do {} while (0)
#define m_rcvif_restore(m)	((m)->m_pkthdr.rcvif)
static inline uint16_t cksum_adjust(uint16_t s, uint16_t o, uint16_t n)
{ (void)o; (void)n; return s; }

/* dummynet */
struct dn_id { uint16_t len; uint8_t type, subtype; uint32_t id; };
#define DN_QUEUE	1
#define set_oid(o, t, l)	((o)->type = (t), (o)->len = (l))
struct dn_flow {
	struct dn_id oid;
	uint64_t tot_pkts, tot_bytes;
	uint32_t length, len_bytes, drops;
};
struct mq { struct mbuf *head, *tail; int count; };
static inline void mq_append(struct mq *q, struct mbuf *m)
{
	if (q->head == NULL)
		q->head = m;
	else
		q->tail->m_nextpkt = m;
	q->tail = m;
	q->count++;
	m->m_nextpkt = NULL;
}
struct dn_link { uint32_t bandwidth; };
struct dn_sch { uint32_t sched_nr; uint32_t flags; };
#define DN_HAVE_MASK	1
struct dn_fsk;
struct dn_alg { const char *name; int ref_count; };
struct dn_schk {
	struct dn_sch sch;
	struct dn_alg *fp;
	struct dn_link link;
	struct dn_fsk *fs;
};
struct dn_sch_inst {
	struct dn_flow ni;
	struct dn_schk *sched;
	int kflags;
	int64_t credit;
	uint64_t sched_time;	/* the release's time, set by the pipe */
};
struct dn_queue {
	struct dn_flow ni;
	struct mq mq;
	struct dn_sch_inst *_si;
	struct dn_fsk *fs;
	uint64_t q_time;
};
struct vnet;
static struct { uint64_t curr_time; uint64_t io_pkt_drop; } V_dn_cfg;

/* the fuzzer's clock and random numbers */
static uint64_t fuzz_now_ns;
static uint64_t fuzz_rng = 1;
static inline uint32_t fuzz_random(void)
{
	/* xorshift64* */
	fuzz_rng ^= fuzz_rng >> 12;
	fuzz_rng ^= fuzz_rng << 25;
	fuzz_rng ^= fuzz_rng >> 27;
	return ((uint32_t)((fuzz_rng * 2685821657736338717ULL) >> 32));
}
static inline uint64_t cake_now_ns(void) { return fuzz_now_ns; }
static inline uint64_t cake_now_us(void) { return fuzz_now_ns / 1000; }
static inline uint32_t cake_random(void) { return fuzz_random(); }

#endif
