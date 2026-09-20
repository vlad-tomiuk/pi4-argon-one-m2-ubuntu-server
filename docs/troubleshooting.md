# Діагностика

Перша команда завжди одна:

```bash
sudo server-status
```

Червоні рядки містять підказку, що робити далі.

## Встановлення

**Скрипт не бачить SSD.** Перевір U-подібну USB-перемичку в корпусі Argon і живлення, потім
`lsblk`. Диск має бути видимий як `sda`.

**Після перезавантаження Pi стартує зі старої системи.** EEPROM не оновився. Перевір
`vcgencmd bootloader_config | grep BOOT_ORDER` — має бути `0xf14`.

**Минуло 20 хвилин, а сервер не налаштований.** Дивись лог:

```bash
sudo tail -50 /var/log/pi-setup.log
systemctl status pi-setup.service
```

Найчастіша причина — не було інтернету при першому старті, тому не вдалося клонувати
репозиторій. Сервіс спробує знову при наступному завантаженні; можна й вручну:

```bash
sudo bash /opt/pi-setup/bootstrap.sh
```

**Налаштування не запускалось узагалі** (`/var/log/pi-setup.log` не існує). Перевір, що
сервіс увімкнений:

```bash
systemctl is-enabled pi-setup.service
sudo systemctl start pi-setup.service
```

## Мережа й доступ

**`server.local` не відкривається з Windows.** У Windows мережа має профіль **Public**, де
блокується mDNS. Варіанти: перемкнути профіль на Private
(`Set-NetConnectionProfile -InterfaceAlias Ethernet -NetworkCategory Private` від адміністратора),
звертатись на ім'я `server` (його видає DNS роутера) або на IP.

**Не пускає по SSH.** Пароль приймається лише з локальної мережі — це навмисно. Ззовні потрібен
ключ або Tailscale. Якщо забанив себе невдалими спробами:

```bash
sudo fail2ban-client set sshd unbanip ТВІЙ_IP
```

**Забув пароль користувача.** Встав microSD у комп'ютер, у файлі `user-data` на розділі
`system-boot` заміни хеш пароля (`openssl passwd -6`), або відновлюй систему з нуля.

## Мережевий диск

```bash
sudo disk-status
```

| Симптом | Причина / дія |
|---|---|
| `System error 53` у Windows | ім'я не резолвиться — пробуй IP |
| `System error 1326` | хибний пароль: `sudo smbpasswd -a vlad`, потім `cmdkey /delete:server` |
| «Відмовлено в доступі» до файлів | `ls -ld /srv/share` — власником має бути твій користувач |
| Папка порожня, хоча файли були | образ не змонтований: `findmnt /srv/share`, `sudo mount -a` |
| Диск із червоним хрестиком | у PowerShell: `InitDisk` |
| Samba не стартує | `sudo systemctl status smbd`, `testparm -s` |

## Менеджер паролів

```bash
password-status
```

| Симптом | Причина / дія |
|---|---|
| Контейнер не запущений | `cd /srv/apps/vaultwarden && docker compose up -d` |
| Локально не відповідає | `docker compose logs --tail 50` |
| HTTPS ззовні не працює | `tailscale serve status`; перевір, що в адмінці увімкнені MagicDNS і HTTPS Certificates |
| Помилка сертифіката в браузері | Tailscale вимкнений на цьому пристрої |
| `ADMIN_TOKEN` не приймається | долари в `.env` мають бути подвоєні: `docker exec vaultwarden printenv ADMIN_TOKEN` має показати один `$` |
| Застосунок не бачить сховище | у Bitwarden не вказаний Self-hosted Server URL |

## Перегрів і живлення

```bash
vcgencmd measure_temp
vcgencmd get_throttled        # 0x0 — все добре
argon-fan-test
```

Значення, відмінне від `0x0`, означає просідання живлення або перегрів. Слабкий блок живлення
дає випадкові зависання й пошкодження файлової системи — це найчастіша апаратна проблема Pi.

Вентилятор не крутиться:

```bash
sudo i2cdetect -y 1           # має бути пристрій 1a
systemctl status argononed argon-fan argon-check
sudo systemctl enable --now argon-fan    # примусово увімкнути запасний драйвер
```

## Диск заповнився

```bash
df -h
sudo du -xh --max-depth=2 / 2>/dev/null | sort -rh | head -20
docker system df
docker system prune -a        # обережно: видалить невикористані образи
sudo journalctl --vacuum-size=200M
```

## Сервер не відповідає взагалі

1. Перевір живлення і чи світиться індикатор.
2. Знайди IP: `ping server`, або подивись у роутері, або `arp -a` на ПК.
3. Якщо система зависла, через 15 секунд її має перезавантажити watchdog.
4. Якщо не допомагає — вимкни живлення, зачекай 10 секунд, увімкни. Після старту:

```bash
journalctl -b -1 -p err       # помилки попереднього завантаження
sudo dmesg | tail -50
```

## Відкотити все і почати спочатку

Записуєш microSD з Raspberry Pi OS Lite, вставляєш у Pi (він завантажиться з карти, якщо
тримати SSD відключеним або скористатись пріоритетом завантаження) і повторюєш встановлення.
Дані з `/srv` перед цим скопіюй — установка стирає SSD повністю.
