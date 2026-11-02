// SPDX-License-Identifier: GPL-2.0
/*
 * KUnit: the byte ring the WCN core uses for chip logs
 * (unisocwcn/platform/bufring.c). Empty is rp == wp, full is wp + 1 == rp.
 * Writers drop a packet that does not fit while a reader has the log
 * device open (mdbg_dev->open_count != 0), and overwrite otherwise.
 */
#include "../../unisocwcn/platform/bufring.c"
#include <kunit/test.h>

#define RING 4096

static void fill(u8 *p, int len, u8 seed)
{
	int i;

	for (i = 0; i < len; i++)
		p[i] = seed + i * 7;
}

static struct mdbg_ring_t *ring_new(struct kunit *test)
{
	struct mdbg_ring_t *r = mdbg_ring_alloc(RING);

	KUNIT_ASSERT_NOT_NULL(test, r);
	mdbg_dev->open_count = 1;
	return r;
}

static void bufring_alloc_limits(struct kunit *test)
{
	struct mdbg_ring_t *r;

	KUNIT_EXPECT_NULL(test, mdbg_ring_alloc(RING - 1));
	r = ring_new(test);
	KUNIT_EXPECT_EQ(test, mdbg_ring_readable_len(r), 0);
	KUNIT_EXPECT_EQ(test, mdbg_ring_free_space(r), RING);
	mdbg_ring_destroy(r);
}

static void bufring_write_read(struct kunit *test)
{
	struct mdbg_ring_t *r = ring_new(test);
	u8 *in = kunit_kmalloc(test, 300, GFP_KERNEL);
	u8 *out = kunit_kzalloc(test, 300, GFP_KERNEL);

	fill(in, 300, 1);
	KUNIT_EXPECT_EQ(test, mdbg_ring_write(r, in, 300), 300);
	KUNIT_EXPECT_EQ(test, mdbg_ring_readable_len(r), 300);
	KUNIT_EXPECT_EQ(test, mdbg_ring_read(r, out, 100), 100);
	KUNIT_EXPECT_EQ(test, mdbg_ring_read(r, out + 100, 1000), 200);
	KUNIT_EXPECT_MEMEQ(test, in, out, 300);
	KUNIT_EXPECT_EQ(test, mdbg_ring_read(r, out, 10), 0);
	mdbg_ring_destroy(r);
}

static void bufring_wraparound(struct kunit *test)
{
	struct mdbg_ring_t *r = ring_new(test);
	u8 *in = kunit_kmalloc(test, RING, GFP_KERNEL);
	u8 *out = kunit_kzalloc(test, RING, GFP_KERNEL);

	fill(in, RING, 3);
	KUNIT_ASSERT_EQ(test, mdbg_ring_write(r, in, 4000), 4000);
	KUNIT_ASSERT_EQ(test, mdbg_ring_read(r, out, 4000), 4000);
	/* 300 bytes: 96 at the end of the buffer, 204 at the start */
	fill(in, 300, 9);
	KUNIT_EXPECT_EQ(test, mdbg_ring_write(r, in, 300), 300);
	KUNIT_EXPECT_EQ(test, mdbg_ring_readable_len(r), 300);
	KUNIT_EXPECT_EQ(test, mdbg_ring_read(r, out, 300), 300);
	KUNIT_EXPECT_MEMEQ(test, in, out, 300);
	KUNIT_EXPECT_EQ(test, mdbg_ring_readable_len(r), 0);
	mdbg_ring_destroy(r);
}

static void bufring_full_drops_with_reader(struct kunit *test)
{
	struct mdbg_ring_t *r = ring_new(test);
	u8 *in = kunit_kzalloc(test, RING, GFP_KERNEL);

	KUNIT_ASSERT_EQ(test, mdbg_ring_write(r, in, RING - 1), RING - 1);
	KUNIT_EXPECT_EQ(test, mdbg_ring_readable_len(r), RING - 1);
	/* full: the packet is dropped, existing data stays intact */
	mdbg_ring_write(r, in, 10);
	KUNIT_EXPECT_EQ(test, mdbg_ring_readable_len(r), RING - 1);
	mdbg_ring_destroy(r);
}

static void bufring_write_ext_in_bounds(struct kunit *test)
{
	struct mdbg_ring_t *r = ring_new(test);
	u8 *in = kunit_kzalloc(test, RING, GFP_KERNEL);
	u8 *out = kunit_kzalloc(test, RING, GFP_KERNEL);
	char *p;

	/* wp near the end, rp near the start, enough free space in total */
	KUNIT_ASSERT_EQ(test, mdbg_ring_write(r, in, 4000), 4000);
	KUNIT_ASSERT_EQ(test, mdbg_ring_read(r, out, 100), 100);
	p = mdbg_ring_write_ext(r, 150);
	/*
	 * write_ext() hands out a contiguous region for the caller to fill:
	 * either NULL or 150 bytes that lie inside the buffer.
	 */
	if (p) {
		KUNIT_EXPECT_GE(test, (unsigned long)p, (unsigned long)r->pbuff);
		KUNIT_EXPECT_LE(test, (unsigned long)(p + 150), (unsigned long)(r->pbuff + RING));
	}
	mdbg_ring_reset(r);
	mdbg_ring_destroy(r);
}

static struct kunit_case bufring_cases[] = {
	KUNIT_CASE(bufring_alloc_limits),
	KUNIT_CASE(bufring_write_read),
	KUNIT_CASE(bufring_wraparound),
	KUNIT_CASE(bufring_full_drops_with_reader),
	KUNIT_CASE(bufring_write_ext_in_bounds),
	{}
};

static struct kunit_suite bufring_suite = {
	.name = "uwe5622_bufring",
	.test_cases = bufring_cases,
};
kunit_test_suite(bufring_suite);
