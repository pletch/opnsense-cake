/*
 * Linux sch_cake's scheduling core (extracted by extract-linux.sh into
 * linux-cake.inc), behind sched-diff's common interface.
 */
#include "linux_shim.h"
#include "linux-cake.inc"

static struct net_device dev;
static struct Qdisc *sch;

/* cake_init() without netlink: defaults, then the stage's settings */
static void
l_init(int diffserv, int flow_mode, uint64_t rate_bps)
{
	struct cake_sched_data *qd;
	struct cake_sched_config *q;
	int i, j;

	sch = calloc(1, sizeof(*sch) + sizeof(struct cake_sched_data));
	sch->dev = &dev;
	qd = qdisc_priv(sch);
	q = &qd->initial_config;
	cake_config_init(q, false);
	q->tin_mode = diffserv;
	q->flow_mode = flow_mode;
	q->rate_bps = rate_bps / 8;	/* despite the name, bytes per second */
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

const struct sched_impl linux_impl = {
	"sch_cake", l_init, l_enqueue, l_dequeue, l_qlen, l_debug
};
