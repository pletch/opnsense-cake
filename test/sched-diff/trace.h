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
	uint16_t	len;		/* bytes */
	/* per side: 0 queued, 1 sent, 2 dropped */
	uint8_t		linux_state, ours_state;
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
	void	(*init)(int diffserv, int flow_mode, uint64_t rate_bps);
	void	(*enqueue)(struct trace_pkt *);
	/* the packet sent now, or NULL; *tin set to its tin */
	struct trace_pkt *(*dequeue)(int *tin);
	uint32_t (*qlen)(void);
	void	(*debug)(void);		/* print the tins' state */
};
extern const struct sched_impl linux_impl, ours_impl;

#endif
