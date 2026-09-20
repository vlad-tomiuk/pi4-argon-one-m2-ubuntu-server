# Закладки (Linkwarden)

Власний менеджер закладок: колекції, теги, пошук і — головне — **автоматичне збереження копії
сторінки** (скриншот, PDF, читабельний текст). Закладка залишиться робочою, навіть якщо сайт
зникне. Є розширення для Chrome і Firefox та мобільний доступ через браузер.

Доступ, як і в менеджера паролів, лише через Tailscale.

```
https://vault.tailXXXX.ts.net   →  Vaultwarden (паролі)
https://links.tailXXXX.ts.net   →  Linkwarden (закладки)
```

Кожен сервіс отримує власне ім'я через **Tailscale Services** — окремі адреси без портів
і без підшляхів. Підшлях (`/links`) тут не варіант: Linkwarden на Next.js і з префіксом
у шляху не працює.

## Ресурси

Два контейнери: сам застосунок і PostgreSQL. Разом близько 1–1.5 ГБ пам'яті — при 8 ГБ на Pi це
прийнятно, але помітно більше за Vaultwarden (16 МБ). Найбільше з'їдає вбудований headless Chrome,
який рендерить сторінки при збереженні — він працює короткими сплесками.

Якщо колись знадобиться щось значно легше, альтернатива — [linkding](https://linkding.link)
(один контейнер, ~100 МБ, SQLite), але без архівування сторінок і з простішим інтерфейсом.

## 1. Запуск

```bash
mkdir -p /srv/apps/linkwarden
cp -r /opt/pi-server/apps/linkwarden/. /srv/apps/linkwarden/
cd /srv/apps/linkwarden
chmod +x backup.sh
```

Згенеруй два секрети:

```bash
openssl rand -base64 32     # NEXTAUTH_SECRET
openssl rand -base64 24     # POSTGRES_PASSWORD
```

Створи `.env`:

```bash
cp .env.example .env
nano .env
```

| Змінна | Значення |
|---|---|
| `NEXTAUTH_URL` | `https://links.tailXXXX.ts.net/api/v1/auth` — рівно та адреса, яку відкриватимеш, з `/api/v1/auth` у кінці |
| `NEXTAUTH_SECRET` | перший згенерований рядок |
| `POSTGRES_PASSWORD` | другий; якщо в ньому трапились `$` або `'`, перегенеруй |
| `NEXT_PUBLIC_DISABLE_REGISTRATION` | поки `false` — зміниш після створення акаунта |

```bash
docker compose up -d
docker compose logs -f linkwarden     # чекаємо "ready", вихід Ctrl+C
```

Перший запуск довгий: тягнуться образи (близько 1.5 ГБ) і застосовуються міграції бази.

## 2. Публікація через Tailscale Services

Потрібен Tailscale 1.86+. Одноразова підготовка — хост має бути **тегованим вузлом**,
інакше `serve --service` відмовиться працювати з помилкою `service hosts must be tagged nodes`.

У політиці доступу (https://login.tailscale.com/admin/acls/file) розкоментуй `tagOwners`:

```json
	"tagOwners": {
		"tag:server": ["autogroup:admin"],
	},
```

Далі на сервері — заходь по **локальній** адресі, бо з'єднання через Tailscale на мить обірветься:

```bash
sudo tailscale up --advertise-tags=tag:server     # відкрий посилання і підтвердь
```

Створи сервіс в адмінці (https://login.tailscale.com/admin/services → **Add service**):
ім'я `links`, порт `443`. Потім:

```bash
sudo tailscale serve --service=svc:links --bg 3000
tailscale serve status
```

В адмінці: сервіс `links` → **Hosts** → біля свого сервера натисни **Approve**.
Без цього ім'я резолвиться, але трафік не йде — саме так виглядає таймаут при перевірці.

```bash
bookmarks-status
```

**Простіша альтернатива без тегів і сервісів:** віддати Linkwarden кореневу адресу
(`sudo tailscale serve --bg 3000`), а Vaultwarden перевести на підшлях `/vault` — він це вміє.

## 3. Акаунт

Відкрий `https://links.tailXXXX.ts.net`, натисни **Sign Up** і створи акаунт.
Пароль згенеруй і поклади у Vaultwarden.

Одразу після цього закрий реєстрацію:

```bash
cd /srv/apps/linkwarden
sed -i 's/^NEXT_PUBLIC_DISABLE_REGISTRATION=.*/NEXT_PUBLIC_DISABLE_REGISTRATION=true/' .env
docker compose up -d
bookmarks-status          # рядок «Реєстрація» має стати «закрита»
```

## 4. Розширення для Chrome

Офіційне: [Linkwarden у Chrome Web Store](https://chromewebstore.google.com/detail/linkwarden/pnidmkljnhbjfffciajlcpeldoljnidn)
(у магазині є ще «Unofficial Linkwarden» — не те).

У налаштуваннях розширення вкажи:

- **Instance URL:** `https://links.tailXXXX.ts.net`
- вхід за логіном і паролем або за **API-ключем** (Settings → Access Tokens)

Уміє зберігати поточну сторінку з вибором колекції й тегів, зберігати **всі відкриті вкладки**
одним натисканням і робити скриншот.

Працює лише з увімкненим Tailscale — інакше браузер не достукається до сервера.

## 5. Як користуватись

- **Колекції** — великі теми: `Робота`, `Відпочинок`, `Інструменти`. Можна вкладати одна в одну.
- **Теги** — наскрізні мітки поверх колекцій: `почитати`, `python`, `рецепт`.
- **Архівування** вмикається в налаштуваннях колекції: скриншот, PDF, текст статті. Це те, заради
  чого варто терпіти його апетит до пам'яті.
- **Імпорт:** Settings → Import → файл закладок HTML з браузера (Chrome: Менеджер закладок → ⋮ →
  Експорт). Папки стануть колекціями.
- **Експорт:** Settings → Export — JSON з усіма посиланнями. Роби раз на кілька місяців.

## 6. Бекапи

Тут дві різні речі, і потрібні обидві: база PostgreSQL (посилання, теги, колекції) і папка
`data` (скриншоти й PDF). [apps/linkwarden/backup.sh](../apps/linkwarden/backup.sh) робить
`pg_dump` і пакує все разом.

```bash
/srv/apps/linkwarden/backup.sh
echo '50 3 * * * root /srv/apps/linkwarden/backup.sh >> /var/log/linkwarden-backup.log 2>&1' \
  | sudo tee /etc/cron.d/linkwarden-backup
sudo chmod 644 /etc/cron.d/linkwarden-backup
```

О 3:50, щоб не збігалося з бекапом Vaultwarden о 3:30. Потрібна налаштована microSD —
[docs/backups.md](backups.md).

**Увага до розміру:** архіви сторінок ростуть швидко, кожна збережена сторінка — це скриншот
плюс PDF. Стеж за рядком «Архіви сторінок» у `bookmarks-status`.

**Відновлення:**

```bash
cd /srv/apps/linkwarden
docker compose down
rm -rf data && mkdir data
tar -xzf /srv/backup/linkwarden/linkwarden-2026-09-20_0350.tar.gz -C .
docker compose up -d postgres
sleep 15
docker exec -i linkwarden-db psql -U postgres postgres < db.sql
docker compose up -d
rm -f db.sql
```

## 7. Обслуговування

```bash
bookmarks-status
cd /srv/apps/linkwarden
docker compose logs -f linkwarden
docker compose pull && docker compose up -d     # або server-update
```

## Якщо щось не працює

| Симптом | Причина / дія |
|---|---|
| Після входу викидає назад на сторінку логіну | `NEXTAUTH_URL` не збігається з адресою в браузері (порт, https, `/api/v1/auth`) |
| «Configuration error» на старті | не заданий `NEXTAUTH_SECRET` |
| Контейнер перезапускається по колу | база ще не піднялась або невірний `POSTGRES_PASSWORD`: `docker compose logs postgres` |
| Сторінки зберігаються без скриншотів | Chrome усередині контейнера не встиг: спробуй ще раз, дивись логи |
| Адреса не відкривається, таймаут | хост сервісу не підтверджений: адмінка → Services → `links` → Hosts → **Approve** |
| `service hosts must be tagged nodes` | вузол не тегований: `sudo tailscale up --advertise-tags=tag:server` |
| Повільно при збереженні | нормально для Pi: рендер сторінки займає кілька секунд |
