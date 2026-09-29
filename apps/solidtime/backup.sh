#!/usr/bin/env bash
# Щоденна резервна копія трекера часу (solidtime).
#
# Головне — база PostgreSQL: клієнти, проєкти, задачі, записи часу. Папка data
# (аватарки, згенеровані експорти) маленька, але пакуємо і її.
# .env обов'язковий: без APP_KEY і ключів Passport відновлена база не відкриється.
# База знімається через pg_dump — копіювати файли PostgreSQL наживо не можна.

set -euo pipefail

APP=/srv/apps/solidtime
DST=${DST:-/srv/backup/solidtime}
MIRROR=${MIRROR:-/srv/share/backups/solidtime}
KEEP_DAYS=${KEEP_DAYS:-90}
MIRROR_KEEP=7
DB_CONTAINER=solidtime-db

[ -d "$APP" ] || { echo "Немає $APP"; exit 1; }

# Якщо карта не змонтована — зупиняємось, інакше архіви тихо ляжуть на SSD
# і бекап перестане бути бекапом.
mountpoint -q "$(dirname "$DST")" || {
    echo "ПОМИЛКА: $(dirname "$DST") не змонтовано. Карта вставлена? Перевір: lsblk"
    exit 1
}

docker ps --format '{{.Names}}' | grep -qx "$DB_CONTAINER" || {
    echo "ПОМИЛКА: контейнер $DB_CONTAINER не запущений"
    exit 1
}

mkdir -p "$DST"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

docker exec "$DB_CONTAINER" pg_dump -U solidtime --clean --if-exists solidtime > "$TMP/db.sql"
[ -s "$TMP/db.sql" ] || { echo "ПОМИЛКА: порожній дамп бази"; exit 1; }

cp "$APP/docker-compose.yml" "$TMP/"
cp "$APP/.env"               "$TMP/"

STAMP=$(date +%F_%H%M)
ARCHIVE="$DST/solidtime-$STAMP.tar.gz"

tar -czf "$ARCHIVE" -C "$APP" data -C "$TMP" db.sql docker-compose.yml .env

chmod 600 "$ARCHIVE"
gzip -t "$ARCHIVE"

find "$DST" -name 'solidtime-*.tar.gz' -mtime "+$KEEP_DAYS" -delete

if [ -n "$MIRROR" ]; then
    mkdir -p "$MIRROR"
    cp "$ARCHIVE" "$MIRROR/"
    ls -1t "$MIRROR"/solidtime-*.tar.gz 2>/dev/null | tail -n +$((MIRROR_KEEP + 1)) | xargs -r rm -f
fi

sync
echo "$(date '+%F %T')  OK  $ARCHIVE  ($(du -h "$ARCHIVE" | cut -f1))  вільно: $(df -h "$DST" | awk 'NR==2{print $4}')"
