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
static uint64_t sched_time;	/* the pipe's last service, in ticks */

static void
o_init(const struct sd_config *c)
{
	sched.s.link.bandwidth = (uint32_t)c->rate;
	sched.c.cfg = cake_sysctl;
	sched.c.cfg.diffserv = c->diffserv;
	sched.c.cfg.flow_mode = c->flow_mode;
	sched.c.cfg.flows_cnt = 1024;	/* sch_cake's CAKE_QUEUES */
	sched.c.cfg.overhead = c->overhead;
	sched.c.cfg.mpu = c->mpu;
	sched.c.cfg.atm = c->atm;
	if (c->ingress)
		sched.c.cfg.flags |= CAKE_INGRESS;
	if (c->ack_filter)
		sched.c.cfg.flags |= CAKE_ACK_FILTER;
	if (c->ack_filter == 2)
		sched.c.cfg.flags |= CAKE_ACK_AGGRESSIVE;
	sched.c.cfg.memlimit = c->memlimit >> 10;
	/* sch_cake has no packet limit, only the byte one; ours is an
	 * addition (memory per packet), kept out of the way here */
	sched.c.cfg.limit = 1000000;
	sched.c.gen = 1;
	/* stepped with sch_cake's releases, the real time is the link's;
	 * sched-diff link and pace turn the link clock on */
	cake_link_clock = 0;

	si = calloc(1, sizeof(*si));
	si->_si.sched = &sched.s;
	set_oid(&si->main_q.ni.oid, DN_QUEUE, sizeof(si->main_q));
	si->main_q._si = &si->_si;
	cake_new_tables(si, &sched.c);
	sched_time = trace_now_ns * hz / 1000000000;
}

static void
o_enqueue(struct trace_pkt *p)
{
	struct mbuf *m = calloc(1, sizeof(*m));

	/* the trace's IPv4 and TCP headers, for ECN marking and the ACK
	 * filter; marking changes this copy only */
	memcpy(m->buf, p->hdr, sizeof(m->buf));
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

/*
 * sched-diff pace: dummynet's own release mechanism instead of sch_cake's
 * shaper. As serve_sched() on each tick at kern.hz=khz: the pipe's credit
 * (bits * hz) grows by the bandwidth per tick elapsed, and the scheduler
 * is asked for packets while it is not negative, each costing its length.
 */
void
ours_set_hz(int khz)
{
	hz = khz;
	sched_time = trace_now_ns * hz / 1000000000;
	si->_si.credit = 0;
}

void
ours_set_link_clock(int on)
{
	cake_link_clock = on;
}

int
ours_serve(void (*sent)(struct trace_pkt *, int))
{
	uint64_t now = trace_now_ns * hz / 1000000000;
	struct trace_pkt *p;
	int n = 0, t;

	si->_si.credit += (int64_t)(now - sched_time) * sched.s.link.bandwidth;
	sched_time = now;
	while (si->_si.credit >= 0 && (p = o_dequeue(&t)) != NULL) {
		si->_si.credit -= (int64_t)hz * p->len * 8;
		sent(p, t);
		n++;
	}
	if (si->_si.credit >= 0)	/* idle: no credit saved up */
		si->_si.credit = 0;
	return (n);
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

static void
o_debug_flow(uint32_t flow)
{
	struct mbuf *m;
	uint32_t i;

	for (i = 0; i < si->tin_cnt * si->flows_cnt; i++) {
		m = si->flows[i].mq.head;
		if (m == NULL || m->trace->flow != flow)
			continue;
		printf("    dn_sched_cake tin %u slot %u def %d set %d cnt %u drp %d next %+lld p %u q:",
		    i / si->flows_cnt, i % si->flows_cnt, si->flows[i].deficit,
		    si->flows[i].set, si->flows[i].cvars.count, si->flows[i].cvars.dropping,
		    (long long)(si->flows[i].cvars.drop_next - trace_now_ns),
		    si->flows[i].cvars.p_drop);
		for (; m != NULL; m = m->m_nextpkt)
			printf(" %u", m->trace->id);
		printf("\n");
	}
}

const struct sched_impl ours_impl = {
	"dn_sched_cake", o_init, o_enqueue, o_dequeue, o_qlen, o_debug,
	o_debug_flow
};
