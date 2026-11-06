# Echo Show 8 (2nd generation) Linux image

This repository builds a 64-bit Linux kernel and Debian arm64 system image for the Echo Show 8 (2nd generation, Athena / MediaTek MT8183). The image uses Phosh for its touch interface, Phoc as its Wayland compositor, and Squeekboard for its on-screen keyboard.

## Build

Run from the repository directory:

```sh
./build-in-docker.sh
./build-debian-image.sh build/athena-bringup/system.img
```

The kernel image is written to `build/boot-athena.img`. The Debian image is written to `build/athena-bringup/system.img`. Docker is required for the Debian image. On Linux with the arm64 cross compiler and kernel build dependencies installed, `./build.sh` can build the kernel without Docker.

The Debian image installs the explicit runtime package set in `image/debian-arm64/packages.txt` with apt recommends disabled, and excludes documentation and non-English locale files to reduce storage. Phosh runs directly from its packaged systemd service without a display manager. The panel is rotated 270 degrees in `/etc/phosh/phoc.ini`.

The system journal is limited to 24 MB in RAM and is cleared at reboot. This avoids journal writes to eMMC; use the serial console to retain logs across reboots when diagnosing boot problems.

## Install

Unlock the device, boot it into TWRP, connect USB, and check that `adb devices` lists it:

```sh
adb devices
```

Check the target and image hashes before writing:

```sh
python3 install-athena.py --boot build/boot-athena.img --image build/athena-bringup/system.img --dry-run
```

Then install both images:

```sh
python3 install-athena.py --boot build/boot-athena.img --image build/athena-bringup/system.img
```

Type `INSTALL` when prompted. The installer backs up the current boot and system partitions under `backups/<device-id>/`, writes the kernel and system image, then verifies each write. Keep those backups for recovery.

## Touch interface and applications

Phosh provides the app launcher, quick settings, and mobile-style shell. Touch the Phosh keyboard button to show Squeekboard. `foot` is included as a terminal. NetworkManager and BlueZ provide Wi-Fi and Bluetooth services.

The image includes the WebKitGTK 4.1 runtime used by Tauri 2 Linux applications. It does not include the application itself or a Rust toolchain; build the app for arm64 and install its Debian package or application bundle separately. Tauri can avoid shipping a separate Chromium engine with the app. WebKitGTK is still a substantial shared system dependency, about 100 MB installed on arm64, and camera, microphone, WebRTC, and GPU behavior must be checked with the actual app on this device. Optional system-tray support through Ayatana AppIndicator is not installed.

The kernel image and system image are both arm64. The root filesystem uses a small Debian base and omits XWayland, Vulkan drivers, and diagnostic utilities that are not required for the Phosh/Tauri Wayland setup.

## Hardware support

The kernel includes support for the display and touch panel, Panfrost GPU, four-channel microphone ADC, TAS5805M speaker amplifier, OV13855 camera capture path, Wi-Fi, Bluetooth, thermal management, and USB serial gadget. The system image configures the speaker and microphone routes at boot and maps the hardware volume buttons to speaker volume. The physical mute and camera shutter switches are exposed by the kernel. Logind ignores power-key events because the mute button also emits a power-key event.

The camera capture path provides raw Bayer frames; camera applications need to convert them to a display-ready format. Speaker tuning data is extracted from the device's stock boot image by the installer and inserted into a reserved device-tree slot. The tuning data is device-specific and is not stored in this repository.

## Recovery and diagnostics

The installer stores verified backups at `backups/<device-id>/`. Keep them until the new image is confirmed working. To roll back, boot TWRP and restore `p20-boot.img` and `p21-system.img` to their matching partitions. The `--stock-boot` option supplies speaker tuning data when the saved boot backup is not stock; it does not restore a partition.

Debian exposes a USB CDC-ACM console, usually `/dev/ttyACM0` at 115200 baud. Useful checks include:

```sh
uname -a
systemctl status phosh.service --no-pager
aplay -l
arecord -l
bluetoothctl show
```

The root filesystem recipe is `image/debian-arm64/mkrootfs.sh`; the direct runtime package list is `image/debian-arm64/packages.txt`.
