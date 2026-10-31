# WCN core ("BSP") module for the UWE5622 on an SDIO bus. Only the Allwinner
# variant is kept; it is selected with CONFIG_AW_WIFI_DEVICE_UWE5622=y by the
# top-level Makefile, dkms.conf and scripts/build-against-kernel.sh.

ifeq ($(CONFIG_AW_WIFI_DEVICE_UWE5622),y)
export CONFIG_WCN_SDIO = y
ccflags-y += -DCONFIG_UWE5622
BSP_CHIP_ID := uwe5622
WCN_HW_TYPE := sdio
endif

MODULE_NAME := $(BSP_CHIP_ID)_bsp_$(WCN_HW_TYPE)

ifneq ($(UNISOC_FW_PATH_CONFIG),)
ccflags-y += -DCONFIG_CUSTOMIZE_UNISOC_FW_PATH=\"$(UNISOC_FW_PATH_CONFIG)\"
endif
ifneq ($(UNISOC_DBG_FILESIZE_CONFIG),)
ccflags-y += -DCONFIG_CUSTOMIZE_UNISOC_DBG_FILESIZE=$(UNISOC_DBG_FILESIZE_CONFIG)
endif
ifneq ($(UNISOC_DBG_FILENUM_CONFIG),)
ccflags-y += -DCONFIG_CUSTOMIZE_UNISOC_DBG_FILENUM=$(UNISOC_DBG_FILENUM_CONFIG)
endif
ifneq ($(UNISOC_DBG_PATH_CONFIG),)
ccflags-y += -DCONFIG_CUSTOMIZE_UNISOC_DBG_PATH=\"$(UNISOC_DBG_PATH_CONFIG)\"
endif

#### add cflag ######
ifeq ($(CONFIG_WCN_SDIO),y)
ccflags-y += -DCONFIG_WCN_SDIO
ccflags-y += -DCONFIG_WCN_SLP
ccflags-y += -DCONFIG_WCN_SWD
export CONFIG_WCN_SWD = y
endif
ccflags-y += -DCONFIG_WCN_BOOT
ccflags-y += -DCONFIG_WCN_UTILS
ccflags-y += -fno-pic -D__linux__

#### include path ######
ccflags-y += -I$(src)/../tty-sdio
ccflags-y += -I$(src)/include/
ccflags-y += -I$(src)/platform/
ccflags-y += -I$(src)/platform/rf/

### ---------- Allwinner start ---------- ###
ifeq ($(CONFIG_AW_WIFI_DEVICE_UWE5622),y)
#### add cflag ######
ccflags-y += -DCONFIG_AW_BOARD
#ccflags-y += -DCONFIG_WCN_PARSE_DTS
#ccflags-y += -DCONFIG_WCN_CHIPEN
#ccflags-y += -DCONFIG_WCN_RESET
#ccflags-y += -DCONFIG_WCN_RESET_PIN_CONNECTED
ccflags-y += -DCONFIG_WCN_POWER_UP_DOWN
ccflags-y += -DCONFIG_BT_WAKE_HOST_EN
ccflags-y += -DCONFIG_WL_WAKE_HOST_EN
#ccflags-y += -DCONFIG_WCN_RESUME_POWER_DOWN
#ccflags-y += -DCONFIG_WCN_RESUME_KEEPPWR_RESETSDIO
#ccflags-y += -DCONFIG_WCN_CHECK_MODULE_VENDOR
ccflags-y += -DCONFIG_WCN_LOOPCHECK
#ccflags-y += -DCONFIG_CPLOG_DEBUG
#ccflags-y += -DCONFIG_MEM_PD
ccflags-y += -DCONFIG_SDIO_TX_ADMA_MODE
ccflags-y += -DCONFIG_SDIO_RX_ADMA_MODE
ccflags-y += -DCONFIG_SDIO_INBAND_INT
#ccflags-y += -DCONFIG_SDIO_INBAND_POLLING
#ccflags-y += -DCONFIG_SDIO_BLKSIZE_512
#ccflags-y += -DCONFIG_SDIO_PWRSEQ
endif
### ---------- Allwinner end ---------- ###

ifdef CONFIG_WCN_BSP_DRIVER_BUILDIN
obj-y := $(MODULE_NAME).o
else
obj-m := $(MODULE_NAME).o
endif

$(MODULE_NAME)-y += wcn_bus.o \
		    platform/wcn_boot.o \
		    platform/wcn_dump.o \
		    platform/bufring.o \
		    platform/wcn_txrx.o \
		    platform/wcn_op.o \
		    platform/wcn_parn_parser.o \
		    platform/rdc_debug.o \
		    platform/wcn_log.o \
		    platform/wcn_misc.o \
		    platform/wcn_procfs.o \
		    platform/loopcheck.o

$(MODULE_NAME)-$(CONFIG_WCN_SWD) += platform/wcn_swd_dp.o

$(MODULE_NAME)-$(CONFIG_WCN_SDIO) += \
		    sdio/sdiohal_main.o \
		    sdio/sdiohal_common.o \
		    sdio/sdiohal_tx.o \
		    sdio/sdiohal_rx.o \
		    sdio/sdio_v3.o \
		    sdio/sdiohal_ctl.o \
		    sleep/sdio_int.o \
		    sleep/slp_mgr.o \
		    sleep/slp_sdio.o \
		    sleep/slp_test.o \
		    platform/mem_pd_mgr.o
