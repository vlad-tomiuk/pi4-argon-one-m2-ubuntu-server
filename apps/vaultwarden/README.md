# Vaultwarden

Менеджер паролів, сумісний з Bitwarden. Доступ — лише через Tailscale.

```bash
cp -r /opt/pi-server/apps/vaultwarden /srv/apps/vaultwarden
cd /srv/apps/vaultwarden
cp .env.example .env     # DOMAIN + ADMIN_TOKEN
docker compose up -d
```

Повна інструкція — [docs/passwords.md](../../docs/passwords.md):
Tailscale, HTTPS, створення акаунта, клієнти, бекапи.

| Файл | Призначення |
|---|---|
| `docker-compose.yml` | контейнер, слухає лише `127.0.0.1:8080` |
| `.env.example` | зразок конфігурації; справжній `.env` у git не потрапляє |
| `backup.sh` | щоденний бекап на microSD, див. [docs/backups.md](../../docs/backups.md) |

Стан: `password-status`
