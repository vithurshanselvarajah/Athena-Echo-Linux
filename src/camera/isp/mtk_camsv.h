/* SPDX-License-Identifier: GPL-2.0 */

/*

 * Copyright (c) 2020 BayLibre

 * Copyright (c) 2022 MediaTek Inc.

 */

#ifndef __MTK_CAMSV_H__

#define __MTK_CAMSV_H__

#include <linux/clk.h>

#include <linux/err.h>

#include <linux/errno.h>

#include <linux/kernel.h>

#include <linux/pm_runtime.h>

#include <linux/videodev2.h>

#include <media/media-entity.h>

#include <media/v4l2-subdev.h>

#include <media/videobuf2-core.h>

#include <media/videobuf2-dma-contig.h>

#include <media/videobuf2-v4l2.h>

#include <soc/mediatek/smi.h>

#define IMG_MAX_WIDTH			5376U

#define IMG_MAX_HEIGHT			4032U

#define IMG_MIN_WIDTH			80U

#define IMG_MIN_HEIGHT			60U

#define MAX_SUPPORTED_NUM_PLANES	1U

#define MTK_CAM_CIO_PAD_SENINF		0U

#define MTK_CAM_CIO_PAD_VIDEO		1U

#define MTK_CAM_CIO_NUM_PADS		2U

struct mtk_cam_format_info {

	u32 code;

	u32 fourcc;

	u8 bpp;

	u32 w_factor;

	u32 module_en_pak;

	u32 fmt_sel;

	u32 pak;

	u32 imgo_stride;

};

const struct mtk_cam_format_info *mtk_cam_format_info_by_code(u32 code);

void mtk_cam_format_info_apply_out_mode(unsigned int out_mode);

struct mtk_cam_dev_buffer {

	struct vb2_v4l2_buffer v4l2_buf;

	struct list_head list;

	dma_addr_t daddr;

};

struct mtk_cam_vdev_desc {

	u8 num_fmts;

	const u32 *fmts;

	const struct v4l2_frmsizeenum *frmsizes;

};

struct mtk_cam_video_device {

	const struct mtk_cam_vdev_desc *desc;

	struct media_pad vdev_pad;

	struct video_device vdev;

	struct vb2_queue vbq;

	struct mutex vdev_lock;

	struct v4l2_pix_format_mplane format;

	const struct mtk_cam_format_info *fmtinfo;

};

struct mtk_cam_dev {

	struct device *dev;

	void __iomem *regs;

	void __iomem *regs_img0;

	void __iomem *regs_tg;

	unsigned int num_clks;

	struct clk_bulk_data *clks;

	unsigned int irq;

	const struct mtk_cam_conf *conf;

	struct media_pipeline pipeline;

	struct v4l2_subdev subdev;

	struct media_pad subdev_pads[MTK_CAM_CIO_NUM_PADS];

	struct mtk_cam_video_device vdev;

	struct media_pad *seninf;

	unsigned int sequence;

	spinlock_t buf_list_lock;

	struct list_head buf_list;

	struct mtk_cam_dev_buffer *cur;

	void *scratch_va;

	dma_addr_t scratch_dma;

	size_t scratch_size;

	u32 irq_cnt;

	u32 done_cnt;

	u32 err_cnt;

	u32 scratch_cnt;

	u32 last_status;

	struct dentry *dbg;

	bool vdev_registered;

};

struct mtk_cam_conf {

	u32 tg_sen_mode;

	u32 module_en;

	u32 imgo_con;

	u32 imgo_con2;

	u32 imgo_xsize;

	u32 imgo_ysize;

	u32 imgo_stride;

	u32 imgo_con_reg;

	u32 imgo_con2_reg;

	bool has_fbc;

	bool pak_reversed;

};

int mtk_cam_dev_init(struct mtk_cam_dev *cam_dev);

void mtk_cam_dev_cleanup(struct mtk_cam_dev *cam_dev);

int mtk_cam_video_register(struct mtk_cam_dev *cam_dev);

void mtk_cam_video_unregister(struct mtk_cam_video_device *vdev);

void mtk_cam_vb2_return_all_buffers(struct mtk_cam_dev *cam,

				    enum vb2_buffer_state state);

#endif
