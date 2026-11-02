// SPDX-License-Identifier: GPL-2.0
/*
 * Length-checked parsing of firmware messages; see parse.h.
 */

#include <linux/errno.h>
#include <linux/unaligned.h>

#include "parse.h"

u32 sprdwl_puh_len(const void *puh)
{
	return (get_unaligned_le32(puh) >> 7) & 0xffff;
}

size_t sprdwl_rx_avail(const void *tran_data, size_t buf_len,
		       size_t hif_offset)
{
	size_t len;

	if (!hif_offset)
		return buf_len;
	if (buf_len < hif_offset || hif_offset < 4)
		return 0;

	len = sprdwl_puh_len(tran_data);
	return len < buf_len - hif_offset ? len : buf_len - hif_offset;
}

int sprdwl_msg_check(const void *msg, size_t avail)
{
	u16 plen;

	if (avail < SPRDWL_MSG_HDR_LEN)
		return -EBADMSG;
	/* struct sprdwl_cmd_hdr: common, cmd_id, __le16 plen, ... */
	plen = get_unaligned_le16((const u8 *)msg + 2);
	if (plen < SPRDWL_MSG_HDR_LEN || plen > avail)
		return -EBADMSG;

	return plen;
}

int sprdwl_tlv_next(struct sprdwl_tlv_iter *it, u16 *type, u16 *len,
		    const u8 **val)
{
	u16 l;

	if (!it->left)
		return 0;
	if (it->left < 4)
		return -EBADMSG;
	l = get_unaligned_le16(it->pos + 2);
	if (l > it->left - 4)
		return -EBADMSG;

	*type = get_unaligned_le16(it->pos);
	*len = l;
	*val = it->pos + 4;
	it->pos += 4 + l;
	it->left -= 4 + l;

	return 1;
}
