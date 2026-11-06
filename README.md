# Athena Echo Linux

A minimal 64-bit Linux system for the Echo Show 8 (2nd generation, Athena / MT8183). The image uses Debian arm64, Phosh, Phoc and Squeekboard, with a WebKitGTK runtime for Tauri applications.

## Build

Run from the repository directory:

```sh
./build-in-docker.sh
./build-debian-image.sh build/athena/system.img
```

The outputs are `build/boot-athena.img` and `build/athena/system.img`. Docker builds the kernel with the cross compiler and creates the Debian arm64 root filesystem. Set `JOBS=2` or another suitable value to adjust kernel build parallelism.

The kernel builder keeps downloads and Kbuild output in a persistent Docker volume. Set `WORK=/path/to/cache` before `./build-in-docker.sh` to use a host directory instead. The Debian builder stores verified downloads in `$HOME/.cache/athena/debian-arm64`; set `CACHE_DIR` to move that cache. Repeated kernel builds reuse unchanged objects. Debian packages and debootstrap downloads are reused when their package versions match current signed repository metadata.

The root image starts at 1536 MiB. On first boot, the system grows the ext4 filesystem to fill the existing `athena-rootfs` partition. The build does not repartition eMMC or alter the TWRP, cache or userdata partitions.

The kernel runtime is configured by `athena_defconfig`, `dts/`, `src/` and `patches/`. Debian image assembly is in `image/debian-arm64/mkrootfs.sh`; the selected desktop has its package list and setup in `image/debian-arm64/desktop/phosh/`.

## Install

Unlock the device, boot it into TWRP and connect USB. Check that the device appears:

```sh
adb devices
```

Review target and image hashes before writing:

```sh
python3 install-athena.py --boot build/boot-athena.img --image build/athena/system.img --dry-run
```

Install both images:

```sh
python3 install-athena.py --boot build/boot-athena.img --image build/athena/system.img
```

Type `INSTALL` when prompted. The installer backs up the current boot and system partitions under `backups/<device-id>/`, writes both images and verifies them. Keep the backups until the new system is confirmed working.

## Device use

The desktop account is `athena` (UID 1000). It opens a local serial console automatically. At boot, the hostname becomes `athena-<serial-number>` using the device serial passed by the bootloader. That hostname is visible to the local network.

Phosh provides the touch app launcher, quick settings and a brightness slider. Squeekboard is the on-screen keyboard. The display is set to rotate 270 degrees and to blank after five minutes idle. Automatic system suspend is disabled; touching the panel should wake the display. Screen locking is disabled because the account has no password configured.

The app grid includes `Power Off` and `Reboot to TWRP`. The TWRP action writes the standard `boot-recovery` request to the first 32 bytes of the `misc` partition, verifies the write, then reboots. The Echo's LK bootloader handoff has not yet been tested with this action; verify it on the device before relying on it. TWRP is installed in the recovery partition.

NetworkManager handles Wi-Fi and BlueZ handles Bluetooth. A USB CDC-ACM serial console is available from the host, usually as `/dev/ttyACM0` at 115200 baud. The image does not install an SSH server.

## Hardware

The kernel and root filesystem configure the display and touch panel, Panfrost GPU, speakers and four-channel microphones, OV13855 camera capture path, Wi-Fi, Bluetooth, hardware volume keys and USB serial console. Audio routing is applied by `athena-audio-init`. The physical mute input is ignored by logind because the switch also reports a power key.

The camera driver exposes raw Bayer capture. An application needs to convert frames to a display-ready format. The camera path, microphone capture, display blanking, brightness changes and TWRP handoff should be verified with the final image on the device.

## Security and updates

The `athena` account is unprivileged. Passwordless sudo is limited to the volume-key handler and fixed power actions; the account cannot run arbitrary commands as root. The root password is locked. An autologin serial console still grants local shell access to anyone with physical serial access.

Dependabot checks GitHub Actions and the pinned Docker base image weekly. Image builds use Debian Trixie, its stable-updates and security repositories, disable apt recommends and upgrade the base packages before installing the desktop. Package indexes are refreshed from signed repository metadata each build. Kernel and firmware sources are pinned by version and SHA-256; update those pins deliberately when moving to newer versions.

The journal is volatile and capped at 24 MiB to reduce eMMC writes. APT lists and downloaded packages are removed from the final image. Kernel outputs, build caches, logs and backups are ignored by Git.

## CI and releases

Pull requests run shell and Python checks, boot-image packer unit tests, and repository secret and configuration scans. Changes to kernel or image inputs also compile the kernel, create the Debian arm64 filesystem, inspect the images, scan installed packages for vulnerabilities, and generate a CycloneDX SBOM. Non-release image builds retain the vulnerability report and SBOM as workflow artifacts. A weekly image build refreshes Debian packages and the vulnerability database. Dependabot checks GitHub Actions and the pinned build and scanner images.

Pushing a version tag such as `v1.0.0` runs the same build and scan gates, then publishes the boot image, system image, matching kernel source archive, kernel configuration, checksums, vulnerability report and SBOM as a GitHub release. A tag build fails when the image has fixable High or Critical package vulnerabilities; findings without a Debian fix remain in the attached report. The release job also creates signed provenance attestations. Enable immutable releases in the repository settings to prevent published release assets from being replaced. CI validates image contents but cannot test physical screen, touch, camera, audio or recovery behavior; those still need an Echo device.

The source scan suppresses Trivy rule `DS-0002` for the ephemeral build and scanner containers, which need root to perform their build or scan jobs. These are not deployed to the Echo; the installed system runs its desktop account as an unprivileged user.
