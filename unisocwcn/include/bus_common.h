#ifndef __BUS_COMMON_H__
#define __BUS_COMMON_H__

#include <wcn_bus.h>

/* Internal to uwe5622_bsp_sdio: not exported. */
int buf_list_is_full(int chn);
int buf_list_is_empty(int chn);
int module_ops_register(struct sprdwcn_bus_ops *ops);
void module_ops_unregister(void);
/* The built-in SDIO transport (sdio/sdio_v3.c). */
struct sprdwcn_bus_ops *wcn_sdio_bus_ops(void);

#endif
