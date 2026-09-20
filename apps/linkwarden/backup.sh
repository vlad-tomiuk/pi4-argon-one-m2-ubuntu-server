#!/usr/bin/env bash
# Щоденна резервна копія закладок (Linkwarden).
#
# Тут дві різні речі: база PostgreSQL (посилання, теги, колекції) і папка data
# (скриншоти, PDF, збережені копії сторінок). Потрібні обидві.
# База знімається через pg_dump — копіювати файли PostgreSQL наживо не можна.

set -euo pipefail

APP=/srv/apps/linkwarden
DST=${DST:-/srv/backup/linkwarden}
MIRROR=${MIRROR:-/srv/share/backups/linkwarden}
KEEP_DAYS=${KEEP_DAYS:-90}
MIRROR_KEEP=7
DB_CONTAINER=linkwarden-db

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

docker exec "$DB_CONTAINER" pg_dump -U postgres --clean --if-exists postgres > "$TMP/db.sql"
[ -s "$TMP/db.sql" ] || { echo "ПОМИЛКА: порожній дамп бази"; exit 1; }

cp "$APP/docker-compose.yml" "$TMP/" 2>/dev/null || true
cp "$APP/.env"               "$TMP/" 2>/dev/null || true

STAMP=$(date +%F_%H%M)
ARCHIVE="$DST/linkwarden-$STAMP.tar.gz"

# data/ може важити сотні мегабайт через збережені копії сторінок
tar -czf "$ARCHIVE" -C "$APP" data -C "$TMP" db.sql docker-compose.yml .env 2>/dev/null \
  || tar -czf "$ARCHIVE" -C "$APP" data -C "$TMP" db.sql

chmod 600 "$ARCHIVE"
gzip -t "$ARCHIVE"

find "$DST" -name 'linkwarden-*.tar.gz' -mtime "+$KEEP_DAYS" -delete

if [ -n "$MIRROR" ]; then
    mkdir -p "$MIRROR"
    cp "$ARCHIVE" "$MIRROR/"
    ls -1t "$MIRROR"/linkwarden-*.tar.gz 2>/dev/null | tail -n +$((MIRROR_KEEP + 1)) | xargs -r rm -f
fi

sync
echo "$(date '+%F %T')  OK  $ARCHIVE  ($(du -h "$ARCHIVE" | cut -f1))  вільно: $(df -h "$DST" | awk 'NR==2{print $4}')"
