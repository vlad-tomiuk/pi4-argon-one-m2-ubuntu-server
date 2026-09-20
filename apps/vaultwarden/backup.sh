#!/usr/bin/env bash
# Резервна копія сховища Vaultwarden на окрему microSD-карту.
# База копіюється через sqlite3 .backup, щоб не зловити її на середині запису.
# Налаштування карти і розкладу — див. BACKUP.md у корені репозиторію.

set -euo pipefail

APP=/srv/apps/vaultwarden
SRC="$APP/data"
DST=${DST:-/srv/backup/vaultwarden}          # microSD
MIRROR=${MIRROR:-/srv/share/backups/vaultwarden}  # копія на диску W:, для зручності
KEEP_DAYS=${KEEP_DAYS:-90}                   # на карті 128 ГБ, тримаємо довго
MIRROR_KEEP=7

[ -d "$SRC" ] || { echo "Немає $SRC"; exit 1; }

# Якщо карта не змонтована — зупиняємось, інакше архіви тихо ляжуть на SSD
# і бекап перестане бути бекапом.
mountpoint -q "$(dirname "$DST")" || {
    echo "ПОМИЛКА: $(dirname "$DST") не змонтовано. Карта вставлена? Перевір: lsblk"
    exit 1
}

mkdir -p "$DST"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Узгоджена копія бази (працює навіть коли контейнер пише)
sqlite3 "$SRC/db.sqlite3" ".backup '$TMP/db.sqlite3'"

# Конфіг кладемо поруч, щоб відновлення не потребувало нічого зовнішнього
cp "$APP/docker-compose.yml" "$TMP/" 2>/dev/null || true
cp "$APP/.env"               "$TMP/" 2>/dev/null || true

STAMP=$(date +%F_%H%M)
ARCHIVE="$DST/vaultwarden-$STAMP.tar.gz"

tar -czf "$ARCHIVE" \
    -C "$SRC" --exclude='db.sqlite3' --exclude='db.sqlite3-*' --exclude='icon_cache' . \
    -C "$TMP" db.sqlite3 docker-compose.yml .env 2>/dev/null \
  || tar -czf "$ARCHIVE" \
        -C "$SRC" --exclude='db.sqlite3' --exclude='db.sqlite3-*' --exclude='icon_cache' . \
        -C "$TMP" db.sqlite3

chmod 600 "$ARCHIVE"

# Перевірка, що архів цілий
gzip -t "$ARCHIVE"

# Прибираємо старі копії
find "$DST" -name 'vaultwarden-*.tar.gz' -mtime "+$KEEP_DAYS" -delete

# Свіжа копія на мережевий диск, щоб було видно з Windows
if [ -n "$MIRROR" ]; then
    mkdir -p "$MIRROR"
    cp "$ARCHIVE" "$MIRROR/"
    # там тримаємо лише кілька останніх
    ls -1t "$MIRROR"/vaultwarden-*.tar.gz 2>/dev/null | tail -n +$((MIRROR_KEEP + 1)) | xargs -r rm -f
fi

sync
echo "$(date '+%F %T')  OK  $ARCHIVE  ($(du -h "$ARCHIVE" | cut -f1))  вільно на карті: $(df -h "$DST" | awk 'NR==2{print $4}')"
