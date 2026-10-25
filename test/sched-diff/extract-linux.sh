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
range '^#define CAKE_SET_WAYS' '^static u8 cake_handle_diffserv('
cat <<'STUB'
/* sched-diff: the DSCP comes from the trace (washing is not compared) */
static u8 cake_handle_diffserv(struct sk_buff *skb, bool wash)
{
	(void)wash;
	return skb->trace->dscp;
}
STUB
range '^static struct cake_tin_data \*cake_select_tin(' '^static const struct nla_policy cake_policy'
range '^static void cake_set_rate(' '^static int cake_config_change('
range '^static void cake_config_init(' '^static int cake_init('
