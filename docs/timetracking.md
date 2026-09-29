# Трекер часу (solidtime)

Власний трекер часу замість Time Doctor / Toggl, без скриншотів. Клієнти, проєкти, задачі,
таймер у браузері і в програмі для Windows, звіти й експорт у CSV/PDF. Доступ лише через Tailscale.

```
https://vault.tailXXXX.ts.net   →  Vaultwarden (паролі)
https://links.tailXXXX.ts.net   →  Linkwarden (закладки)
https://time.tailXXXX.ts.net    →  solidtime (трекер часу)
```

**Безкоштовно.** У версії для власного сервера відкриті всі функції хмарного тарифу
Professional: оцінки часу на проєкти й задачі, округлення, PDF-звіти. Платне лише виставлення
рахунків (invoicing).

## Ресурси

П'ять контейнерів з одного compose: застосунок, планувальник, черга (усі з одного образу),
PostgreSQL і Gotenberg (Chromium для PDF-звітів). Разом приблизно 0.8–1.3 ГБ пам'яті.
Gotenberg — найважчий, і потрібен лише для PDF; без нього працює все інше.

## 1. Запуск

На сервері спершу підтягни свіжий репозиторій і команди:

```bash
server-update --self
```

```bash
mkdir -p /srv/apps/solidtime
cp -r /opt/pi-server/apps/solidtime/. /srv/apps/solidtime/
cd /srv/apps/solidtime
chmod +x backup.sh
mkdir -p data && sudo chown -R 1000:1000 data    # контейнер працює під uid 1000
```

Створи `.env`:

```bash
openssl rand -base64 24     # DB_PASSWORD
cp .env.example .env
nano .env
```

| Змінна | Значення |
|---|---|
| `APP_URL` | `https://time.tailXXXX.ts.net` — рівно та адреса, яку відкриватимеш, без `/` у кінці |
| `DB_PASSWORD` | згенерований рядок; якщо в ньому трапились `$` або `'`, перегенеруй |
| `SUPER_ADMINS` | твій email, якщо потрібна адмін-панель `/admin`; можна лишити порожнім |

Завантаж образи (близько 2 ГБ, на Pi це кілька хвилин) і згенеруй ключі:

```bash
docker compose pull
docker compose run --rm --no-deps -T scheduler php artisan self-host:generate-keys >> .env
tail -c 200 .env            # в кінці мають бути APP_KEY, PASSPORT_PRIVATE_KEY, PASSPORT_PUBLIC_KEY
```

Команду генерації запускай **один раз**: повторний запуск допише другий комплект ключів.
Якщо так сталося — видали зайві рядки в `nano .env`.

```bash
docker compose up -d
docker compose logs -f solidtime     # чекаємо, поки стихнуть міграції, вихід Ctrl+C
```

## 2. Публікація через Tailscale Services

Хост уже тегований, якщо ти налаштовував Linkwarden ([docs/bookmarks.md](bookmarks.md#2-публікація-через-tailscale-services)).

В адмінці (https://login.tailscale.com/admin/services → **Add service**) створи сервіс
`time`, порт `443`. Потім на сервері:

```bash
sudo tailscale serve --service=svc:time --bg 8000
tailscale serve status
```

В адмінці: сервіс `time` → **Hosts** → біля сервера **Approve**.

```bash
timetracker-status
```

## 3. Акаунт

Реєстрація вимкнена повністю, акаунт створюється командою:

```bash
cd /srv/apps/solidtime
docker compose exec scheduler php artisan admin:user:create "Ім'я Прізвище" "you@example.com" \
  --ask-for-password --verify-email
```

Пароль згенеруй і поклади у Vaultwarden. Відкрий `https://time.tailXXXX.ts.net` і увійди.

Одразу в профілі (аватар → **Profile**):

- **Timezone** → `Europe/Kyiv` (за замовчуванням UTC, і записи зсунуться на 2–3 години);
- **Week start** → понеділок.

## 4. Програма для Windows

Спершу створи для неї OAuth-клієнт на сервері:

```bash
docker compose exec scheduler php artisan passport:client \
  --name=desktop --redirect_uri=solidtime://oauth/callback --public -n
```

Команда виведе **Client ID** — скопіюй його.

Завантаж інсталятор для Windows з
https://github.com/solidtime-io/solidtime-desktop/releases. При першому запуску натисни
**Instance Settings**:

- **API URL:** `https://time.tailXXXX.ts.net`
- **Client ID:** рядок з попередньої команди

Далі **Log in** — відкриється браузер, входиш і повертаєшся в програму. Таймер живе в треї.

Працює лише з увімкненим Tailscale на ПК.

## 5. Як організувати дві компанії

- **Clients** — по одному на компанію: `Компанія A`, `Компанія B`.
- **Projects** — у кожного клієнта, наприклад `Підтримка`. Для проєкту можна задати
  **Estimated time**. Це загальна оцінка, а не місячна, тому для ліміту «80 год на місяць»
  зручніше дивитись `timetracker-status`: він показує години кожного клієнта за поточний місяць
  зі шкалою до 80.
- **Tasks** — усередині проєкту, по одній на тікет чи роботу: `#1234 Не працює експорт`.
  Виконану задачу познач **Done**: вона зникне з вибору, але години лишаться у звітах.
- **Billable** і **ставка** — на рівні проєкту, якщо оплата погодинна.
- **Звіти:** Reporting → групування за клієнтом / проєктом / задачею, експорт CSV або PDF.

Інший ліміт, ніж 80: `HOURS_LIMIT=100 timetracker-status`.

## 6. Бекапи

Головне — база PostgreSQL, і обов'язково `.env`: без `APP_KEY` і ключів Passport відновлена
база не відкриється. [apps/solidtime/backup.sh](../apps/solidtime/backup.sh) пакує все разом.

```bash
/srv/apps/solidtime/backup.sh
echo '10 4 * * * root /srv/apps/solidtime/backup.sh >> /var/log/solidtime-backup.log 2>&1' \
  | sudo tee /etc/cron.d/solidtime-backup
sudo chmod 644 /etc/cron.d/solidtime-backup
```

О 4:10, після Vaultwarden (3:30) і Linkwarden (3:50). Потрібна налаштована microSD —
[docs/backups.md](backups.md).

**Відновлення:**

```bash
cd /srv/apps/solidtime
docker compose down
tar -xzf /srv/backup/solidtime/solidtime-2026-09-30_0410.tar.gz -C .   # data, db.sql, .env, compose
sudo chown -R 1000:1000 data
docker compose up -d postgres
sleep 15
docker exec -i solidtime-db psql -U solidtime solidtime < db.sql
docker compose up -d
rm -f db.sql
```

## 7. Обслуговування

```bash
timetracker-status
cd /srv/apps/solidtime
docker compose logs -f solidtime
docker compose pull && docker compose up -d     # або server-update
```

Міграції бази після оновлення виконуються самі (`AUTO_DB_MIGRATE` у compose).

## Якщо щось не працює

| Симптом | Причина / дія |
|---|---|
| Сторінка без стилів або редірект на `http://` | `APP_URL` не збігається з адресою в браузері; виправ і `docker compose up -d` |
| 500 одразу після старту, в логах `No application encryption key` | ключі не дописались у `.env` — повтори генерацію з кроку 1 |
| Контейнер перезапускається по колу | база ще не піднялась або невірний `DB_PASSWORD`: `docker compose logs postgres` |
| `Permission denied` на `storage/app` | `sudo chown -R 1000:1000 /srv/apps/solidtime/data` |
| Програма для ПК не входить | неправильний Client ID або API URL; клієнт створюється командою з кроку 4 |
| Записи зсунуті на кілька годин | у профілі не виставлена `Europe/Kyiv` |
| Експорт у PDF падає | не запущений `solidtime-gotenberg`: `docker compose up -d gotenberg` |
| Забув пароль | листів немає (`MAIL_MAILER=log`), тож створи тимчасовий: `docker compose exec scheduler php artisan tinker`, далі `App\Models\User::where('email','you@example.com')->first()->forceFill(['password'=>Hash::make('новий')])->save();` |
| Адреса не відкривається, таймаут | хост сервісу не підтверджений: адмінка → Services → `time` → Hosts → **Approve** |
