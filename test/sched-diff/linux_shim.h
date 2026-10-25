/*
 * Just enough of the Linux kernel API for sch_cake's scheduling core to
 * build in userland for sched-diff. Packets carry their trace identity;
 * the flow dissector hands it to cake_hash() and flow_hash_from_keys()
 * turns it into the same hashes the driver gives dn_sched_cake.
 */
#ifndef LINUX_SHIM_H
#define LINUX_SHIM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "trace.h"

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int16_t s16;
typedef int32_t s32;
typedef int64_t s64;
typedef s64 ktime_t;
typedef u16 __be16;
typedef u32 __be32;

#define __read_mostly
#define __rcu
#define __init
#define __exit
#define fallthrough	do {} while (0)
#define likely(x)	(x)
#define unlikely(x)	(x)
#define WRITE_ONCE(x, v)	((x) = (v))
#define READ_ONCE(x)	(x)
#define IS_ENABLED(x)	0
#define BIT(n)		(1UL << (n))
#define NSEC_PER_USEC	1000ULL
#define USEC_PER_SEC	1000000ULL
#define NSEC_PER_SEC	1000000000ULL
#define KTIME_MAX	INT64_MAX
#define min(a, b)	((a) < (b) ? (a) : (b))
#define max(a, b)	((a) > (b) ? (a) : (b))
#define min_t(t, a, b)	((t)(a) < (t)(b) ? (t)(a) : (t)(b))
#define max_t(t, a, b)	((t)(a) > (t)(b) ? (t)(a) : (t)(b))
#define do_div(n, base)	({ u32 __r = (n) % (base); (n) /= (base); __r; })
#define div64_u64(a, b)	((a) / (b))
#define ilog2(n)	(63 - __builtin_clzll(n))
#define ARRAY_SIZE(a)	(sizeof(a) / sizeof((a)[0]))

#define ktime_sub(a, b)		((a) - (b))
#define ktime_add_ns(a, n)	((a) + (s64)(n))
#define ktime_add_ms(a, n)	((a) + (s64)(n) * 1000000)
#define ktime_to_ns(t)		(t)
#define ns_to_ktime(n)		((ktime_t)(n))
#define ktime_before(a, b)	((a) < (b))
#define ktime_after(a, b)	((a) > (b))
#define ktime_compare(a, b)	((a) < (b) ? -1 : (a) > (b))
static inline ktime_t ktime_get(void) { return (ktime_t)trace_now_ns; }

static inline u32 reciprocal_scale(u32 val, u32 ep_ro)
{
	return (u32)(((u64)val * ep_ro) >> 32);
}
static inline u32 get_random_u32(void) { return trace_random_linux(); }
static inline u16 get_random_u16(void) { return (u16)trace_random_linux(); }

/* lists (include/linux/list.h) */
struct list_head { struct list_head *next, *prev; };
#define INIT_LIST_HEAD(l)	((l)->next = (l)->prev = (l))
static inline void __list_add(struct list_head *n, struct list_head *p,
	struct list_head *x) { x->prev = n; n->next = x; n->prev = p; p->next = n; }
static inline void list_add_tail(struct list_head *n, struct list_head *h)
{ __list_add(n, h->prev, h); }
static inline void __list_del(struct list_head *p, struct list_head *x)
{ x->prev = p; p->next = x; }
static inline void list_del_init(struct list_head *e)
{ __list_del(e->prev, e->next); INIT_LIST_HEAD(e); }
static inline void list_move_tail(struct list_head *e, struct list_head *h)
{ __list_del(e->prev, e->next); list_add_tail(e, h); }
static inline int list_empty(const struct list_head *h) { return h->next == h; }
#define container_of(p, t, m)	((t *)((char *)(p) - offsetof(t, m)))
#define list_first_entry(h, t, m)	container_of((h)->next, t, m)

/* packets */
struct sk_buff {
	struct sk_buff	*next;
	unsigned int	len;
	unsigned int	truesize;
	u32		hash;
	u8		l4_hash;
	u32		mark;
	u32		priority;
	char		cb[48];
	u8		encapsulation;
	struct { unsigned short a, b; unsigned int c; } shinfo;
	struct trace_pkt *trace;	/* who this packet is */
};
struct qdisc_skb_cb { unsigned int pkt_len; unsigned int pkt_segs; u16 slave_dev_queue_mapping;
	u16 tc_classid; unsigned char data[20]; };
#define qdisc_skb_cb(skb)	((struct qdisc_skb_cb *)(skb)->cb)
#define qdisc_cb_private_validate(skb, sz)	do {} while (0)
static inline unsigned int qdisc_pkt_len(const struct sk_buff *skb) { return skb->len; }
static inline bool skb_is_gso(const struct sk_buff *skb) { (void)skb; return false; }
#define skb_mark_not_on_list(skb)	((skb)->next = NULL)
/* GSO segmentation: never reached, as no packet is GSO */
typedef u64 netdev_features_t;
#define NETIF_F_GSO_MASK	0
#define netif_skb_features(skb)	0
#define qdisc_pkt_segs(skb)	1
#define skb_gso_segment(skb, f)	((struct sk_buff *)NULL)
#define IS_ERR_OR_NULL(p)	((p) == NULL)
#define skb_list_walk_safe(first, skb, next_skb) \
	for ((skb) = (first), (next_skb) = (skb) ? (skb)->next : NULL; (skb); \
	    (skb) = (next_skb), (next_skb) = (skb) ? (skb)->next : NULL)
#define consume_skb(skb)	(trace_dropped_linux((skb)->trace), free(skb))
/*
 * The packet's headers, for the ACK filter: the trace's IPv4 and TCP
 * headers at offset 0, as sched-diff gives both sides IP packets.
 */
#define skb_network_offset(skb)	0
static inline void *skb_header_pointer(const struct sk_buff *skb, int off,
	int len, void *buf)
{
	if (off < 0 || off + len > (int)skb->len || off + len > 128)
		return (NULL);
	memcpy(buf, skb->trace->hdr + off, len);
	return (buf);
}
static inline u32 get_unaligned_be32(const void *p)
{ const u8 *b = p; return ((u32)b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]; }
static inline u16 shim_bswap16(u16 x) { return (u16)((x << 8) | (x >> 8)); }
static inline u32 shim_bswap32(u32 x) { return __builtin_bswap32(x); }
#define htons(x)	shim_bswap16(x)
#define ntohs(x)	shim_bswap16(x)
#define htonl(x)	shim_bswap32(x)
#define ntohl(x)	shim_bswap32(x)
#define cpu_to_be32(x)	shim_bswap32(x)
#define before(a, b)	((s32)((a) - (b)) < 0)
#define after(a, b)	before(b, a)
#define IPPROTO_TCP	6
#define IPPROTO_UDP	17
#define IPPROTO_IPV6	41
typedef u16 __sum16;
struct iphdr {
	u8	ihl:4, version:4;
	u8	tos;
	__be16	tot_len, id, frag_off;
	u8	ttl, protocol;
	__sum16	check;
	__be32	saddr, daddr;
};
struct in6_addr { union { u8 u6_addr8[16]; __be32 u6_addr32[4]; } in6_u; };
struct ipv6hdr {
	u8	priority:4, version:4;
	u8	flow_lbl[3];
	__be16	payload_len;
	u8	nexthdr, hop_limit;
	struct in6_addr saddr, daddr;
};
#define ipv6_addr_cmp(a, b)	memcmp((a), (b), sizeof(struct in6_addr))
struct tcphdr {
	__be16	source, dest;
	__be32	seq, ack_seq;
	u16	res1:4, doff:4, fin:1, syn:1, rst:1, psh:1, ack:1, urg:1,
		ece:1, cwr:1;
	__be16	window;
	__sum16	check;
	__be16	urg_ptr;
};
struct udphdr { __be16 source, dest, len; __sum16 check; };
struct tcp_sack_block_wire { __be32 start_seq, end_seq; };
#define iph_totlen(skb, iph)	ntohs((iph)->tot_len)
#define ipv6_payload_len(skb, ip6)	ntohs((ip6)->payload_len)
#define __tcp_hdrlen(th)	((th)->doff * 4)
#define tcp_flag_word(tp)	(((const u32 *)(tp))[3])
#define TCP_FLAG_CWR	cpu_to_be32(0x00800000)
#define TCP_FLAG_ECE	cpu_to_be32(0x00400000)
#define TCP_FLAG_URG	cpu_to_be32(0x00200000)
#define TCP_FLAG_ACK	cpu_to_be32(0x00100000)
#define TCP_FLAG_PSH	cpu_to_be32(0x00080000)
#define TCP_FLAG_RST	cpu_to_be32(0x00040000)
#define TCP_FLAG_SYN	cpu_to_be32(0x00020000)
#define TCP_FLAG_FIN	cpu_to_be32(0x00010000)
#define TCPOPT_NOP	1
#define TCPOPT_EOL	0
#define TCPOPT_MSS	2
#define TCPOPT_WINDOW	3
#define TCPOPT_SACK_PERM 4
#define TCPOPT_SACK	5
#define TCPOPT_TIMESTAMP 8
#define TCPOPT_MD5SIG	19
#define TCPOPT_FASTOPEN	34
#define TCPOPT_EXP	254
#define TCPOLEN_TIMESTAMP 10
#define TCPOLEN_SACK_BASE 2
/* GSO packets never reach cake_overhead()'s segment path here */
struct skb_shared_info { unsigned short gso_size, gso_segs; unsigned int gso_type; };
#define SKB_GSO_TCPV4	1
#define SKB_GSO_TCPV6	2
#define skb_shinfo(skb)	((struct skb_shared_info *)&(skb)->shinfo)
#define skb_transport_offset(skb)	0
#define skb_inner_transport_offset(skb)	0

/* CoDel marks the packets the trace calls ECN-capable */
static inline bool INET_ECN_set_ce(struct sk_buff *skb) { return skb->trace->ecn; }

/* the flow dissector, from the packet's trace identity */
enum { FLOW_DISSECTOR_KEY_IPV4_ADDRS = 1, FLOW_DISSECTOR_KEY_IPV6_ADDRS = 2 };
#define FLOW_DISSECTOR_F_STOP_AT_FLOW_LABEL 0
struct flow_keys {
	struct { u16 addr_type; } control;
	struct { u8 ip_proto; } basic;
	struct { u32 keyid; } keyid;
	struct { u32 flow_label; } tags;
	struct { u32 ports; } ports;
	struct { struct { u32 src, dst; } v4addrs;
		struct { struct { u32 a[4]; } src, dst; } v6addrs; } addrs;
};
static inline void skb_flow_dissect_flow_keys(const struct sk_buff *skb,
	struct flow_keys *k, int flags)
{
	(void)flags;
	memset(k, 0, sizeof(*k));
	k->control.addr_type = FLOW_DISSECTOR_KEY_IPV4_ADDRS;
	k->addrs.v4addrs.src = skb->trace->src;
	k->addrs.v4addrs.dst = skb->trace->dst;
	k->ports.ports = skb->trace->flow;
	k->basic.ip_proto = 6;
}
static inline u32 flow_hash_from_keys(struct flow_keys *k)
{
	return trace_hash(k->addrs.v4addrs.src, k->addrs.v4addrs.dst,
	    k->ports.ports, k->basic.ip_proto);
}

/* the qdisc around it */
struct gnet_stats_queue { u32 qlen, backlog, drops, requeues, overlimits; };
struct Qdisc;
struct netdev_queue { struct Qdisc *qdisc_sleeping; };
/* multiqueue sharing: never reached, as the qdisc is not shared */
struct net_device { unsigned int num_tx_queues; struct netdev_queue txq; };
#define netdev_get_tx_queue(dev, n)	(&(dev)->txq)
struct Qdisc {
	struct { u32 qlen; } q;
	struct gnet_stats_queue qstats;
	u32 limit, handle, flags;
	struct net_device *dev;
	long priv[] __attribute__((aligned(64)));
};
#define TCQ_F_CAN_BYPASS	1
#define TCQ_F_DEQUEUE_DROPS	2
static inline void *qdisc_priv(struct Qdisc *q) { return q->priv; }
static inline struct net_device *qdisc_dev(struct Qdisc *q) { return q->dev; }
static inline unsigned int psched_mtu(const struct net_device *d) { (void)d; return 1514; }
#define qdisc_qstats_backlog_inc(sch, skb)	((sch)->qstats.backlog += qdisc_pkt_len(skb))
#define qdisc_qstats_backlog_dec(sch, skb)	((sch)->qstats.backlog -= qdisc_pkt_len(skb))
#define qstats_backlog_sub(sch, l)	((sch)->qstats.backlog -= (l))
#define qstats_backlog_add(sch, l)	((sch)->qstats.backlog += (l))
#define qdisc_qstats_overlimit(sch)	((sch)->qstats.overlimits++)
#define qdisc_qstats_drop(sch)		((sch)->qstats.drops++)
#define qdisc_qlen_dec(sch)		((sch)->q.qlen--)
#define qdisc_qlen_inc(sch)		((sch)->q.qlen++)
#define qdisc_bstats_update(sch, skb)	do {} while (0)
#define qdisc_tree_reduce_backlog(sch, n, l)	do {} while (0)
#define sch_tree_lock(sch)	do {} while (0)
#define sch_tree_unlock(sch)	do {} while (0)
struct qdisc_watchdog { int dummy; };
#define qdisc_watchdog_schedule_ns(w, t)	do {} while (0)
#define qdisc_watchdog_cancel(w)	do {} while (0)

enum qdisc_drop_reason {
	QDISC_DROP_UNSPEC, QDISC_DROP_CONGESTED, QDISC_DROP_FLOOD_PROTECTION,
	QDISC_DROP_OVERLIMIT, QDISC_DROP_QUEUE_PURGED
};
#define SKB_DROP_REASON_QDISC_CONGESTED	1
#define SKB_DROP_REASON_QUEUE_PURGE	2
static inline void kfree_skb_reason(struct sk_buff *skb, int r)
{ (void)r; trace_dropped_linux(skb->trace); free(skb); }
#define qdisc_drop_reason(skb, sch, to_free, r) \
	((sch)->qstats.drops++, trace_dropped_linux((skb)->trace), free(skb), NET_XMIT_DROP)
#define qdisc_dequeue_drop(sch, skb, r)	kfree_skb_reason(skb, r)
#define qdisc_drop(skb, sch, to_free)	qdisc_drop_reason(skb, sch, to_free, 0)
#define __qdisc_drop(skb, to_free)	(trace_dropped_linux((skb)->trace), free(skb))

#define NET_XMIT_SUCCESS	0
#define NET_XMIT_DROP		1
#define NET_XMIT_CN		2
#define __NET_XMIT_BYPASS	0x20000
#define __NET_XMIT_STOLEN	0x10000

/* classifiers: none attached */
struct tcf_proto;
struct tcf_result { u32 classid; };
struct tcf_block;
#define rcu_dereference_bh(p)	(p)
#define rcu_dereference(p)	(p)
#define tcf_classify_qdisc(skb, f, r, c)	(-1)
#define TC_H_MAJ(h)	((h) & 0xFFFF0000U)
#define TC_H_MIN(h)	((h) & 0x0000FFFFU)

/* u64_stats */
typedef struct { u64 v; } u64_stats_t;
struct u64_stats_sync { int dummy; };
#define u64_stats_read(p)	((p)->v)
#define u64_stats_set(p, x)	((p)->v = (x))
#define u64_stats_update_begin(s)	do {} while (0)
#define u64_stats_update_end(s)	do {} while (0)
#define u64_stats_init(s)	do {} while (0)

#endif
