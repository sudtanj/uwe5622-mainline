/*
 * Copyright (C) 2015 Spreadtrum Communications Inc.
 * This software is licensed under the terms of the GNU General Public
 * License version 2, as published by the Free Software Foundation, and
 * may be copied, distributed, and modified under those terms.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 */

#define pr_fmt(fmt) "WCN: " fmt

#include "bufring.h"
#include "mdbg_type.h"
#include "wcn_log.h"

#define MDBG_RING_LOCK_INIT(ring)		mutex_init(ring->plock)
#define MDBG_RING_LOCK_UNINIT(ring)		mutex_destroy(ring->plock)
#define MDBG_RING_LOCK(ring)			mutex_lock(ring->plock)
#define MDBG_RING_UNLOCK(ring)			mutex_unlock(ring->plock)
#define _MDBG_RING_REMAIN(rp, wp, size)	((u_long)(wp) >= (u_long)(rp) ?\
			((size) - (u_long)(wp) + (u_long)(rp)) :\
			((u_long)(rp) - (u_long)(wp)))

/* valid buf for write */
long int mdbg_ring_free_space(struct mdbg_ring_t *ring)
{
	return (long int)_MDBG_RING_REMAIN(ring->rp,
				ring->wp, ring->size);
}

static char *mdbg_ring_start(struct mdbg_ring_t *ring)
{
	return ring->pbuff;
}

static char *mdbg_ring_end(struct mdbg_ring_t *ring)
{
	return ring->end;
}

bool mdbg_ring_over_loop(struct mdbg_ring_t *ring, u_long len, int rw)
{
	if (rw == MDBG_RING_R) {
		if ((u_long)ring->rp + len > (u_long)mdbg_ring_end(ring)) {
			ring->p_order_flag = 0;
			return true;
		}
		return false;
	}

	if ((u_long)ring->wp + len > (u_long)mdbg_ring_end(ring)) {
		ring->p_order_flag = 1;
		return true;
	}

	return false;
}

struct mdbg_ring_t *mdbg_ring_alloc(long int size)
{
	struct mdbg_ring_t *ring = NULL;

	do {
		if (size < MDBG_RING_MIN_SIZE) {
			pr_err("size error:%ld\n", size);
			break;
		}
		ring = kmalloc(sizeof(struct mdbg_ring_t), GFP_KERNEL);
		if (ring == NULL) {
			pr_err("Ring malloc Failed.\n");
			break;
		}
		ring->pbuff = kmalloc(size, GFP_KERNEL);
		if (ring->pbuff == NULL) {
			pr_err("Ring buff malloc Failed.\n");
			break;
		}
		ring->plock = kmalloc(MDBG_RING_LOCK_SIZE, GFP_KERNEL);
		if (ring->plock == NULL) {
			pr_err("Ring lock malloc Failed.\n");
			break;
		}
		MDBG_RING_LOCK_INIT(ring);
		memset(ring->pbuff, 0, size);
		ring->size = size;
		ring->rp = ring->pbuff;
		ring->wp = ring->pbuff;
		ring->end = (char *)(((u_long)ring->pbuff) + (ring->size - 1));
		ring->p_order_flag = 0;

		return ring;
	} while (0);
	mdbg_ring_destroy(ring);

	return NULL;
}

void mdbg_ring_destroy(struct mdbg_ring_t *ring)
{
	if (unlikely(ZERO_OR_NULL_PTR(ring)))
		return;

	pr_debug("ring = %p\n", ring);
	pr_debug("ring->pbuff = %p\n", ring->pbuff);
	if (ring != NULL) {
		if (ring->pbuff != NULL) {
			pr_debug("to free ring->pbuff.\n");
			kfree(ring->pbuff);
			ring->pbuff = NULL;
		}
		if (ring->plock != NULL) {
			pr_debug("to free ring->plock.\n");
			MDBG_RING_LOCK_UNINIT(ring);
			kfree(ring->plock);
			ring->plock = NULL;
		}
		pr_debug("to free ring.\n");
		kfree(ring);
		ring = NULL;
	}
}

int mdbg_ring_read(struct mdbg_ring_t *ring, void *buf, int len)
{
	int len1, len2 = 0;
	int cont_len = 0;
	int read_len = 0;
	char *pstart = NULL;
	char *pend = NULL;
	static unsigned int total_len;

	if ((buf == NULL) || (ring == NULL) || (len == 0)) {
		pr_err("Ring Read Failed,Param Error!,buf=%p,ring=%p,len=%d\n",
		       buf, ring, len);
		return -MDBG_ERR_BAD_PARAM;
	}
	MDBG_RING_LOCK(ring);
	cont_len = mdbg_ring_readable_len(ring);
	read_len = cont_len >= len ? len : cont_len;
	pstart = mdbg_ring_start(ring);
	pend = mdbg_ring_end(ring);
	pr_debug("read_len=%d\n", read_len);
	pr_debug("buf=%p\n", buf);
	pr_debug("pstart=%p\n", pstart);
	pr_debug("pend=%p\n", pend);
	pr_debug("ring->wp = %p\n", ring->wp);
	pr_debug("ring->rp=%p\n", ring->rp);

	if ((read_len == 0) || (cont_len == 0)) {
		pr_debug("read_len = 0 OR Ring Empty.\n");
		MDBG_RING_UNLOCK(ring);
		return 0;	/*ring empty*/
	}

	if (mdbg_ring_over_loop(ring, read_len, MDBG_RING_R)) {
		pr_debug("Ring loopover.\n");
		len1 = pend - ring->rp + 1;
		len2 = read_len - len1;
		if ((uintptr_t)buf > TASK_SIZE) {
			memcpy(buf, ring->rp, len1);
			memcpy((buf + len1), pstart, len2);
		} else {
			if (copy_to_user((void __user *)buf,
				(void *)ring->rp, len1) |
				copy_to_user((void __user *)(buf + len1),
				(void *)pstart, len2)) {
				pr_err("copy to user error!\n");
				MDBG_RING_UNLOCK(ring);
				return -EFAULT;
			}
		}
		ring->rp = (char *)((u_long)pstart + len2);
	} else{
		/* RP < WP */
		if (ring->p_order_flag == 0) {
			if (((ring->rp + read_len) > ring->wp)
				&& (mdbg_dev->open_count != 0))
				pr_err("read overlay\n");
		}

		if ((uintptr_t)buf > TASK_SIZE)
			memcpy(buf, ring->rp, read_len);
		else
			if (copy_to_user((void __user *)buf,
						(void *)ring->rp, read_len)) {
				pr_err("copy to user error!\n");
				MDBG_RING_UNLOCK(ring);

				return -EFAULT;
			}
		ring->rp += read_len;
	}
	total_len += read_len;
	wcn_pr_daterate(4, 1, total_len,
			"%s totallen:%u curread:%d wp:%p rp:%p",
			__func__, total_len, read_len,
			ring->wp, ring->rp);
	pr_debug("<-----[read end] read len =%d.\n", read_len);
	MDBG_RING_UNLOCK(ring);

	return read_len;
}

/*
 * read:	Rp = Wp:	empty
 * write:	Wp+1=Rp:	full
 */
int mdbg_ring_write(struct mdbg_ring_t *ring, void *buf, unsigned int len)
{
	int len1, len2 = 0;
	char *pstart = NULL;
	char *pend = NULL;
	static unsigned int total_len;

	pr_debug("-->Ring Write len = %d\n", len);
	if ((ring == NULL) || (buf == NULL) || (len == 0)) {
		pr_err("Ring Write Failed,Param Error!,buf=%p,ring=%p,len=%d\n",
		       buf, ring, len);

		return -MDBG_ERR_BAD_PARAM;
	}
	pstart = mdbg_ring_start(ring);
	pend = mdbg_ring_end(ring);
	pr_debug("pstart = %p\n", pstart);
	pr_debug("pend = %p\n", pend);
	pr_debug("buf = %p\n", buf);
	pr_debug("len = %d\n", len);
	pr_debug("ring->wp = %p\n", ring->wp);
	pr_debug("ring->rp=%p\n", ring->rp);

	/*
	 * ring buf valid space < len,need to write (buf_space-1)
	 * and then write len-(buf_space-1)
	 */
	if (((mdbg_ring_free_space(ring) - 1) < len)
		&& (mdbg_dev->open_count != 0)) {
		pr_err("log buf is full, Discard the package=%d\n", len);
		wake_up_log_wait();
		return len;
	}

	/* ring buf valid space > len, you can write freely */
	if (mdbg_ring_over_loop(ring, len, MDBG_RING_W)) {
		pr_debug("Ring overloop.\n");
		len1 = pend - ring->wp + 1;
		len2 = (len - len1) % ring->size;
		if ((uintptr_t)buf > TASK_SIZE) {
			memcpy(ring->wp, buf, len1);
			memcpy(pstart, (buf + len1), len2);
		} else {
			if (copy_from_user((void *)ring->wp,
				(void __user *)buf, len1) |
				copy_from_user((void *)pstart,
					(void __user *)(buf + len1), len2)) {
				pr_err("%s copy from user error!\n",
						__func__);
				return -EFAULT;
			}
		}
		ring->wp = (char *)((u_long)pstart + len2);

	} else{
		/* RP > WP */
		if ((uintptr_t)buf > TASK_SIZE)
			memcpy(ring->wp, buf, len);
		else
			if (copy_from_user((void *)ring->wp,
						(void __user *)buf, len)) {
				pr_err("%s copy from user error!\n",
						__func__);
				return -EFAULT;
			}
		ring->wp += len;
	}
	total_len += len;
	wcn_pr_daterate(4, 1, total_len,
			"%s totallen:%u cur_read:%u wp:%p rp:%p",
			__func__, total_len, len, ring->wp, ring->rp);
	pr_debug("<------end len = %d\n", len);

	return len;
}

/* @timeout unit is ms */
int mdbg_ring_write_timeout(struct mdbg_ring_t *ring, void *buf,
			    unsigned int len, unsigned int timeout)
{
	unsigned  int cnt = timeout / 20;

	while (cnt > 0 && (mdbg_ring_free_space(ring) - 1) < len) {
		msleep(20);
		if (--cnt == 0)
			pr_err("ringbuf is full, tiemout:%u\n",
			       timeout);
	}

	return mdbg_ring_write(ring, buf, len);
}

char *mdbg_ring_write_ext(struct mdbg_ring_t *ring, long int len)
{
	char *wp = NULL;

	pr_debug("ring=%p,ring->wp=%p,len=%ld.\n", ring, ring->wp, len);

	if ((ring == NULL) || (len == 0)) {
		pr_err("Ring Write Ext Failed,Param Error!\n");
		return NULL;
	}

	if (mdbg_ring_over_loop(ring, len, MDBG_RING_R)
			|| mdbg_ring_will_full(ring, len)) {
		pr_debug("Ring Write Ext Failed,Ring State Error!,overloop=%d,full=%d.\n",
			 mdbg_ring_over_loop(ring, len, MDBG_RING_R),
			 mdbg_ring_will_full(ring, len));
		return NULL;
	}
	MDBG_RING_LOCK(ring);
	wp = ring->wp;
	ring->wp += len;
	pr_debug("return wp=%p,ring->wp=%p.\n", wp, ring->wp);
	MDBG_RING_UNLOCK(ring);

	return wp;
}

bool mdbg_ring_will_full(struct mdbg_ring_t *ring, int len)
{
	return (len > mdbg_ring_free_space(ring));
}

/* remain data for read */
long int mdbg_ring_readable_len(struct mdbg_ring_t *ring)
{
	return ring->size - mdbg_ring_free_space(ring);
}

void mdbg_ring_clear(struct mdbg_ring_t *ring)
{
	ring->rp = ring->wp;
}

void mdbg_ring_reset(struct mdbg_ring_t *ring)
{
	ring->wp = ring->pbuff;
	ring->rp = ring->wp;
}

void mdbg_ring_print(struct mdbg_ring_t *ring)
{
	pr_debug("ring buf status:ring->rp=%p,ring->wp=%p.\n",
				ring->rp, ring->wp);
}
