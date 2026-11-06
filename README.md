# Echo Show 8 (2nd generation) Linux image

This repository builds a 64-bit Linux kernel and Debian arm64 system image for the Echo Show 8 2nd generation (Athena, MediaTek MT8183). It includes the board device tree, hardware drivers and patches, image builder, and TWRP installer.

## Build

Run these commands from the repository directory:

```sh
./build-in-docker.sh
./build-debian-image.sh build/athena-bringup/system.img
```

The kernel image is written to `build/boot-athena.img`. The Debian system image is written to `build/athena-bringup/system.img`. Docker is required. On Linux with the arm64 cross compiler and kernel build dependencies installed, `./build.sh` can build the kernel without Docker.

## Install

Unlock the device, boot it into TWRP, connect USB, and check that `adb devices` lists it:

```sh
adb devices
```

Check the target device and image hashes before flashing:

```sh
python3 install-athena.py --boot build/boot-athena.img --image build/athena-bringup/system.img --dry-run
```

Then install both images:

```sh
python3 install-athena.py --boot build/boot-athena.img --image build/athena-bringup/system.img
```

Type `INSTALL` when prompted. The installer backs up the current boot and system partitions under `backups/<device-id>/`, writes the kernel before the system image, and verifies each write. Keep those backups for recovery.

## Hardware support

The kernel includes support for the display and touch panel, Panfrost GPU, four-channel microphone ADC, TAS5805M speaker amplifier, OV13855 camera capture path, Wi-Fi, Bluetooth, thermal management, and USB serial gadget. The Debian image starts Weston and configures the speaker and microphone routes at boot. The physical mute and camera shutter switches are exposed by the kernel.

The speaker tuning data is extracted from the device's stock boot image by the installer and inserted into a reserved device-tree slot. It is device-specific and is not stored in this repository. The camera capture path provides raw Bayer frames; camera applications need to convert them to a display-ready format.

## Recovery and diagnostics

The installer stores verified backups at `backups/<device-id>/`. Keep them until the new image is confirmed working. To roll back, boot TWRP and restore `p20-boot.img` and `p21-system.img` to their matching partitions. The `--stock-boot` option supplies speaker tuning data when the saved boot backup is not stock; it does not restore a partition.

The kernel prints boot messages to the display and internal UART. Debian provides a USB CDC-ACM console, usually `/dev/ttyACM0` at 115200 baud. Useful device checks include:

```sh
uname -a
aplay -l
arecord -l
libinput list-devices
bluetoothctl show
```

See `image/debian-arm64/mkrootfs.sh` for system image setup and `build.sh` for kernel configuration and build steps.
