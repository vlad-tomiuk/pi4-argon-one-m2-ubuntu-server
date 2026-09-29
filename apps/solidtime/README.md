# solidtime

Трекер часу замість Time Doctor / Toggl, без скриншотів екрана: клієнти, проєкти, задачі,
таймер у браузері, програмі для ПК і розширенні для браузера, звіти CSV/PDF.
Доступ — лише через Tailscale. Безкоштовно: на власному сервері відкриті оцінки часу,
округлення й PDF-звіти, платне лише виставлення рахунків.

П'ять контейнерів, разом ~0.8–1.3 ГБ пам'яті. Стан і години за місяць: `timetracker-status`.
Повна інструкція з поясненнями — [docs/timetracking.md](../../docs/timetracking.md).

Нижче `tailXXXX` — ім'я твоєї мережі Tailscale. Його видно в адресі будь-якого сервісу,
наприклад `grep NEXTAUTH_URL /srv/apps/linkwarden/.env`.

## 1. Сервер

```bash
server-update --self                       # свіжий репозиторій і команда timetracker-status

mkdir -p /srv/apps/solidtime
cp -r /opt/pi-server/apps/solidtime/. /srv/apps/solidtime/
cd /srv/apps/solidtime
chmod +x backup.sh
mkdir -p data && sudo chown -R 1000:1000 data

openssl rand -hex 24                       # пароль бази, лише цифри й a–f
cp .env.example .env
nano .env
```

```
APP_URL=https://time.tailXXXX.ts.net
DB_PASSWORD=<рядок з openssl>
SUPER_ADMINS=you@example.com               # необов'язково: адмін-панель /admin
```

```bash
docker compose pull                        # ~2 ГБ
docker compose run --rm --no-deps -T scheduler php artisan self-host:generate-keys >> .env   # ОДИН раз
grep -c -E '^(APP_KEY|PASSPORT_PRIVATE_KEY|PASSPORT_PUBLIC_KEY)=' .env                      # має бути 3
docker compose up -d
docker compose ps                          # 5 контейнерів, усі (healthy) через 1–2 хвилини
```

## 2. Tailscale

1. https://login.tailscale.com/admin/services → **Add service**: ім'я `time`, порт `tcp:443`.
   Хост має бути тегованим — див. [docs/bookmarks.md](../../docs/bookmarks.md#2-публікація-через-tailscale-services).
2. На сервері:
   ```bash
   sudo tailscale serve --service=svc:time --bg 8000
   ```
3. В адмінці: `time` → **Hosts** → **Approve**.

## 3. Акаунт

Реєстрації немає, акаунт створюється командою. Контейнери вже мають бути запущені
(`docker compose up -d`), інакше буде `service "scheduler" is not running`.

```bash
docker compose exec scheduler php artisan admin:user:create "Ім'я Прізвище" "you@example.com" \
  --ask-for-password --verify-email
```

Відкрий `https://time.tailXXXX.ts.net`, увійди, і в **Profile** одразу постав
**Timezone → Europe/Kyiv** та **Week start → Monday** (інакше записи будуть в UTC).

## 4. Програма для ПК

Завантаження: https://github.com/solidtime-io/solidtime-desktop/releases/latest

| Система | Файл |
|---|---|
| Windows, Intel / AMD (майже всі ПК) | `solidtime-setup-x64.exe` |
| Windows на ARM (Snapdragon) | `solidtime-setup-arm64.exe` |
| macOS, Apple Silicon (M1…) | `solidtime-arm64.dmg` |
| macOS, Intel | `solidtime-x64.dmg` |
| Linux | `solidtime-amd64.deb`, `solidtime-x86_64.rpm` або `.tar.gz` |

Не впевнений, яка в тебе Windows: **Параметри → Система → Про систему → Тип системи**
(«x64» — бери x64). SmartScreen може сказати «Невідомий видавець» → **Докладніше → Все одно запустити**.

**Client ID** — програма входить через OAuth, тому для неї потрібен клієнт на сервері. Один раз:

```bash
cd /srv/apps/solidtime
docker compose exec scheduler php artisan passport:client \
  --name=desktop --redirect_uri=solidtime://oauth/callback --public -n
```

Скопіюй рядок після `Client ID`. Загубив — подивитись можна будь-коли:

```bash
docker exec solidtime-db psql -U solidtime -d solidtime -c "select id, name from oauth_clients;"
```

**Підключення:** запусти програму → **Instance Settings** →

- **API URL:** `https://time.tailXXXX.ts.net` (без `/` у кінці)
- **Client ID:** рядок з команди вище

→ **Log in** → вхід у браузері → **Authorize** → дозволь відкрити посилання `solidtime://`.
Таймер живе в треї. Корисне в налаштуваннях: **Idle detection** — якщо відійшов від ПК із
запущеним таймером, програма спитає, що робити з часом простою.

## 5. Розширення для браузера (необов'язково)

Таймер прямо з вкладки браузера:
[Chrome / Edge](https://chromewebstore.google.com/detail/solidtime/hpanifeankiobmgbemnhjmhpjeebdhdd) ·
[Firefox](https://addons.mozilla.org/firefox/addon/solidtime/)

Йому потрібен свій клієнт на сервері (один раз):

```bash
docker compose exec scheduler php artisan passport:client --name=browser-extension \
  --redirect_uri=https://3369f72567118d8c03fb34880e9d6378d3b0c569.extensions.allizom.org/,https://hpanifeankiobmgbemnhjmhpjeebdhdd.chromiumapp.org/ \
  --public -n
```

У налаштуваннях розширення: ту саму адресу `https://time.tailXXXX.ts.net` і новий Client ID.

## 6. Телефон

Окремої програми не потрібно: відкрий `https://time.tailXXXX.ts.net` у браузері телефона
з увімкненим Tailscale і додай на головний екран.

## 7. Бекап

```bash
echo '10 4 * * * root /srv/apps/solidtime/backup.sh >> /var/log/solidtime-backup.log 2>&1' \
  | sudo tee /etc/cron.d/solidtime-backup
sudo chmod 644 /etc/cron.d/solidtime-backup
/srv/apps/solidtime/backup.sh              # перша копія вручну, перевірка що все працює
```

Потрібна microSD під бекапи — [docs/backups.md](../../docs/backups.md). В архів іде і `.env`:
без `APP_KEY` і ключів Passport відновлена база не відкриється.

## Коли сервер недоступний

Таймер зберігається на сервері, програма на ПК **нічого не кешує на диск**.

| Ситуація | Що буде |
|---|---|
| Таймер уже йде, сервер упав / перезавантажився | нічого не втрачається: час старту в базі, **Stop** після повернення сервера |
| **Stop**, поки сервер недоступний | помилка, таймер не зупиниться — натисни ще раз пізніше й підправ час кінця |
| **Start**, поки сервер недоступний | запис не збережеться — запам'ятай час і додай вручну потім |
| Зникло світло | контейнери піднімуться самі, запущений таймер лишиться запущеним |

## Файли

| Файл | Призначення |
|---|---|
| `docker-compose.yml` | застосунок (`127.0.0.1:8000`), планувальник, черга, PostgreSQL, Gotenberg (PDF) |
| `.env.example` | зразок конфігурації; справжній `.env` у git не потрапляє |
| `backup.sh` | `pg_dump` бази + `data` + `.env` на microSD |
