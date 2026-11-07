#!/bin/bash

set -euo pipefail

ROOT=${1:?usage: configure.sh rootfs-directory}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

install -d -m 0755 "$ROOT/etc/phosh" "$ROOT/etc/dconf/profile" \
	"$ROOT/etc/dconf/db/local.d" "$ROOT/etc/systemd/system/phosh.service.d" \
	"$ROOT/usr/share/alsa/ucm2/conf.d/mt8183_athena"

install -m 0644 "$SCRIPT_DIR/ucm/mt8183_athena.conf" \
	"$ROOT/usr/share/alsa/ucm2/conf.d/mt8183_athena/mt8183_athena.conf"
install -m 0644 "$SCRIPT_DIR/ucm/HiFi.conf" \
	"$ROOT/usr/share/alsa/ucm2/conf.d/mt8183_athena/HiFi.conf"

cat >"$ROOT/etc/phosh/phoc.ini" <<'PHOC'

[core]

xwayland=false

[output:DSI-1]

rotate=90
scale=1

PHOC

cat >"$ROOT/etc/dconf/profile/user" <<'PROFILE'

user-db:user

system-db:local

PROFILE

cat >"$ROOT/etc/dconf/db/local.d/20-athena" <<'DCONF'

[org/gnome/desktop/session]

idle-delay=uint32 300

[org/gnome/desktop/screensaver]

idle-activation-enabled=true

lock-enabled=false

[sm/puri/phosh/lockscreen]

require-unlock=false

[sm/puri/phosh]

app-filter-mode=[]

favorites=['org.gnome.Settings.desktop','foot.desktop']

[org/gnome/settings-daemon/plugins/power]

sleep-inactive-ac-timeout=0

sleep-inactive-battery-timeout=0

power-button-action='nothing'

[org/gnome/settings-daemon/peripherals/touchscreen]

orientation-lock=true

DCONF

cat >"$ROOT/etc/systemd/system/phosh.service.d/athena.conf" <<'UNIT'

[Unit]

Requires=seatd.service

After=seatd.service

[Service]

Environment=LIBSEAT_BACKEND=seatd

UNIT
