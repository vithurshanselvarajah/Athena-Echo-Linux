#!/bin/bash

set -euo pipefail

ROOT=${1:?usage: configure.sh rootfs-directory}

install -d -m 0755 "$ROOT/etc/phosh" "$ROOT/etc/dconf/profile" \
	"$ROOT/etc/dconf/db/local.d" "$ROOT/etc/systemd/system/phosh.service.d"

cat > "$ROOT/etc/phosh/phoc.ini" <<'PHOC'

[core]

xwayland=false

[output:DSI-1]

rotate=270

PHOC

cat > "$ROOT/etc/dconf/profile/user" <<'PROFILE'

user-db:user

system-db:local

PROFILE

cat > "$ROOT/etc/dconf/db/local.d/20-athena" <<'DCONF'

[org/gnome/desktop/session]

idle-delay=uint32 300

[org/gnome/desktop/screensaver]

idle-activation-enabled=true

lock-enabled=false

[org/gnome/settings-daemon/plugins/power]

sleep-inactive-ac-timeout=0

sleep-inactive-battery-timeout=0

DCONF

cat > "$ROOT/etc/systemd/system/phosh.service.d/athena.conf" <<'UNIT'

[Unit]

Requires=seatd.service

After=seatd.service

[Service]

Environment=LIBSEAT_BACKEND=seatd

UNIT
