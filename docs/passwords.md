# Менеджер паролів (Vaultwarden)

Vaultwarden — сервер, сумісний з Bitwarden. Працюють офіційні застосунки Bitwarden для браузера,
Windows, Android і iOS, а сховище лежить на твоєму Pi. Це заміна 1Password або хмарного Bitwarden.

**Доступ тільки через Tailscale.** У публічний інтернет сховище не виставляється:

```
Телефон / ноутбук  ──Tailscale (P2P, шифровано)──▶  vault.tailXXXX.ts.net  ──▶  127.0.0.1:8080  ──▶  Vaultwarden
```

Контейнер слухає лише `127.0.0.1`, тому з локальної мережі його теж не видно — тільки через
Tailscale, який сам видає справжній HTTPS-сертифікат.

## 1. Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
sudo ufw allow in on tailscale0 comment 'Tailscale'
```

`tailscale up` покаже посилання — відкрий його і увійди. Далі в адмінці:

- https://login.tailscale.com/admin/machines → твій сервер → `...` → **Disable key expiry**
  (інакше через 6 місяців сервер відпаде від мережі);
- https://login.tailscale.com/admin/dns → увімкни **MagicDNS** і **HTTPS Certificates**.

Постав Tailscale на ноутбук і телефон, увійди тим самим акаунтом. Адресу сервера покаже
`tailscale status` — вона має вигляд `server.tailXXXXXX.ts.net`. Сервіси отримують власні
імена (`vault.…`, `links.…`), див. крок 2.

## 2. Запуск

```bash
mkdir -p /srv/apps
cp -r /opt/pi-server/apps/vaultwarden /srv/apps/vaultwarden
cd /srv/apps/vaultwarden
```

Згенеруй пароль і хеш для панелі адміністратора:

```bash
openssl rand -base64 30                                    # пароль, збережи
docker run --rm -it vaultwarden/server /vaultwarden hash    # встав пароль двічі
```

Створи `.env`:

```bash
printf 'DOMAIN=https://vault.tailXXXXXX.ts.net\n' > .env
read -rsp 'Встав хеш: ' H; echo; printf 'ADMIN_TOKEN=%s\n' "${H//\$/\$\$}" >> .env
```

**Долари в хеші подвоюються** — інакше docker compose сприйме `$` як початок змінної і зіпсує
його. Команда вище робить це сама. Перевірка (має бути один `$`):

```bash
docker exec vaultwarden printenv ADMIN_TOKEN | head -c 12; echo
```

Перший запуск — з тимчасово дозволеною реєстрацією:

```bash
SIGNUPS_ALLOWED=true docker compose up -d
```

Далі публікація через Tailscale. Найчистіше — власне ім'я `vault.tailXXXX.ts.net` через
**Tailscale Services** (вузол має бути тегованим, підготовка описана в
[docs/bookmarks.md](bookmarks.md#2-публікація-через-tailscale-services)):

```bash
sudo tailscale serve --service=svc:vault --bg 8080
tailscale serve status
```

Потім в адмінці: Services → `vault` → **Hosts** → **Approve**. Без підтвердження адреса
резолвиться, але з'єднання відвалюється по таймауту.

Без сервісів працює і коренева адреса самого сервера:

```bash
sudo tailscale serve --bg 8080
```

## 3. Акаунт

Відкрий свою Tailscale-адресу в браузері → **Create account**.

- **Головний пароль не відновлюється.** Ним зашифроване все сховище: ні розробники, ні панель
  адміністратора не можуть його скинути. Роби з 5–6 випадкових слів і **запиши на папері**.
- Одразу увімкни 2FA: Settings → Security → Two-step Login. Коди відновлення теж на папір.

Потім **закрий реєстрацію**:

```bash
docker compose up -d --force-recreate
password-status        # рядок «Реєстрація» має бути «закрита»
```

## 4. Клієнти

У застосунку Bitwarden **перед входом** відкрий вибір сервера (шестерня або список регіонів),
вибери **Self-hosted** і вкажи `https://vault.tailXXXX.ts.net`. Лише потім вводь пошту й пароль.
Кнопка «Єдиний вхід / SSO» тут не потрібна — це корпоративна функція.

Поза домом на телефоні має бути увімкнений Tailscale.

## 5. Бекапи

Сам по собі головний пароль нічого не відновлює: дані живуть у `data/db.sqlite3`. Потрібні
**обидві** частини — архів і пароль. Налаштування: [docs/backups.md](backups.md).

Додатково раз на кілька місяців роби експорт: Tools → Export vault → **.json (Encrypted)**,
з окремим паролем, і зберігай файл поза домом.

## 6. Обслуговування

```bash
password-status                                # стан
cd /srv/apps/vaultwarden
docker compose logs -f                         # логи
docker compose pull && docker compose up -d    # оновлення (або server-update)
```

Контейнер піднімається сам після перезавантаження (`restart: unless-stopped`), конфігурація
`tailscale serve` теж зберігається.

## Чому саме так

| Рішення | Причина |
|---|---|
| порт `127.0.0.1:8080`, а не `8080` | опубліковані порти Docker обходять UFW |
| Tailscale, а не Cloudflare Tunnel | сховище паролів не має бути доступним з інтернету |
| `SIGNUPS_ALLOWED=false` | інакше будь-хто, хто дістанеться адреси, створить акаунт |
| окреме ім'я `vault.…`, а не порт | адресу легше запам'ятати, і кожен сервіс ізольований |
| `ADMIN_TOKEN` як argon2-хеш | у `.env` і логах немає пароля у відкритому вигляді |
| бекап через `sqlite3 .backup` | копія файлу бази «наживо» дає пошкоджений архів |
