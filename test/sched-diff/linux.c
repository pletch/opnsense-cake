/*
 * Linux sch_cake's scheduling core (extracted by extract-linux.sh into
 * linux-cake.inc), behind sched-diff's common interface.
 */
#include "linux_shim.h"
#include "linux-cake.inc"

static struct net_device dev;
static struct Qdisc *sch;

/* dn_sched_cake's diffserv numbers to sch_cake's */
static const int diffserv_map[] = {
	CAKE_DIFFSERV_BESTEFFORT, CAKE_DIFFSERV_DIFFSERV3,
	CAKE_DIFFSERV_DIFFSERV4, CAKE_DIFFSERV_DIFFSERV8,
	CAKE_DIFFSERV_PRECEDENCE
};

/* cake_init() without netlink: defaults, then the run's settings */
static void
l_init(const struct sd_config *c)
{
	struct cake_sched_data *qd;
	struct cake_sched_config *q;
	int i, j;

	sch = calloc(1, sizeof(*sch) + sizeof(struct cake_sched_data));
	sch->dev = &dev;
	qd = qdisc_priv(sch);
	q = &qd->initial_config;
	cake_config_init(q, false);
	q->tin_mode = diffserv_map[c->diffserv];
	q->flow_mode = c->flow_mode;
	q->rate_bps = c->rate / 8;	/* despite the name, bytes per second */
	/* as tc's overhead keywords set them */
	if (c->overhead || c->mpu || c->atm) {
		q->rate_flags |= CAKE_FLAG_OVERHEAD;
		q->rate_overhead = c->overhead;
		q->rate_mpu = c->mpu;
		q->atm_mode = c->atm;
	}
	if (c->ingress)
		q->rate_flags |= CAKE_FLAG_INGRESS;
	q->ack_filter = c->ack_filter;
	q->buffer_config_limit = c->memlimit;
	sch->limit = 10240;
	qd->config = q;

	quantum_div[0] = ~0;
	for (i = 1; i <= CAKE_QUEUES; i++)
		quantum_div[i] = 65535 / i;

	qd->tins = calloc(CAKE_MAX_TINS, sizeof(struct cake_tin_data));
	for (i = 0; i < CAKE_MAX_TINS; i++) {
		struct cake_tin_data *b = qd->tins + i;

		INIT_LIST_HEAD(&b->new_flows);
		INIT_LIST_HEAD(&b->old_flows);
		INIT_LIST_HEAD(&b->decaying_flows);
		for (j = 0; j < CAKE_QUEUES; j++) {
			struct cake_flow *flow = b->flows + j;
			u32 k = j * CAKE_MAX_TINS + i;

			INIT_LIST_HEAD(&flow->flowchain);
			cobalt_vars_init(&flow->cvars);
			/* dn_sched_cake's deliberate start at 1/sqrt(1), which
			 * cobalt-diff measures separately */
			flow->cvars.rec_inv_sqrt = ~0U;
			qd->overflow_heap[k].t = i;
			qd->overflow_heap[k].b = j;
			b->overflow_idx[j] = k;
		}
	}
	cake_reconfigure(sch);
}

static void
l_enqueue(struct trace_pkt *p)
{
	struct sk_buff *skb = calloc(1, sizeof(*skb)), *to_free = NULL;

	skb->len = skb->truesize = p->len;
	skb->trace = p;
	cake_enqueue(skb, sch, &to_free);
}

static struct trace_pkt *
l_dequeue(int *tin)
{
	struct cake_sched_data *qd = qdisc_priv(sch);
	struct sk_buff *skb = cake_dequeue(sch);
	struct trace_pkt *p;

	if (skb == NULL)
		return (NULL);
	*tin = qd->cur_tin;
	p = skb->trace;
	free(skb);
	return (p);
}

static uint32_t
l_qlen(void)
{
	return (sch->q.qlen);
}

static void
l_debug(void)
{
	struct cake_sched_data *qd = qdisc_priv(sch);
	int t;

	printf("    sch_cake     ");
	for (t = 0; t < qd->tin_cnt; t++) {
		struct cake_tin_data *b = &qd->tins[t];

		printf(" [%d next %+lld backlog %u sp %u bk %u]", t,
		    (long long)(b->time_next_packet - (s64)trace_now_ns),
		    b->tin_backlog, b->sparse_flow_count, b->bulk_flow_count);
	}
	printf("\n");
}

static void
l_debug_flow(uint32_t flow)
{
	struct cake_sched_data *qd = qdisc_priv(sch);
	struct sk_buff *skb;
	int t, i;

	for (t = 0; t < qd->tin_cnt; t++)
		for (i = 0; i < CAKE_QUEUES; i++) {
			skb = qd->tins[t].flows[i].head;
			if (skb == NULL || skb->trace->flow != flow)
				continue;
			printf("    sch_cake      tin %d slot %d def %d set %d cnt %u drp %d next %+lld p %u q:",
			    t, i, qd->tins[t].flows[i].deficit, qd->tins[t].flows[i].set,
			    qd->tins[t].flows[i].cvars.count, qd->tins[t].flows[i].cvars.dropping,
			    (long long)(qd->tins[t].flows[i].cvars.drop_next - (s64)trace_now_ns),
			    qd->tins[t].flows[i].cvars.p_drop);
			for (; skb != NULL; skb = skb->next)
				printf(" %u", skb->trace->id);
			printf("\n");
		}
}

/*
 * sched-diff link: when sch_cake's shaper next lets a packet out, as its
 * cake_dequeue() checks it (the earlier of the shaper and the failsafe
 * time); UINT64_MAX while nothing is queued.
 */
uint64_t
linux_next_release(void)
{
	struct cake_sched_data *qd = qdisc_priv(sch);
	uint64_t t = (uint64_t)qd->time_next_packet;
	uint64_t f = (uint64_t)qd->failsafe_next_packet;

	if (sch->q.qlen == 0)
		return (UINT64_MAX);
	return (t < f ? t : f);
}

const struct sched_impl linux_impl = {
	"sch_cake", l_init, l_enqueue, l_dequeue, l_qlen, l_debug, l_debug_flow
};
