# Linkwarden

Менеджер закладок з колекціями, тегами і автоматичним архівуванням сторінок
(скриншот + PDF). Доступ — лише через Tailscale.

```bash
cp -r /opt/pi-server/apps/linkwarden/. /srv/apps/linkwarden/
cd /srv/apps/linkwarden
cp .env.example .env     # NEXTAUTH_URL, NEXTAUTH_SECRET, POSTGRES_PASSWORD
docker compose up -d
sudo tailscale serve --service=svc:links --bg 3000
```

Повна інструкція — [docs/bookmarks.md](../../docs/bookmarks.md): налаштування,
розширення для Chrome, імпорт закладок, бекапи, відновлення.

| Файл | Призначення |
|---|---|
| `docker-compose.yml` | застосунок (`127.0.0.1:3000`) + PostgreSQL без портів назовні |
| `.env.example` | зразок конфігурації; справжній `.env` у git не потрапляє |
| `backup.sh` | `pg_dump` бази + архіви сторінок на microSD |

Два контейнери, разом ~1–1.5 ГБ пам'яті. Стан: `bookmarks-status`
