/*
 * Malformed packets through the kernel's dummynet and CAKE, for a KASAN
 * kernel (test/kfuzz.sh). test/fuzz.sh runs CAKE's packet parsers in
 * userland, with stand-ins for the kernel's mbufs and jenkins_hash();
 * this sends the same packets (test/fuzz/gen.h) through the real ones.
 * Each packet is an mbuf chain cut at random points, often inside or at
 * the ends of the IP and TCP headers, every piece in an external buffer
 * malloc()ed to its exact length (m_extadd()), so that KASAN catches a
 * read a byte past a piece or the packet, which an mbuf's or a cluster's
 * slack hides from it with real traffic. Some pieces are read-only.
 *
 * The packets enter dummynet as layer 2 output with no interface, into
 * a queue (flowset) as OPNsense's shaper rules send them, whose pipe's
 * scheduler is CAKE: the IP header follows a 14-byte Ethernet header,
 * and what the pipe releases is dropped rather than sent.
 *
 *   sysctl debug.cake_kfuzz.queue=9999	the queue to send to
 *   sysctl debug.cake_kfuzz.seed=1
 *   sysctl debug.cake_kfuzz.run=100000	send that many packets
 *   sysctl debug.cake_kfuzz.bufs		pieces not yet freed
 */
#include <sys/param.h>
#include <sys/systm.h>
#include <sys/kernel.h>
#include <sys/malloc.h>
#include <sys/mbuf.h>
#include <sys/module.h>
#include <sys/proc.h>
#include <sys/socket.h>
#include <sys/sx.h>
#include <sys/sysctl.h>
#include <sys/ucred.h>
#include <sys/jail.h>		/* TD_TO_VNET */
#include <net/if.h>
#include <net/ethernet.h>
#include <net/vnet.h>
#include <netinet/in.h>
#include <netinet/ip_var.h>	/* ip_dn_io_ptr */
#include <netinet/ip_fw.h>
#include <netinet/tcp.h>
#include <netpfil/ipfw/ip_fw_private.h>

static MALLOC_DEFINE(M_KFUZZ, "cake_kfuzz", "cake_kfuzz packet pieces");

#define	KF_PIECES	5

static uint64_t kf_rng = 1;
static u_long kf_bufs, kf_packets, kf_pieces, kf_rdonly;
static u_int kf_queue = 9999;
static struct sx kf_lock;

static uint32_t
fuzz_random(void)
{
	kf_rng ^= kf_rng << 13;
	kf_rng ^= kf_rng >> 7;
	kf_rng ^= kf_rng << 17;
	return (kf_rng >> 32);
}

#include "gen.h"

static void
kf_free(struct mbuf *m)
{
	free(m->m_ext.ext_arg1, M_KFUZZ);
	atomic_subtract_long(&kf_bufs, 1);
}

/*
 * Offsets after the IP header where a piece may end awkwardly: inside
 * and at the ends of the IPv4, IPv6, 6in4 and TCP headers and options
 */
static const int kf_awkward[] = {
	1, 2, 4, 6, 9, 12, 16, 19, 20, 21, 24, 32, 33, 39, 40, 41, 52, 53,
	59, 60, 61, 72, 73, 80, 100
};

static int
kf_cut(int len)
{
	int at;

	at = rnd(2) ? (int)rnd(len + 1) : ETHER_HDR_LEN +
	    kf_awkward[rnd(nitems(kf_awkward))] + (int)rnd(3) - 1;
	return (MIN(MAX(at, 0), len));
}

/* the packet in p as a chain of exactly sized external buffers */
static struct mbuf *
kf_chain(const uint8_t *p, int len)
{
	int cuts[KF_PIECES + 1], n, i, j, plen, pad, t;
	struct mbuf *m = NULL, *last = NULL, *mb;
	char *buf;

	n = 1 + rnd(KF_PIECES);
	cuts[0] = 0;
	for (i = 1; i < n; i++) {
		t = kf_cut(len);
		for (j = i; j > 1 && cuts[j - 1] > t; j--)
			cuts[j] = cuts[j - 1];
		cuts[j] = t;
	}
	cuts[n] = len;
	for (i = 0; i < n; i++) {
		mb = i == 0 ? m_gethdr(M_WAITOK, MT_DATA) :
		    m_get(M_WAITOK, MT_DATA);
		plen = cuts[i + 1] - cuts[i];
		if (plen > 0) {
			/* the IP header 4-byte aligned, or not */
			pad = i == 0 && rnd(2) ? 2 : 0;
			buf = malloc(pad + plen, M_KFUZZ, M_WAITOK);
			memcpy(buf + pad, p + cuts[i], plen);
			t = rnd(8) ? 0 : M_RDONLY;
			m_extadd(mb, buf + pad, plen, kf_free, buf, NULL, t,
			    EXT_MOD_TYPE);
			mb->m_len = plen;
			atomic_add_long(&kf_bufs, 1);
			kf_pieces++;
			if (t)
				kf_rdonly++;
		}
		if (last == NULL)
			m = mb;
		else
			last->m_next = mb;
		last = mb;
	}
	m->m_pkthdr.len = len;
	return (m);
}

static void
kf_send(void)
{
	struct epoch_tracker et;
	struct ip_fw_args fwa;
	uint8_t p[PKT_MAX];
	struct mbuf *m;
	int len, i;

	memset(p, 0, sizeof(p));
	for (i = 0; i < ETHER_HDR_LEN; i++)
		p[i] = rnd(256);
	len = build(p, ETHER_HDR_LEN);
	if (rnd(3) == 0)
		len = mutate(p, len, ETHER_HDR_LEN);
	m = kf_chain(p, len);

	memset(&fwa, 0, sizeof(fwa));
	fwa.flags = IPFW_ARGS_ETHER | IPFW_ARGS_OUT;
	fwa.rule.info = IPFW_IS_DUMMYNET | kf_queue;
	/* for a pipe with a mask: a few scheduler instances */
	fwa.f_id.addr_type = 4;
	fwa.f_id.src_ip = rnd(4);
	fwa.f_id.dst_ip = rnd(4);
	NET_EPOCH_ENTER(et);
	if (ip_dn_io_ptr != NULL)
		ip_dn_io_ptr(&m, &fwa);
	NET_EPOCH_EXIT(et);
	if (m != NULL)
		m_freem(m);
	kf_packets++;
}

static int
kf_run(SYSCTL_HANDLER_ARGS)
{
	int error, n = 0, i, conns = 0;

	error = sysctl_handle_int(oidp, &n, 0, req);
	if (error != 0 || req->newptr == NULL)
		return (error);
	if (ip_dn_io_ptr == NULL)
		return (ENXIO);
	sx_xlock(&kf_lock);
	CURVNET_SET(TD_TO_VNET(curthread));
	for (i = 0; i < n; i++) {
		if (conns-- <= 0) {
			new_conns();
			conns = 1000 + rnd(20000);
		}
		kf_send();
		/* now and then a tick for dummynet to release some */
		if (rnd(64) == 0)
			pause("kfuzz", 1);
	}
	CURVNET_RESTORE();
	sx_xunlock(&kf_lock);
	return (0);
}

static int
kf_seed(SYSCTL_HANDLER_ARGS)
{
	uint64_t seed = kf_rng;
	int error;

	error = sysctl_handle_64(oidp, &seed, 0, req);
	if (error != 0 || req->newptr == NULL)
		return (error);
	sx_xlock(&kf_lock);
	kf_rng = seed ? seed : 1;
	sx_xunlock(&kf_lock);
	return (0);
}

SYSCTL_NODE(_debug, OID_AUTO, cake_kfuzz, CTLFLAG_RW | CTLFLAG_MPSAFE, 0,
    "malformed packets through dummynet and CAKE");
SYSCTL_PROC(_debug_cake_kfuzz, OID_AUTO, run,
    CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_MPSAFE, NULL, 0, kf_run, "I",
    "send this many packets");
SYSCTL_PROC(_debug_cake_kfuzz, OID_AUTO, seed,
    CTLTYPE_U64 | CTLFLAG_RW | CTLFLAG_MPSAFE, NULL, 0, kf_seed, "QU",
    "random number generator state");
SYSCTL_UINT(_debug_cake_kfuzz, OID_AUTO, queue, CTLFLAG_RW, &kf_queue, 0,
    "queue the packets go to");
SYSCTL_ULONG(_debug_cake_kfuzz, OID_AUTO, bufs, CTLFLAG_RD, &kf_bufs, 0,
    "pieces not yet freed");
SYSCTL_ULONG(_debug_cake_kfuzz, OID_AUTO, packets, CTLFLAG_RD, &kf_packets,
    0, "packets sent");
SYSCTL_ULONG(_debug_cake_kfuzz, OID_AUTO, pieces, CTLFLAG_RD, &kf_pieces, 0,
    "pieces allocated");
SYSCTL_ULONG(_debug_cake_kfuzz, OID_AUTO, rdonly, CTLFLAG_RD, &kf_rdonly, 0,
    "read-only pieces");
SYSCTL_ULONG(_debug_cake_kfuzz, OID_AUTO, mutated, CTLFLAG_RD, &mutated, 0,
    "packets corrupted");

static int
kf_modevent(module_t mod, int type, void *data)
{
	switch (type) {
	case MOD_LOAD:
		sx_init(&kf_lock, "cake_kfuzz");
		return (0);
	case MOD_UNLOAD:
		/* kf_free() must stay while dummynet holds a piece */
		if (atomic_load_long(&kf_bufs) != 0)
			return (EBUSY);
		sx_destroy(&kf_lock);
		return (0);
	default:
		return (EOPNOTSUPP);
	}
}

static moduledata_t kf_mod = { "cake_kfuzz", kf_modevent, NULL };
DECLARE_MODULE(cake_kfuzz, kf_mod, SI_SUB_PROTO_END, SI_ORDER_ANY);
MODULE_VERSION(cake_kfuzz, 1);
