/*
 * Just enough of FreeBSD's kernel and dummynet for dn_sched_cake's
 * scheduling core to build in userland for sched-diff. Packets carry
 * their trace identity; cake_hash_flow() is replaced by one that returns
 * the hashes sch_cake computes for the same packet.
 */
#ifndef OURS_SHIM_H
#define OURS_SHIM_H

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

#include "trace.h"

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
#define D(fmt, ...)	fprintf(stderr, "%s: " fmt "\n", __func__, ##__VA_ARGS__)
#define SEQ_LT(a, b)	((int32_t)((a) - (b)) < 0)
#define SEQ_LEQ(a, b)	((int32_t)((a) - (b)) <= 0)
#define SEQ_GT(a, b)	((int32_t)((a) - (b)) > 0)
#define SEQ_GEQ(a, b)	((int32_t)((a) - (b)) >= 0)
#define HASHINIT	5381
static inline uint32_t jenkins_hash(const void *k, size_t l, uint32_t i)
{ (void)k; (void)l; return i; }

/* kernel malloc(9): userland calls go through (free)() and calloc() */
#define M_DUMMYNET	0
#define M_TEMP		0
#define M_NOWAIT	0
#define M_WAITOK	0
#define M_ZERO		0
#define mallocarray(n, s, t, f)	calloc((n), (s))
#define malloc(s, t, f)		calloc(1, (s))
#define free(p, t)		(free)(p)

/* sysctl(9) and logging: nothing to register */
#define SYSCTL_UINT(...)
#define ppsratecheck(t, c, m)	0
static int hz = 1000;
/* the pipe's clock (dn_sched_cake.c's DN_CREDIT_HZ, DN_RELEASE_NS):
 * dummynet's tick, unless sched-diff release models a finer one */
static int64_t credit_hz = 1000;
static uint64_t release_ns = 1000000;
#define DN_CREDIT_HZ	credit_hz
#define DN_RELEASE_NS	release_ns
/* dummynet's tick widens the target on slow tick rates (a deliberate
 * FreeBSD adaptation, documented); 1 us takes it out of the comparison */
static int tick = 1;

/* mbufs, with their tags, one buffer each */
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
	char		*m_data;
	struct { int len; void *rcvif; } m_pkthdr;
	struct m_tag	*tags;
	char		buf[128];	/* the IP and TCP headers */
	struct trace_pkt *trace;
};
#define mtod(m, t)	((t)((m)->m_data))
#define mtodo(m, o)	((void *)((m)->m_data + (o)))
#define M_WRITABLE(m)	1
static inline void m_copydata(const struct mbuf *m, int off, int len, void *b)
{ memcpy(b, m->m_data + off, len); }
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
static inline void m_free_tags(struct mbuf *m)
{
	while (m->tags != NULL)
		m_tag_delete(m, m->tags);
}
static inline void m_freem(struct mbuf *m)
{ trace_dropped_ours(m->trace); m_free_tags(m); (free)(m); }
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

/* the scheduler's clocks run on the trace's */
static inline uint64_t cake_now_ns(void) { return trace_now_ns; }
static inline uint64_t cake_now_us(void) { return trace_now_ns / 1000; }
#define arc4random()	trace_random_ours()

/* the hashes sch_cake gets from its flow dissector, rotated so that our
 * multiply-shift slot (top bits) is its modulo slot (low bits) */
static inline uint32_t trace_rot(uint32_t h) { return (h << 22) | (h >> 10); }
static uint32_t
cake_hash_flow(struct mbuf *m, uint32_t perturbation, uint32_t mode,
	uint8_t *dscp, uint32_t *srch, uint32_t *dsth)
{
	struct trace_pkt *p = m->trace;

	(void)perturbation;
	(void)mode;
	*dscp = p->dscp;
	*srch = trace_rot(trace_hash(p->src, 0, 0, 0));
	*dsth = trace_rot(trace_hash(0, p->dst, 0, 0));
	return (trace_rot(trace_hash(p->src, p->dst, p->flow, 6)));
}

#endif
