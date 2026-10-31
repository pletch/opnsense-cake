/*
 * What sched-diff's two schedulers share: the trace packets, the clock,
 * the hash function behind the flow and host hashes, and a random stream
 * and drop log per side.
 */
#ifndef TRACE_H
#define TRACE_H

#include <stdint.h>

struct trace_pkt {
	uint32_t	id;
	uint32_t	flow, src, dst;	/* flow (ports) and host identities */
	uint8_t		dscp;		/* 6-bit DSCP */
	uint8_t		ecn;		/* ECN-capable */
	uint16_t	len;		/* bytes, IP header included */
	/* per side: 0 queued, 1 sent, 2 dropped */
	uint8_t		linux_state, ours_state;
	/* the IPv4 and TCP headers, as both sides parse them */
	uint8_t		hdr[128];
};

/* the settings of a run, beyond diffserv and flow isolation */
struct sd_config {
	int		diffserv;	/* dn_sched_cake's CAKE_DIFFSERV_* */
	int		flow_mode;	/* CAKE_FLOW_*, the same in both */
	uint64_t	rate;		/* bit/s */
	int		overhead;	/* bytes; with mpu and atm: compensation */
	int		mpu;
	int		atm;		/* 0 none, 1 ATM, 2 PTM, the same in both */
	int		ingress;
	int		ack_filter;	/* 0 off, 1 on, 2 aggressive */
	uint32_t	memlimit;	/* bytes, a multiple of 1024; 0 default */
};

extern uint64_t trace_now_ns;

uint32_t trace_hash(uint32_t src, uint32_t dst, uint32_t ports, uint8_t proto);
uint32_t trace_random_linux(void);
uint32_t trace_random_ours(void);
void trace_dropped_linux(struct trace_pkt *);
void trace_dropped_ours(struct trace_pkt *);

/* one implementation, behind a common interface */
struct sched_impl {
	const char *name;
	void	(*init)(const struct sd_config *);
	void	(*enqueue)(struct trace_pkt *);
	/* the packet sent now, or NULL; *tin set to its tin */
	struct trace_pkt *(*dequeue)(int *tin);
	uint32_t (*qlen)(void);
	void	(*debug)(void);		/* print the tins' state */
	void	(*debug_flow)(uint32_t flow);	/* print its queued packets */
	/* a tin's peak, average and base delay EWMAs, ns; 0 if no such tin */
	int	(*delays)(int tin, uint64_t d[3]);
};
extern const struct sched_impl linux_impl, ours_impl;

#endif
