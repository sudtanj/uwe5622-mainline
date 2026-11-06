// SPDX-License-Identifier: GPL-2.0
/*
 * Simulated UWE5622 chip for the QEMU tests.
 *
 * Registers as the WCN core's transport (uwe5622_bsp_sdio transport=external,
 * "Transport interface" in docs/ARCHITECTURE.md) and plays the firmware:
 *
 *  - boot: chip id, CP reset, calibration sync and "all finished" words, AT
 *    commands (loopcheck, cp2 info, log switch) answered on the AT channels
 *  - Wi-Fi: every command on channel 8 is answered on channel 22 with the
 *    same cmd_id, mstime and status 0; GET_INFO and GET_STATION carry a
 *    payload; SCAN yields beacon frames of a few synthetic access points,
 *    CONNECT a connect event, DISCONNECT a disconnect event
 *  - data: frames sent on channel 10 are counted and handed back; there is
 *    no RX data path (see docs/TESTING.md, limitations)
 *
 * Nothing here touches hardware. Faults are injected with the "inject"
 * module parameter (sim_inject_set()).
 */
#define pr_fmt(fmt) "uwe5622_sim: " fmt

#include <linux/module.h>
#include <linux/slab.h>
#include <linux/workqueue.h>
#include <linux/delay.h>
#include <linux/random.h>
#include <linux/etherdevice.h>
#include <linux/ieee80211.h>
#include <linux/atomic.h>
#include <linux/skbuff.h>
#include <linux/unaligned.h>
#include <wcn_bus.h>

#include <net/cfg80211.h>
#include "cfg80211.h"
#include "msg.h"
#include "cmdevt.h"

/* chip registers the boot sequence touches (docs/ARCHITECTURE.md) */
#define SIM_CHIPID_REG		0x4083c208
#define SIM_CHIPID		0x2355B001
#define SIM_SYNC_ADDR		0x405E73B0
#define SIM_SYNC_CALI_WAITING	0xF0F0F0F1
#define SIM_SYNC_ALL_FINISHED	0xF0F0F0FF

/* channels (Allwinner SDIO build) */
#define CHN_AT_TX		0
#define CHN_WIFI_CMD_TX		8
#define CHN_WIFI_DATA_TX	10
#define CHN_LOOPCHECK_RX	12
#define CHN_AT_RX		13
#define CHN_WIFI_CMD_RX		22

static int rx_delay_ms;
module_param(rx_delay_ms, int, 0644);
MODULE_PARM_DESC(rx_delay_ms, "delay before answering each Wi-Fi command (ms)");

struct sim_ap {
	const char *ssid;
	u8 bssid[ETH_ALEN];
	u8 channel;
	s8 signal;
};

static const struct sim_ap sim_aps[] = {
	{ "uwe-sim-open", { 0x02, 0x55, 0x57, 0x45, 0x00, 0x01 }, 1, -40 },
	{ "uwe-sim-two", { 0x02, 0x55, 0x57, 0x45, 0x00, 0x02 }, 6, -55 },
	{ "uwe-sim-three", { 0x02, 0x55, 0x57, 0x45, 0x00, 0x03 }, 11, -70 },
};

struct sim_tx_job {
	struct list_head node;
	int chn;
	struct mbuf_t *head, *tail;
	int num;
};

static struct {
	int (*rescan_cb)(void);
	struct workqueue_struct *wq;
	struct work_struct rescan_work;
	struct work_struct tx_work;
	spinlock_t lock;
	struct list_head jobs;
	u32 regs[4];
	bool silent;
	bool stopping;
	atomic_t fail_next_push;
	atomic_t drop_cmd_id;
	atomic_t cmds, events, tx_frames, tx_bytes, dropped, scans, connects;
} sim = { .lock = __SPIN_LOCK_UNLOCKED(sim.lock) };

/* ---- RX delivery ------------------------------------------------------ */

/*
 * The Wi-Fi core refills its RX mbufs with netdev_alloc_frag() and frees what
 * it takes with put_page() (sprdwl_free_data(), SPRDWL_DEFRAG_MEM): a slab
 * buffer there corrupts the page refcount. The other RX channels hand the
 * buffer back with push_list(), like the SDIO transport's own pool buffers.
 */
static void *sim_rx_buf_alloc(int chn, unsigned int size)
{
	void *buf;

	if (chn != CHN_WIFI_CMD_RX)
		return kzalloc(size, GFP_KERNEL);
	buf = netdev_alloc_frag(size);
	if (buf)
		memset(buf, 0, size);
	return buf;
}

static void sim_rx_buf_free(int chn, void *buf)
{
	if (!buf)
		return;
	if (chn == CHN_WIFI_CMD_RX)
		skb_free_frag(buf);
	else
		kfree(buf);
}

static void sim_rx_push(int chn, const void *payload, unsigned int len,
			unsigned int declared_len)
{
	struct mchn_ops_t *ops = chn_ops(chn);
	struct mbuf_t *mbuf;
	u8 *buf;
	u32 puh;

	if (!ops || !ops->pop_link) {
		atomic_inc(&sim.dropped);
		return;
	}
	mbuf = kzalloc(sizeof(*mbuf), GFP_KERNEL);
	buf = sim_rx_buf_alloc(chn, 4 + len + 4);
	if (!mbuf || !buf) {
		kfree(mbuf);
		sim_rx_buf_free(chn, buf);
		return;
	}
	/* public header: len 7..22, eof 23, subtype 24..27, type 28..31 */
	puh = (declared_len << 7) | BIT(23) | ((chn - 12) << 24) | (3U << 28);
	put_unaligned_le32(puh, buf);
	memcpy(buf + 4, payload, len);
	mbuf->buf = buf;
	mbuf->len = 4 + len;
	/* the owner returns the mbuf with push_list(); see sim_push_list() */
	ops->pop_link(chn, mbuf, mbuf, 1);
}

static void sim_at_reply(int chn, const char *s)
{
	sim_rx_push(chn, s, strlen(s) + 1, strlen(s) + 1);
}

/* ---- Wi-Fi: responses and events --------------------------------------- */

static void sim_send_rsp(const struct sprdwl_cmd_hdr *req, const void *payload,
			 unsigned int plen)
{
	struct sprdwl_cmd_hdr *rsp;
	unsigned int total = sizeof(*rsp) + plen;

	rsp = kzalloc(total, GFP_KERNEL);
	if (!rsp)
		return;
	memcpy(rsp, req, sizeof(*rsp));
	rsp->common.type = SPRDWL_TYPE_CMD;
	rsp->plen = cpu_to_le16(total);
	rsp->status = 0;
	if (plen)
		memcpy(rsp->paydata, payload, plen);
	if (rx_delay_ms)
		msleep(rx_delay_ms);
	sim_rx_push(CHN_WIFI_CMD_RX, rsp, total, total);
	kfree(rsp);
}

static void sim_send_event(u8 ctx_id, u8 event_id, const void *payload,
			   unsigned int plen)
{
	struct sprdwl_cmd_hdr *ev;
	unsigned int total = sizeof(*ev) + plen;

	ev = kzalloc(total, GFP_KERNEL);
	if (!ev)
		return;
	ev->common.type = SPRDWL_TYPE_EVENT;
	ev->common.ctx_id = ctx_id;
	ev->cmd_id = event_id;
	ev->plen = cpu_to_le16(total);
	if (plen)
		memcpy(ev->paydata, payload, plen);
	atomic_inc(&sim.events);
	sim_rx_push(CHN_WIFI_CMD_RX, ev, total, total);
	kfree(ev);
}

/* beacon frame of @ap; returns its length */
static unsigned int sim_beacon(const struct sim_ap *ap, u8 *out)
{
	struct ieee80211_mgmt *m = (void *)out;
	static const u8 rates[] = { 0x82, 0x84, 0x8b, 0x96, 0x0c, 0x12, 0x18, 0x24 };
	u8 *p;
	size_t ssid_len = strlen(ap->ssid);

	memset(m, 0, sizeof(m->u.beacon) + 24);
	m->frame_control = cpu_to_le16(IEEE80211_FTYPE_MGMT | IEEE80211_STYPE_BEACON);
	eth_broadcast_addr(m->da);
	ether_addr_copy(m->sa, ap->bssid);
	ether_addr_copy(m->bssid, ap->bssid);
	m->u.beacon.beacon_int = cpu_to_le16(100);
	m->u.beacon.capab_info = cpu_to_le16(WLAN_CAPABILITY_ESS);
	p = m->u.beacon.variable;
	*p++ = WLAN_EID_SSID;
	*p++ = ssid_len;
	memcpy(p, ap->ssid, ssid_len);
	p += ssid_len;
	*p++ = WLAN_EID_SUPP_RATES;
	*p++ = sizeof(rates);
	memcpy(p, rates, sizeof(rates));
	p += sizeof(rates);
	*p++ = WLAN_EID_DS_PARAMS;
	*p++ = 1;
	*p++ = ap->channel;
	return p - out;
}

static void sim_do_scan(u8 ctx_id)
{
	u8 buf[sizeof(struct sprdwl_event_mgmt_frame) + 256];
	struct sprdwl_event_mgmt_frame *f = (void *)buf;
	struct sprdwl_event_scan_done done = { .type = SPRDWL_SCAN_DONE };
	int i;

	atomic_inc(&sim.scans);
	for (i = 0; i < ARRAY_SIZE(sim_aps); i++) {
		unsigned int len;

		memset(buf, 0, sizeof(*f));
		f->type = SPRDWL_FRAME_SCAN;
		f->channel = sim_aps[i].channel;
		f->signal = sim_aps[i].signal;
		len = sim_beacon(&sim_aps[i], f->data);
		f->len = cpu_to_le16(len);
		sim_send_event(ctx_id, WIFI_EVENT_MGMT_FRAME, f, sizeof(*f) + len);
	}
	sim_send_event(ctx_id, WIFI_EVENT_SCAN_DONE, &done, sizeof(done));
}

static void sim_do_connect(u8 ctx_id, const struct sprdwl_cmd_connect *c,
			   unsigned int avail)
{
	u8 buf[1 + ETH_ALEN + 1 + 1 + 3 * 2];
	u8 *p = buf;
	const struct sim_ap *ap = &sim_aps[0];
	int i;

	if (avail < sizeof(*c))
		return;
	for (i = 0; i < ARRAY_SIZE(sim_aps); i++)
		if (ether_addr_equal(sim_aps[i].bssid, c->bssid))
			ap = &sim_aps[i];
	atomic_inc(&sim.connects);
	*p++ = SPRDWL_CONNECT_SUCCESS;
	ether_addr_copy(p, ap->bssid);
	p += ETH_ALEN;
	*p++ = ap->channel;
	*p++ = ap->signal;
	put_unaligned_le16(0, p);	/* req_ie_len */
	p += 2;
	put_unaligned_le16(0, p);	/* resp_ie_len */
	p += 2;
	put_unaligned_le16(0, p);	/* bea_ie_len */
	p += 2;
	sim_send_event(ctx_id, WIFI_EVENT_CONNECT, buf, p - buf);
}

static void sim_do_disconnect(u8 ctx_id)
{
	__le16 reason = cpu_to_le16(WLAN_REASON_DEAUTH_LEAVING);

	sim_send_event(ctx_id, WIFI_EVENT_DISCONNECT, &reason, sizeof(reason));
}

static void sim_handle_cmd(const struct sprdwl_cmd_hdr *c, unsigned int avail)
{
	atomic_inc(&sim.cmds);
	if (sim.silent || atomic_read(&sim.drop_cmd_id) == c->cmd_id) {
		atomic_inc(&sim.dropped);
		return;
	}
	switch (c->cmd_id) {
	case WIFI_CMD_GET_INFO: {
		struct sprdwl_cmd_fw_info *fi = kzalloc(sizeof(*fi), GFP_KERNEL);

		if (!fi)
			return;
		fi->chip_model = cpu_to_le32(0x2355);
		fi->chip_version = cpu_to_le32(1);
		fi->fw_version = cpu_to_le32(0x1000);
		fi->max_ap_assoc_sta = 8;
		fi->max_mc_mac_addrs = 16;
		fi->wiphy_sec2.ht_cap_info = 0x01ee;
		fi->wiphy_sec2.ht_mcs_set.rx_mask[0] = 0xff;
		fi->wiphy_sec2.antenna_tx = 1;
		fi->wiphy_sec2.antenna_rx = 1;
		fi->wiphy_sec2.retry_short = 7;
		fi->wiphy_sec2.retry_long = 4;
		fi->wiphy_sec2.frag_threshold = 2346;
		fi->wiphy_sec2.rts_threshold = 2347;
		memcpy(fi->mac_addr, (u8[]){ 0x02, 0x55, 0x57, 0x45, 0xaa, 0x01 }, ETH_ALEN);
		fi->credit_capa = TX_NO_CREDIT;
		sim_send_rsp(c, fi, sizeof(*fi));
		kfree(fi);
		break;
	}
	case WIFI_CMD_SYNC_VERSION:
		/* the firmware speaks exactly the API versions the driver offers */
		sim_send_rsp(c, c->paydata,
			     min_t(unsigned int, avail - sizeof(*c),
				   sizeof(struct sprdwl_cmd_api_t)));
		break;
	case WIFI_CMD_SCAN:
		sim_send_rsp(c, NULL, 0);
		sim_do_scan(c->common.ctx_id);
		break;
	case WIFI_CMD_CONNECT:
		sim_send_rsp(c, NULL, 0);
		sim_do_connect(c->common.ctx_id, (const void *)c->paydata,
			       avail - sizeof(*c));
		break;
	case WIFI_CMD_DISCONNECT:
		sim_send_rsp(c, NULL, 0);
		sim_do_disconnect(c->common.ctx_id);
		break;
	case WIFI_CMD_GET_STATION: {
		struct sprdwl_cmd_get_station st = { .signal = -45, .noise = 90 };

		st.rate.legacy = 540;	/* 54 Mbit/s in 100 kbit/s */
		sim_send_rsp(c, &st, sizeof(st));
		break;
	}
	default:
		sim_send_rsp(c, NULL, 0);
		break;
	}
}

/* ---- TX jobs ------------------------------------------------------------ */

static void sim_process_one(int chn, struct mbuf_t *m)
{
	u8 *payload = m->buf ? m->buf + 4 : NULL;
	unsigned int len = m->len;

	if (!payload)
		return;
	switch (chn) {
	case CHN_AT_TX:
		if (strnstr((const char *)payload, "loopcheck", len))
			sim_at_reply(CHN_LOOPCHECK_RX, "\r\nOK\r\n");
		else
			sim_at_reply(CHN_AT_RX, "\r\nOK\r\n");
		break;
	case CHN_WIFI_CMD_TX:
		if (len >= sizeof(struct sprdwl_cmd_hdr))
			sim_handle_cmd((const void *)payload, len);
		break;
	case CHN_WIFI_DATA_TX:
		atomic_inc(&sim.tx_frames);
		atomic_add(len, &sim.tx_bytes);
		break;
	default:
		break;
	}
}

static void sim_tx_work(struct work_struct *w)
{
	struct sim_tx_job *job;

	for (;;) {
		struct mbuf_t *m;
		struct mchn_ops_t *ops;
		int i;

		spin_lock_bh(&sim.lock);
		job = list_first_entry_or_null(&sim.jobs, struct sim_tx_job, node);
		if (job)
			list_del(&job->node);
		spin_unlock_bh(&sim.lock);
		if (!job)
			return;
		for (i = 0, m = job->head; i < job->num && m; i++, m = m->next)
			sim_process_one(job->chn, m);
		ops = chn_ops(job->chn);
		if (ops && ops->pop_link)
			ops->pop_link(job->chn, job->head, job->tail, job->num);
		kfree(job);
	}
}

static int sim_push_list(int chn, struct mbuf_t *head, struct mbuf_t *tail, int num)
{
	struct sim_tx_job *job;

	if (atomic_dec_if_positive(&sim.fail_next_push) >= 0)
		return -EIO;
	if (chn >= 12) {
		/*
		 * the owner gives an RX list back: the mbufs are ours; a buf
		 * still set was not taken (the Wi-Fi core clears it when it does)
		 */
		struct mbuf_t *m = head, *next;
		int i;

		for (i = 0; i < num && m; i++, m = next) {
			next = m->next;
			sim_rx_buf_free(chn, m->buf);
			kfree(m);
		}
		return 0;
	}
	job = kzalloc(sizeof(*job), GFP_ATOMIC);
	if (!job)
		return -ENOMEM;
	job->chn = chn;
	job->head = head;
	job->tail = tail;
	job->num = num;
	spin_lock_bh(&sim.lock);
	list_add_tail(&job->node, &sim.jobs);
	spin_unlock_bh(&sim.lock);
	queue_work(sim.wq, &sim.tx_work);
	return 0;
}

/*
 * push_list_direct(): the caller queues the pop itself (sprdwl_add_topop_list),
 * so the transport sends, returns 0 and never calls pop_link().
 */
static int sim_push_list_direct(int chn, struct mbuf_t *head, struct mbuf_t *tail, int num)
{
	struct mbuf_t *m;
	int i;

	if (atomic_dec_if_positive(&sim.fail_next_push) >= 0)
		return -EIO;
	for (i = 0, m = head; i < num && m; i++, m = m->next)
		sim_process_one(chn, m);
	return 0;
}

/* ---- transport ops --------------------------------------------------------- */

static int sim_read_l(unsigned int addr, void *buf)
{
	u32 v = 0;

	switch (addr) {
	case SIM_CHIPID_REG:
		v = SIM_CHIPID;
		break;
	case SIM_SYNC_ADDR:
		v = sim.regs[1] ? sim.regs[1] : SIM_SYNC_CALI_WAITING;
		break;
	case 0x40088288:
		v = sim.regs[0];
		break;
	case 0x408a0000:
		v = sim.regs[2];
		break;
	}
	put_unaligned_le32(v, buf);
	return 0;
}

static int sim_write_l(unsigned int addr, void *buf)
{
	u32 v = get_unaligned_le32(buf);

	switch (addr) {
	case SIM_SYNC_ADDR:
		sim.regs[1] = v;
		break;
	case 0x40088288:
		sim.regs[0] = v;
		break;
	case 0x408a0000:
		sim.regs[2] = v & ~BIT(15);
		break;
	}
	return 0;
}

static int sim_direct_read(unsigned int addr, void *buf, unsigned int len)
{
	memset(buf, 0, len);
	if (addr == SIM_SYNC_ADDR && len >= 4)
		put_unaligned_le32(SIM_SYNC_ALL_FINISHED, buf);
	return 0;
}

static int sim_direct_write(unsigned int addr, void *buf, unsigned int len)
{
	return 0;
}

static int sim_readbyte(unsigned int addr, unsigned char *val)
{
	*val = 0;
	return 0;
}

static int sim_writebyte(unsigned int addr, unsigned char val)
{
	return 0;
}

static void sim_rescan_work(struct work_struct *w)
{
	if (sim.rescan_cb)
		sim.rescan_cb();
}

static int sim_rescan(void)
{
	queue_work(sim.wq, &sim.rescan_work);
	return 0;
}

static void sim_register_rescan_cb(void *fn)
{
	sim.rescan_cb = fn;
}

static int sim_chn_init(struct mchn_ops_t *ops)
{
	return bus_chn_init(ops, HW_TYPE_SDIO);
}

static int sim_chn_deinit(struct mchn_ops_t *ops)
{
	return bus_chn_deinit(ops);
}

static int sim_hif_type(void)
{
	return HW_TYPE_SDIO;
}

static unsigned int sim_blk_size(void)
{
	return 512;
}

static struct sprdwcn_bus_ops sim_ops = {
	.chn_init = sim_chn_init,
	.chn_deinit = sim_chn_deinit,
	.list_alloc = buf_list_alloc,
	.list_free = buf_list_free,
	.push_list = sim_push_list,
	.push_list_direct = sim_push_list_direct,
	.get_blk_size = sim_blk_size,
	.direct_read = sim_direct_read,
	.direct_write = sim_direct_write,
	.readbyte = sim_readbyte,
	.writebyte = sim_writebyte,
	.read_l = sim_read_l,
	.write_l = sim_write_l,
	.rescan = sim_rescan,
	.register_rescan_cb = sim_register_rescan_cb,
	.get_hif_type = sim_hif_type,
};

/* ---- fault injection and statistics ---------------------------------------- */

/*
 * inject=<fault>, written at any time:
 *   silent        stop answering Wi-Fi commands (driver times out)
 *   talk          answer again
 *   drop=<id>     never answer command <id>; drop=-1 clears
 *   fail_push     the next push_list() returns -EIO
 *   short         RX message on the command channel shorter than a header
 *   badlen        RX command message whose header claims more than was sent
 *   garbage       RX message of random bytes on the command channel
 *   unknown_event event with an id nobody handles
 *   truncated_connect / truncated_scan   events cut short
 *   scan_flood    200 scan results back to back
 *   bad_ctx       response for a context id that does not exist
 */
static int sim_inject_set(const char *val, const struct kernel_param *kp)
{
	char s[32];
	u8 junk[64];
	long id;

	strscpy(s, val, sizeof(s));
	strim(s);
	if (!strcmp(s, "silent")) {
		sim.silent = true;
	} else if (!strcmp(s, "talk")) {
		sim.silent = false;
	} else if (!strncmp(s, "drop=", 5)) {
		if (kstrtol(s + 5, 0, &id))
			return -EINVAL;
		atomic_set(&sim.drop_cmd_id, id);
	} else if (!strcmp(s, "fail_push")) {
		atomic_set(&sim.fail_next_push, 1);
	} else if (!strcmp(s, "short")) {
		sim_rx_push(CHN_WIFI_CMD_RX, "\x01\x02\x03", 3, 3);
	} else if (!strcmp(s, "badlen")) {
		struct sprdwl_cmd_hdr h = { .cmd_id = WIFI_CMD_GET_INFO };

		h.common.type = SPRDWL_TYPE_CMD;
		h.plen = cpu_to_le16(4000);
		sim_rx_push(CHN_WIFI_CMD_RX, &h, sizeof(h), sizeof(h));
	} else if (!strcmp(s, "garbage")) {
		get_random_bytes(junk, sizeof(junk));
		sim_rx_push(CHN_WIFI_CMD_RX, junk, sizeof(junk), sizeof(junk));
	} else if (!strcmp(s, "unknown_event")) {
		sim_send_event(0, 0xee, "xyz", 3);
	} else if (!strcmp(s, "truncated_connect")) {
		u8 b[3] = { SPRDWL_CONNECT_SUCCESS, 1, 2 };

		sim_send_event(0, WIFI_EVENT_CONNECT, b, sizeof(b));
	} else if (!strcmp(s, "truncated_scan")) {
		struct sprdwl_event_mgmt_frame f = { .type = SPRDWL_FRAME_SCAN,
						     .channel = 1 };

		f.len = cpu_to_le16(500);
		sim_send_event(0, WIFI_EVENT_MGMT_FRAME, &f, sizeof(f));
	} else if (!strcmp(s, "scan_flood")) {
		int i;

		for (i = 0; i < 200; i++)
			sim_do_scan(0);
	} else if (!strcmp(s, "bad_ctx")) {
		struct sprdwl_cmd_hdr h = { .cmd_id = WIFI_CMD_GET_INFO };

		h.common.type = SPRDWL_TYPE_CMD;
		h.common.ctx_id = 7;
		h.plen = cpu_to_le16(sizeof(h));
		sim_rx_push(CHN_WIFI_CMD_RX, &h, sizeof(h), sizeof(h));
	} else {
		return -EINVAL;
	}
	return 0;
}

static const struct kernel_param_ops sim_inject_ops = {
	.set = sim_inject_set,
};
module_param_cb(inject, &sim_inject_ops, NULL, 0200);
MODULE_PARM_DESC(inject, "inject a fault, see the comment in uwe5622_sim.c");

static ssize_t stats_show(struct kobject *k, struct kobj_attribute *a, char *buf)
{
	return sysfs_emit(buf, "cmds %d events %d scans %d connects %d tx_frames %d tx_bytes %d dropped %d\n",
			  atomic_read(&sim.cmds), atomic_read(&sim.events),
			  atomic_read(&sim.scans), atomic_read(&sim.connects),
			  atomic_read(&sim.tx_frames), atomic_read(&sim.tx_bytes),
			  atomic_read(&sim.dropped));
}

static struct kobj_attribute stats_attr = __ATTR_RO(stats);

static int __init sim_init(void)
{
	int ret;

	INIT_LIST_HEAD(&sim.jobs);
	INIT_WORK(&sim.rescan_work, sim_rescan_work);
	INIT_WORK(&sim.tx_work, sim_tx_work);
	atomic_set(&sim.drop_cmd_id, -1);
	sim.wq = alloc_ordered_workqueue("uwe5622_sim", 0);
	if (!sim.wq)
		return -ENOMEM;
	ret = wcn_bus_register_transport(&sim_ops);
	if (ret) {
		pr_err("wcn_bus_register_transport: %d (load uwe5622_bsp_sdio transport=external first)\n", ret);
		destroy_workqueue(sim.wq);
		return ret;
	}
	ret = sysfs_create_file(&THIS_MODULE->mkobj.kobj, &stats_attr.attr);
	if (ret)
		pr_warn("stats attribute: %d\n", ret);
	pr_info("simulated UWE5622 registered as transport\n");
	return 0;
}

static void __exit sim_exit(void)
{
	sysfs_remove_file(&THIS_MODULE->mkobj.kobj, &stats_attr.attr);
	wcn_bus_unregister_transport(&sim_ops);
	flush_workqueue(sim.wq);
	destroy_workqueue(sim.wq);
}

module_init(sim_init);
module_exit(sim_exit);

MODULE_DESCRIPTION("Simulated UWE5622 chip for the uwe5622-mainline tests");
MODULE_LICENSE("GPL");
