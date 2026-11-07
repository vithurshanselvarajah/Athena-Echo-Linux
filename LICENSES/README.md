# License and attribution inventory

This repository has mixed licensing. Project-authored code is MIT-licensed unless a file-level SPDX identifier or an upstream attribution below specifies other terms. Neither MIT notice applies to GPL-licensed kernel work or other third-party material.

## MIT

Project-authored software is licensed under the MIT terms in the repository-root [LICENSE](../LICENSE). This includes the build, install, image, CI and test tooling, except files or portions identified below under other terms.

These files are marked `SPDX-License-Identifier: MIT` and also contain code derived from the corresponding Athena kernel tools in [TECHO5](https://github.com/HuskerMinion/techo5):

- `build.sh`
- `check-boot.py`
- `check-source.py`
- `dsp_slot.py`
- `mkfwcpio.py`
- `pack.py`

The TECHO5 copyright and permission notice for copied and adapted portions is in [MIT-TECHO5.txt](MIT-TECHO5.txt). Copyright in subsequent modifications remains with their respective authors.

## Linux kernel and GPL code

Kernel patchers and driver sources marked `GPL-2.0` or `GPL-2.0-only` retain those file-level terms. The kernel patches modify Linux kernel code and are distributed with the matching patched kernel source archive in tagged releases. The board device tree, `dts/mt8183-amazon-athena.dts`, is dual-licensed `GPL-2.0 OR MIT` as stated in its SPDX identifier.

Upstream material incorporated into the kernel work includes:

- The MediaTek camera receiver and CAMSV drivers in `src/camera/isp/`, derived from BayLibre's MT8365 ISP series as published in [vpavlin/mt8183-camera](https://github.com/vpavlin/mt8183-camera), commit `c00ad16`. The original copyright and SPDX headers are retained; Athena changes are marked in the source.
- OV13855 register tables in `src/camera/ov13855-tables.inc`, from Rockchip's GPL-licensed driver, identified in that file.
- Amazon Echo Show 8 panel initialization tables in `patches/panel/`, from Amazon's GPL-2.0 kernel, identified in the patches.

The downloaded Linux kernel source has its own `COPYING` and file-level notices. Preserve those and the corresponding source archive when redistributing a built kernel.

## Other files and build outputs

Files without an SPDX identifier are not relicensed by this inventory. Check their headers and upstream sources before redistributing them. Generated root filesystems and boot images also contain Debian packages and MediaTek firmware; their respective licenses apply. The firmware's `LICENCE.mediatek` is included in the firmware ramdisk.