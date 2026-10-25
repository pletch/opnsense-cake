#!/bin/sh
# sch_cake.c -> linux-cake.inc: the scheduling core, without the packet
# parsers (stubs below), netlink, statistics dumps and the mq variant
set -eu
SRC=$1 UAPI=$2
range() { sed -n "/$1/,/$2/p" "$SRC" | sed '$d'; }
# the CAKE enums of include/uapi/linux/pkt_sched.h
awk '/^enum \{$/ { buf = $0; inenum = 1; next }
    inenum { buf = buf "\n" $0
	if ($0 ~ /^};/) {
		if (buf ~ /CAKE_(FLOW_NONE|DIFFSERV_DIFFSERV3|ACK_NONE|ATM_NONE) /) print buf
		inenum = 0
	} }' "$UAPI"
range '^#define CAKE_SET_WAYS' '^static struct iphdr \*cake_get_iphdr('
cat <<'STUB'
/* sched-diff: the ACK filter and DSCP parsing are not part of stage 1 */
static struct sk_buff *cake_ack_filter(struct cake_sched_data *q,
				       struct cake_flow *flow)
{
	(void)q; (void)flow;
	return NULL;
}

static u8 cake_handle_diffserv(struct sk_buff *skb, bool wash)
{
	(void)wash;
	return skb->trace->dscp;
}

/* and no overhead compensation: a packet costs its length */
static u32 cake_overhead(struct cake_sched_data *q, const struct sk_buff *skb)
{
	(void)q;
	return skb->len;
}
STUB
range '^static u64 cake_ewma(' '^static u32 cake_calc_overhead('
range '^static void cake_heap_swap(' '^static u8 cake_handle_diffserv('
range '^static struct cake_tin_data \*cake_select_tin(' '^static const struct nla_policy cake_policy'
range '^static void cake_set_rate(' '^static int cake_config_change('
range '^static void cake_config_init(' '^static int cake_init('
