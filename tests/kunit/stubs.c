// SPDX-License-Identifier: GPL-2.0
/*
 * Definitions the included driver sources expect from the rest of their
 * module: the Wi-Fi log level and the WCN log device that bufring.c
 * consults. The test module has its own copies; the real ones in
 * sprdwl_ng / uwe5622_bsp_sdio are not exported, so nothing clashes.
 */
#include <linux/module.h>
#include <linux/wait.h>
#include "wcn_log.h"

int sprdwl_debug_level = 1; /* L_ERR */

static struct mdbg_device_t kunit_mdbg_dev;
struct mdbg_device_t *mdbg_dev = &kunit_mdbg_dev;

int wake_up_log_wait(void)
{
	return 0;
}

MODULE_DESCRIPTION("KUnit tests for the UWE5622 driver's pure helpers");
MODULE_LICENSE("GPL");
