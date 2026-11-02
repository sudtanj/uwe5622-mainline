/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Length-checked parsing of firmware messages.
 *
 * Everything here is pure: no hardware, no driver state, no allocation,
 * so it can be unit tested (KUnit) on any architecture.
 */
#ifndef __SPRDWL_PARSE_H__
#define __SPRDWL_PARSE_H__

#include <linux/types.h>

/* size of struct sprdwl_cmd_hdr (msg.h): the header of cmd/event messages */
#define SPRDWL_MSG_HDR_LEN	12

/*
 * Payload length from the 4-byte bus header (struct sdiohal_puh): bits
 * 7..22 of the little-endian word.
 */
u32 sprdwl_puh_len(const void *puh);

/*
 * Bytes of message available after the bus header of an RX buffer.
 * @buf_len is the size of the buffer (mbuf_t.len), @hif_offset the size of
 * the bus header (0 if there is none, then @buf_len is returned).
 */
size_t sprdwl_rx_avail(const void *tran_data, size_t buf_len,
		       size_t hif_offset);

/*
 * Check a command response or event header against the bytes received.
 * Return: plen (header included) when SPRDWL_MSG_HDR_LEN <= plen <= @avail,
 * -EBADMSG otherwise.
 */
int sprdwl_msg_check(const void *msg, size_t avail);

/* true if [@off, @off + @need) lies inside a buffer of @len bytes */
static inline bool sprdwl_len_ok(size_t len, size_t off, size_t need)
{
	return off <= len && need <= len - off;
}

/*
 * Iterator over {__le16 type; __le16 len; u8 value[len]} records
 * (struct sprdwl_tlv_data, cmdevt.h).
 */
struct sprdwl_tlv_iter {
	const u8 *pos;
	size_t left;
};

static inline void sprdwl_tlv_init(struct sprdwl_tlv_iter *it,
				   const void *buf, size_t len)
{
	it->pos = buf;
	it->left = len;
}

/*
 * Return 1 and fill @type, @len, @val for the next record, 0 at the clean
 * end of the buffer, -EBADMSG if a record header or value runs past it.
 */
int sprdwl_tlv_next(struct sprdwl_tlv_iter *it, u16 *type, u16 *len,
		    const u8 **val);

#endif
