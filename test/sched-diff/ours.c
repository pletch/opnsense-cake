/*
 * dn_sched_cake's scheduling core (extracted by extract-ours.py into
 * ours-cake.inc), behind sched-diff's common interface.
 */
#include "ours_shim.h"
#include "dn_sched_cake.h"
#include "ours-cake.inc"

static struct {
	struct dn_schk	s;
	struct cake_schk c;
} sched;
static struct cake_si *si;

static void
o_init(int diffserv, int flow_mode, uint64_t rate_bps)
{
	sched.s.link.bandwidth = (uint32_t)rate_bps;
	sched.c.cfg = cake_sysctl;
	sched.c.cfg.diffserv = diffserv;
	sched.c.cfg.flow_mode = flow_mode;
	sched.c.cfg.flows_cnt = 1024;	/* sch_cake's CAKE_QUEUES */
	sched.c.gen = 1;

	si = calloc(1, sizeof(*si));
	si->_si.sched = &sched.s;
	set_oid(&si->main_q.ni.oid, DN_QUEUE, sizeof(si->main_q));
	si->main_q._si = &si->_si;
	cake_new_tables(si, &sched.c);
}

static void
o_enqueue(struct trace_pkt *p)
{
	struct mbuf *m = calloc(1, sizeof(*m));
	struct ip *ip = (struct ip *)m->buf;

	/* an IPv4 header, so that ECN marking has something to mark */
	ip->ip_v = 4;
	ip->ip_hl = 5;
	ip->ip_tos = (p->dscp << 2) | (p->ecn ? IPTOS_ECN_ECT0 : 0);
	ip->ip_len = htons(p->len);
	ip->ip_p = IPPROTO_TCP;
	m->m_data = m->buf;
	m->m_len = sizeof(m->buf);
	m->m_pkthdr.len = p->len;
	m->trace = p;
	cake_enqueue(&si->_si, NULL, m);
}

static struct trace_pkt *
o_dequeue(int *tin)
{
	struct mbuf *m = cake_dequeue(&si->_si);
	struct trace_pkt *p;

	if (m == NULL)
		return (NULL);
	*tin = si->cur_tin;
	p = m->trace;
	m_free_tags(m);
	(free)(m);
	return (p);
}

static uint32_t
o_qlen(void)
{
	return (si->main_q.ni.length);
}

#ifdef CAKE_DEBUG
uint32_t
ours_check_errors(void)
{
	return (cake_check_errors);
}
#endif

static void
o_debug(void)
{
	uint32_t t;

	printf("    dn_sched_cake");
	for (t = 0; t < si->tin_cnt; t++) {
		struct cake_tin *b = &si->tins[t];

		printf(" [%u next %+lld backlog %u sp %u bk %u]", t,
		    (long long)(b->time_next - trace_now_ns), b->backlog_bytes ?
		    (unsigned)b->backlog_bytes : 0, b->sparse_flows, b->bulk_flows);
	}
	printf("\n");
}

const struct sched_impl ours_impl = {
	"dn_sched_cake", o_init, o_enqueue, o_dequeue, o_qlen, o_debug
};
