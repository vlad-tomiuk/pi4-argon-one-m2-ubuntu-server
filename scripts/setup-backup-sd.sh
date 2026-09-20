#!/usr/bin/env bash
# setup-backup-sd.sh — turn the free microSD slot into the backup target (/srv/backup).
#
#   sudo bash scripts/setup-backup-sd.sh
#
# The system boots from the SSD, so the card is used for nothing else. Keeping
# backups on a second physical device is the whole point: a copy on the same SSD
# dies together with the original.
#
# WARNING: the card is erased completely.

set -euo pipefail
[ "$EUID" -eq 0 ] || exec sudo "$0" "$@"

CARD=${1:-/dev/mmcblk0}
MOUNT=/srv/backup
PART="${CARD}p1"

[ -b "$CARD" ] || { echo "Карта $CARD не знайдена. Вставлена? Перевір: lsblk"; exit 1; }

# Refuse to touch the disk the system is running from.
ROOT_SRC=$(findmnt -no SOURCE /)
ROOT_DISK="/dev/$(lsblk -no PKNAME "$ROOT_SRC" | head -1)"
[ "$CARD" != "$ROOT_DISK" ] || { echo "$CARD — це системний диск. Зупиняюсь."; exit 1; }

echo "Буде стерто:"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$CARD"
read -rp "Усі дані на $CARD зникнуть. Введи YES: " ok
[ "$ok" = "YES" ] || { echo "Скасовано"; exit 1; }

echo "== Розмітка =="
for p in $(lsblk -lnpo NAME "$CARD" | tail -n +2); do umount -f "$p" 2>/dev/null || true; done
wipefs -a "$CARD" >/dev/null
parted -s "$CARD" mklabel gpt mkpart primary ext4 0% 100%
udevadm settle; sleep 2
mkfs.ext4 -q -L backup "$PART"
tune2fs -m 0 "$PART" >/dev/null

echo "== Монтування =="
mkdir -p "$MOUNT"
UUID=$(blkid -s UUID -o value "$PART")
# Mount by UUID: device names can change, UUIDs do not. nofail = boot works without the card.
if ! grep -q "$UUID" /etc/fstab; then
    echo "UUID=$UUID $MOUNT ext4 defaults,nofail,noatime 0 2" >> /etc/fstab
    systemctl daemon-reload
fi
mountpoint -q "$MOUNT" || mount "$MOUNT"
chown "${SUDO_USER:-root}:${SUDO_USER:-root}" "$MOUNT"
df -h "$MOUNT" | tail -1

echo "== Розклад бекапів =="
command -v sqlite3 >/dev/null || { apt-get update -qq; apt-get install -y -qq sqlite3; }

if [ -f /srv/apps/vaultwarden/backup.sh ]; then
    chmod +x /srv/apps/vaultwarden/backup.sh
    cat > /etc/cron.d/vaultwarden-backup << 'CRON'
30 3 * * * root /srv/apps/vaultwarden/backup.sh >> /var/log/vaultwarden-backup.log 2>&1
CRON
    chmod 644 /etc/cron.d/vaultwarden-backup
    echo "Vaultwarden: щодня о 3:30"
    /srv/apps/vaultwarden/backup.sh || echo "!!! Перший бекап не вдався, дивись помилку вище"
else
    echo "Vaultwarden не знайдено — розклад не створено"
fi

cat << EOF

Готово. Бекапи: $MOUNT

  Перевірка:   ls -lh $MOUNT/*/ ; tail /var/log/vaultwarden-backup.log
  Стан диска:  server-status

Пам'ятай: карта лежить у тому ж Pi. Раз на кілька місяців роби експорт
сховища (Tools → Export vault) і зберігай його поза домом — docs/backups.md
EOF
