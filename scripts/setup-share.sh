#!/usr/bin/env bash
# setup-share.sh — network drive: a fixed-size disk image shared over SMB.
#
#   sudo bash scripts/setup-share.sh                    # 10G, share "Workplace"
#   sudo bash scripts/setup-share.sh -s 50G -n Media    # own size and name
#
# Why an image file instead of sharing a folder: the size is a hard limit, so the
# drive can never eat the space Docker and the websites need.
#
# Safe to re-run: existing image, mount and config are kept as they are.

set -euo pipefail
[ "$EUID" -eq 0 ] || exec sudo "$0" "$@"

SIZE=10G
NAME=Workplace
MOUNT=/srv/share
IMAGE=/srv/images/share.img
USERNAME=${SUDO_USER:-root}

usage(){ cat << 'HELP'
Використання: sudo bash scripts/setup-share.sh [параметри]

  -s, --size SIZE     розмір диска (10G, 50G, 500M...), за замовчуванням 10G
  -n, --name NAME     назва мережевої папки, за замовчуванням Workplace
  -u, --user USER     користувач Samba, за замовчуванням той, хто викликав sudo
  -m, --mount PATH    точка монтування, за замовчуванням /srv/share
  -h, --help          ця довідка
HELP
}

while [ $# -gt 0 ]; do
    case "$1" in
        -s|--size)  SIZE="${2:?}"; shift 2 ;;
        -n|--name)  NAME="${2:?}"; shift 2 ;;
        -u|--user)  USERNAME="${2:?}"; shift 2 ;;
        -m|--mount) MOUNT="${2:?}"; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        *) usage; echo "Невідомий параметр: $1"; exit 1 ;;
    esac
done

id "$USERNAME" >/dev/null 2>&1 || { echo "Немає користувача $USERNAME"; exit 1; }

echo "== Образ диска =="
mkdir -p "$(dirname "$IMAGE")" "$MOUNT"
if [ -f "$IMAGE" ]; then
    echo "Образ уже існує: $IMAGE (пропускаю створення)"
else
    fallocate -l "$SIZE" "$IMAGE"
    mkfs.ext4 -q -L share "$IMAGE"
    tune2fs -m 0 "$IMAGE" >/dev/null   # no 5% root reserve on a data disk
    echo "Створено $IMAGE на $SIZE"
fi

echo
echo "== Монтування =="
if ! grep -q "^$IMAGE " /etc/fstab; then
    echo "$IMAGE $MOUNT ext4 loop,defaults,nofail 0 2" >> /etc/fstab
    systemctl daemon-reload
fi
mountpoint -q "$MOUNT" || mount "$MOUNT"
chown "$USERNAME:$USERNAME" "$MOUNT"
df -h "$MOUNT" | tail -1

echo
echo "== Samba =="
command -v smbd >/dev/null || { apt-get update -qq; apt-get install -y -qq samba; }

if grep -q "^\[$NAME\]" /etc/samba/smb.conf; then
    echo "Секція [$NAME] уже є в smb.conf (пропускаю)"
else
    cat >> /etc/samba/smb.conf << EOF

[$NAME]
   path = $MOUNT
   valid users = $USERNAME
   read only = no
   browseable = yes
   create mask = 0664
   directory mask = 0775
   veto files = /lost+found/
   delete veto files = no
EOF
fi
testparm -s >/dev/null
systemctl enable --now smbd >/dev/null
systemctl restart smbd

echo
echo "== Файрвол =="
# Same LAN the installer allowed SSH from; SMB must never leave the local network.
LAN=$(awk '/^LAN_CIDR=/{print $0}' /opt/pi-setup/setup.conf 2>/dev/null | cut -d= -f2)
[ -n "$LAN" ] || LAN=$(ip -4 route | awk '/proto kernel/ && /scope link/ && !/docker/ {print $1; exit}')
ufw allow from "$LAN" to any port 445 proto tcp comment 'Samba only from LAN' >/dev/null
echo "445/tcp дозволено з $LAN"

echo
echo "== Пароль Samba =="
echo "Пароль для мережевого диска окремий від системного."
smbpasswd -a "$USERNAME"

cat << EOF

Готово.

  Windows:  net use W: \\\\$(hostname)\\$NAME /user:$USERNAME /persistent:yes
  macOS:    smb://$(hostname)/$NAME
  Перевірка на сервері:  sudo disk-status

Автопідключення у Windows: windows/Workplace-Disk.ps1 -Install
EOF
