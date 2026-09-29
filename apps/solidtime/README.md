# solidtime

Трекер часу з клієнтами, проєктами й задачами, таймером у браузері і програмою для Windows.
Без скриншотів екрана. Доступ — лише через Tailscale.

```bash
mkdir -p /srv/apps/solidtime
cp -r /opt/pi-server/apps/solidtime/. /srv/apps/solidtime/
cd /srv/apps/solidtime
mkdir -p data && sudo chown -R 1000:1000 data
cp .env.example .env     # APP_URL, DB_PASSWORD
docker compose pull
docker compose run --rm --no-deps -T scheduler php artisan self-host:generate-keys >> .env
docker compose up -d
sudo tailscale serve --service=svc:time --bg 8000
```

Повна інструкція — [docs/timetracking.md](../../docs/timetracking.md): акаунт, програма для ПК,
як організувати клієнтів, бекапи, відновлення.

| Файл | Призначення |
|---|---|
| `docker-compose.yml` | застосунок (`127.0.0.1:8000`), планувальник, черга, PostgreSQL, Gotenberg |
| `.env.example` | зразок конфігурації; справжній `.env` у git не потрапляє |
| `backup.sh` | `pg_dump` бази + `data` + `.env` на microSD |

П'ять контейнерів, разом ~0.8–1.3 ГБ пам'яті. Стан і години за місяць: `timetracker-status`
