#!/usr/bin/env bash
# =====================================================================
#  pi4-argon-one-m2-ubuntu-server / install.sh
#  Raspberry Pi 4 + Argon ONE M.2  →  Ubuntu Server 24.04 LTS на SSD
#
#  Що робить:
#   1. Знаходить SSD, повністю стирає і записує Ubuntu Server
#   2. Створює твого користувача, hostname, часовий пояс
#   3. Wi-Fi: сканує мережі, даєш вибрати зі списку і ввести пароль
#   4. Безпека: UFW, fail2ban, жорсткий SSH, автооновлення безпеки
#   5. Автовідновлення: watchdog, reboot при kernel panic, fsck, журнал
#   6. Docker + Docker Compose
#   7. Вентилятор Argon ONE: офіційний драйвер + запасний, якщо офіційний не працює
#
#  Репозиторій: https://github.com/vlad-tomiuk/pi4-argon-one-m2-ubuntu-server
#
#  Запуск (з Raspberry Pi OS на microSD):
#     curl -fsSL https://raw.githubusercontent.com/vlad-tomiuk/pi4-argon-one-m2-ubuntu-server/main/install.sh -o install.sh
#     sudo bash install.sh                  # усе спитає сам
#     sudo bash install.sh --help           # параметри
# =====================================================================
set -euo pipefail

UBUNTU_VER=24.04
BASE_URL="https://cdimage.ubuntu.com/releases/${UBUNTU_VER}/release"
WORKDIR=/root/ubuntu-img
MIN_SIZE_GB=8

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; B='\033[1m'; NC='\033[0m'
log(){  echo -e "${G}[+] $1${NC}"; }
warn(){ echo -e "${Y}[!] $1${NC}"; }
die(){  echo -e "${R}[x] $1${NC}"; exit 1; }
yes_no(){ local a; read -rp "$1 [$( [ "$2" = y ] && echo Y/n || echo y/N )]: " a; a=${a:-$2}; [[ "$a" =~ ^[yYтТ] ]]; }

usage(){ cat << 'HELP'
Використання: sudo bash install.sh [параметри]

  -n, --hostname NAME     Ім'я сервера (hostname)
  -u, --user NAME         Ім'я користувача
  -w, --wifi SSID         Назва Wi-Fi мережі (без цього покаже список мереж)
      --no-wifi           Тільки кабель, Wi-Fi не питати
  -c, --country CODE      Країна для Wi-Fi (за замовчуванням UA)
  -t, --timezone TZ       Часовий пояс (за замовчуванням Europe/Kyiv)
      --lan CIDR          Мережа, з якої дозволено SSH (визначається сама)
      --no-docker         Не ставити Docker
      --no-argon          Не ставити драйвер вентилятора Argon
  -h, --help              Ця довідка

Паролі НЕ передаються параметрами (їх видно в історії команд і в списку процесів).
Скрипт спитає їх сам. Для повної автоматизації можна через змінні середовища:
  sudo SSH_PASSWORD='...' WIFI_PASSWORD='...' bash install.sh -n myserver -u me -w MyWiFi

Приклад:
  sudo bash install.sh -n pi-server -u vlad
HELP
}

# ---------------------------------------------------------------------
# Параметри
# ---------------------------------------------------------------------
HOST=""; NEW_USER=""; WIFI_SSID=""; NO_WIFI=no; COUNTRY="UA"; TZONE="Europe/Kyiv"
LAN_CIDR=""; INSTALL_DOCKER=yes; INSTALL_ARGON=yes
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--hostname) HOST="${2:?}"; shift 2 ;;
    -u|--user)     NEW_USER="${2:?}"; shift 2 ;;
    -w|--wifi)     WIFI_SSID="${2:?}"; shift 2 ;;
    --no-wifi)     NO_WIFI=yes; shift ;;
    -c|--country)  COUNTRY="${2:?}"; shift 2 ;;
    -t|--timezone) TZONE="${2:?}"; shift 2 ;;
    --lan)         LAN_CIDR="${2:?}"; shift 2 ;;
    --no-docker)   INSTALL_DOCKER=no; shift ;;
    --no-argon)    INSTALL_ARGON=no; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) usage; die "Невідомий параметр: $1" ;;
  esac
done

# Щоб питання працювали і при запуску через "curl ... | sudo bash"
[ -t 0 ] || exec < /dev/tty
[ "$EUID" -eq 0 ] || die "Запусти через sudo: sudo bash install.sh"

# ---------------------------------------------------------------------
# 0. Утиліти
# ---------------------------------------------------------------------
log "Перевіряю утиліти..."
for c in curl xzcat openssl partprobe wipefs blkdiscard; do
  if ! command -v "$c" >/dev/null; then
    apt-get update -qq
    apt-get install -y -qq curl xz-utils openssl parted util-linux
    break
  fi
done

# ---------------------------------------------------------------------
# 1. Пошук SSD
# ---------------------------------------------------------------------
ROOT_SRC=$(findmnt -no SOURCE /)
ROOT_DISK="/dev/$(lsblk -no PKNAME "$ROOT_SRC" | head -1)"
[[ "$ROOT_DISK" == /dev/mmcblk* ]] || die "Система має працювати з microSD, зараз корінь на: $ROOT_DISK"

mapfile -t CANDIDATES < <(
  lsblk -dnpbo NAME,TYPE,SIZE | awk -v r="$ROOT_DISK" -v min=$((MIN_SIZE_GB*1024*1024*1024)) \
    '$2=="disk" && $1!=r && $1 !~ /(mmcblk|loop|zram|ram)/ && $3>=min {print $1}'
)
case ${#CANDIDATES[@]} in
  0) die "SSD не знайдено. Перевір U-подібну USB-перемичку Argon і живлення, потім lsblk" ;;
  1) DISK="${CANDIDATES[0]}" ;;
  *) warn "Знайдено кілька дисків:"
     lsblk -dpo NAME,SIZE,MODEL,TRAN "${CANDIDATES[@]}"
     select d in "${CANDIDATES[@]}"; do [ -n "${d:-}" ] && DISK="$d" && break; done ;;
esac
log "Цільовий диск: $DISK"
lsblk -po NAME,SIZE,MODEL,TRAN,FSTYPE,LABEL,MOUNTPOINTS "$DISK"
echo

# ---------------------------------------------------------------------
# 2. Сервер і користувач
# ---------------------------------------------------------------------
echo -e "${B}--- Сервер і користувач ---${NC}"
while ! [[ "$HOST" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; do
  [ -n "$HOST" ] && warn "Некоректне ім'я сервера: $HOST (латиниця, цифри, дефіс)"
  read -rp "Ім'я сервера (hostname) [pi-server]: " HOST; HOST=${HOST:-pi-server}
done
while ! [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || [ "$NEW_USER" = "root" ]; do
  [ -n "$NEW_USER" ] && warn "Некоректне ім'я користувача: $NEW_USER"
  read -rp "Ім'я користувача (латиниця, малі літери): " NEW_USER
done
if [ -n "${SSH_PASSWORD:-}" ]; then
  [ "${#SSH_PASSWORD}" -ge 10 ] || die "SSH_PASSWORD коротший за 10 символів"
  P1="$SSH_PASSWORD"
else
  while true; do
    read -rsp "Пароль для $NEW_USER (мін. 10 символів): " P1; echo
    read -rsp "Повтори: " P2; echo
    [ "$P1" = "$P2" ] && [ "${#P1}" -ge 10 ] && break
    warn "Паролі не збігаються або коротші за 10 символів"
  done
fi
PASS_HASH=$(openssl passwd -6 "$P1"); unset P1 P2 SSH_PASSWORD
[ -f "/usr/share/zoneinfo/$TZONE" ] || die "Невідомий часовий пояс: $TZONE"

# ---------------------------------------------------------------------
# 3. Мережа і Wi-Fi
# ---------------------------------------------------------------------
echo -e "\n${B}--- Мережа ---${NC}"
if [ -z "$LAN_CIDR" ]; then
  DETECTED_LAN=$(ip -4 route | awk '/proto kernel/ && /scope link/ && !/docker/ {print $1; exit}')
  read -rp "Локальна мережа, з якої дозволено SSH [${DETECTED_LAN}]: " LAN_CIDR
  LAN_CIDR=${LAN_CIDR:-$DETECTED_LAN}
fi
[[ "$LAN_CIDR" =~ ^[0-9.]+/[0-9]+$ ]] || die "Некоректна мережа: $LAN_CIDR"

scan_wifi(){
  rfkill unblock wifi 2>/dev/null || true
  if command -v nmcli >/dev/null; then
    nmcli -g SIGNAL,SSID dev wifi list --rescan yes 2>/dev/null \
      | awk -F: '$2!="" {sig=$1; sub(/^[^:]*:/,""); gsub(/\\:/,":"); print sig"\t"$0}' \
      | sort -t$'\t' -k1,1nr | awk -F'\t' '!seen[$2]++ {print $2}'
  elif command -v iw >/dev/null; then
    iw dev wlan0 scan 2>/dev/null | sed -n 's/^[[:space:]]*SSID: //p' | awk 'NF && !seen[$0]++'
  fi
}

current_wifi_psk(){  # пароль мережі, до якої Pi підключений зараз (якщо SSID збігається)
  command -v nmcli >/dev/null || return 0
  local con ssid
  con=$(nmcli -t -f NAME,TYPE con show --active 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1; exit}')
  [ -n "$con" ] || return 0
  ssid=$(nmcli -g 802-11-wireless.ssid con show "$con" 2>/dev/null)
  [ "$ssid" = "$1" ] && nmcli -s -g 802-11-wireless-security.psk con show "$con" 2>/dev/null
  return 0
}

if [ "$NO_WIFI" = "no" ] && [ -z "$WIFI_SSID" ]; then
  if yes_no "Підключати сервер до Wi-Fi?" y; then
    log "Сканую Wi-Fi мережі..."
    mapfile -t NETS < <(scan_wifi)
    OPT_MANUAL="[Ввести назву вручну / прихована мережа]"
    OPT_CABLE="[Без Wi-Fi, тільки кабель]"
    if [ ${#NETS[@]} -eq 0 ]; then warn "Мережі не знайдено"; fi
    echo "Обери мережу (найсильніший сигнал зверху):"
    PS3="Номер: "
    select n in "${NETS[@]}" "$OPT_MANUAL" "$OPT_CABLE"; do
      case "${n:-}" in
        "") continue ;;
        "$OPT_MANUAL") read -rp "Назва мережі (SSID): " WIFI_SSID; break ;;
        "$OPT_CABLE")  WIFI_SSID=""; break ;;
        *) WIFI_SSID="$n"; break ;;
      esac
    done
  fi
fi

WIFI_PASS=""
if [ -n "$WIFI_SSID" ]; then
  if [ -n "${WIFI_PASSWORD:-}" ]; then
    [ "${#WIFI_PASSWORD}" -ge 8 ] && [ "${#WIFI_PASSWORD}" -le 63 ] \
      || die "WIFI_PASSWORD має бути від 8 до 63 символів (вимога WPA/WPA2). Зараз: ${#WIFI_PASSWORD}"
    WIFI_PASS="$WIFI_PASSWORD"
  else
    SAVED=$(current_wifi_psk "$WIFI_SSID")
    if [ -n "$SAVED" ] && yes_no "Pi зараз підключений до \"$WIFI_SSID\". Використати збережений пароль?" y; then
      WIFI_PASS="$SAVED"
    else
      while true; do
        read -rsp "Пароль Wi-Fi \"$WIFI_SSID\" (Enter, якщо мережа відкрита): " WIFI_PASS; echo
        [ -z "$WIFI_PASS" ] && break
        [ "${#WIFI_PASS}" -ge 8 ] || { warn "Пароль WPA мінімум 8 символів"; continue; }
        read -rsp "Повтори: " W2; echo
        [ "$WIFI_PASS" = "$W2" ] && break
        warn "Не збігаються"
      done
    fi
  fi
  unset WIFI_PASSWORD SAVED W2
  [[ "$WIFI_SSID$WIFI_PASS" != *'"'* && "$WIFI_SSID$WIFI_PASS" != *'\'* ]] \
    || die "SSID/пароль з символами \" або \\ не підтримуються"
fi

SSH_BLOCK=""
AK="/home/${SUDO_USER:-root}/.ssh/authorized_keys"
if [ -s "$AK" ]; then
  KEYS=$(grep -E '^(ssh-|ecdsa-|sk-)' "$AK" | sed 's/.*/      - "&"/' || true)
  [ -n "$KEYS" ] && SSH_BLOCK=$(printf '    ssh_authorized_keys:\n%s' "$KEYS")
fi

echo
echo -e "${B}================ ПІДСУМОК ================${NC}"
echo "Диск (буде СТЕРТО): $DISK"
echo "Сервер:             $HOST     TZ: $TZONE"
echo "Користувач:         $NEW_USER"
echo "SSH дозволено з:    $LAN_CIDR"
echo "Wi-Fi:              $([ -n "$WIFI_SSID" ] && echo "$WIFI_SSID ($COUNTRY)" || echo "ні, кабель")"
echo "Docker:             $INSTALL_DOCKER"
echo "Вентилятор Argon:   $INSTALL_ARGON"
echo "SSH-ключі:          $([ -n "$SSH_BLOCK" ] && echo "будуть перенесені" || echo "не знайдено")"
echo -e "${B}==========================================${NC}"
read -rp "Все правильно? УСІ дані на $DISK буде знищено. Введи YES: " ok
[ "$ok" = "YES" ] || die "Скасовано"

# ---------------------------------------------------------------------
# 4. Образ Ubuntu (качаємо ДО стирання диска)
# ---------------------------------------------------------------------
log "Шукаю образ Ubuntu ${UBUNTU_VER} Server для Raspberry Pi..."
IMG=$(curl -fsSL "$BASE_URL/" \
  | grep -oE "ubuntu-${UBUNTU_VER}(\.[0-9]+)?-preinstalled-server-arm64\+raspi\.img\.xz" \
  | sort -uV | tail -1)
[ -n "$IMG" ] || die "Не знайшов образ на $BASE_URL"
log "Образ: $IMG"
mkdir -p "$WORKDIR"; cd "$WORKDIR"
[ -f "$IMG" ] || curl -fL -o "$IMG" "$BASE_URL/$IMG"
curl -fsSL -o SHA256SUMS "$BASE_URL/SHA256SUMS"
awk -v f="$IMG" '$2=="*"f || $2==f' SHA256SUMS | sha256sum -c - \
  || die "Контрольна сума не збіглась. Видали $WORKDIR/$IMG і запусти знову"

# ---------------------------------------------------------------------
# 5. EEPROM: спочатку USB (SSD), потім SD
# ---------------------------------------------------------------------
if command -v rpi-eeprom-config >/dev/null; then
  log "Оновлюю EEPROM і ставлю завантаження з USB першим..."
  rpi-eeprom-update -a >/dev/null 2>&1 || warn "rpi-eeprom-update повернув помилку, продовжую"
  CUR_BO=$(rpi-eeprom-config 2>/dev/null | awk -F= '/^BOOT_ORDER=/{print $2}' | tail -1)
  if [ "$CUR_BO" != "0xf14" ]; then
    rpi-eeprom-config > /tmp/bootconf.txt
    sed -i '/^BOOT_ORDER=/d' /tmp/bootconf.txt
    echo "BOOT_ORDER=0xf14" >> /tmp/bootconf.txt
    rpi-eeprom-config --apply /tmp/bootconf.txt >/dev/null
  fi
else
  warn "rpi-eeprom-config не знайдено, пропускаю налаштування EEPROM"
fi

# ---------------------------------------------------------------------
# 6. Повне очищення SSD
# ---------------------------------------------------------------------
log "Відмонтовую і стираю $DISK..."
for p in $(lsblk -lnpo NAME "$DISK" | tail -n +2); do
  swapoff "$p" 2>/dev/null || true
  umount -f "$p" 2>/dev/null || true
done
for p in $(lsblk -lnpo NAME "$DISK" | tail -n +2); do
  wipefs -af "$p" >/dev/null 2>&1 || true
done
wipefs -af "$DISK" >/dev/null
if blkdiscard -f "$DISK" 2>/dev/null; then log "TRIM виконано"; else warn "TRIM не підтримується USB-мостом, затираю службові області"; fi
SECTORS=$(blockdev --getsz "$DISK")
dd if=/dev/zero of="$DISK" bs=1M count=16 conv=fsync status=none
dd if=/dev/zero of="$DISK" bs=512 seek=$((SECTORS - 32768)) count=32768 conv=fsync status=none
partprobe "$DISK" 2>/dev/null || true; udevadm settle; sleep 2
LEFT=$(lsblk -lnpo NAME "$DISK" | tail -n +2 || true)
[ -z "$LEFT" ] || die "Лишились розділи: $LEFT. Перезавантаж Pi і запусти знову"

# ---------------------------------------------------------------------
# 7. Запис Ubuntu
# ---------------------------------------------------------------------
log "Записую Ubuntu на $DISK (кілька хвилин)..."
xzcat "$IMG" | dd of="$DISK" bs=4M status=progress conv=fsync
sync; partprobe "$DISK"; udevadm settle; sleep 3
BOOT_PART=$(lsblk -lnpo NAME "$DISK" | sed -n 2p)
ROOT_PART=$(lsblk -lnpo NAME "$DISK" | sed -n 3p)
[ "$(blkid -s LABEL -o value "$BOOT_PART")" = "system-boot" ] || die "Немає розділу system-boot"
[ "$(blkid -s LABEL -o value "$ROOT_PART")" = "writable" ]    || die "Немає розділу writable"

MB=/mnt/ssd-boot; MR=/mnt/ssd-root
mkdir -p "$MB" "$MR"
mount "$BOOT_PART" "$MB"
mount "$ROOT_PART" "$MR"
trap 'umount "$MB" "$MR" 2>/dev/null || true' EXIT

# ---------------------------------------------------------------------
# 8. cloud-init: користувач, мережа
# ---------------------------------------------------------------------
log "Пишу cloud-init..."
cat > "$MB/user-data" << UD
#cloud-config
hostname: ${HOST}
manage_etc_hosts: true
timezone: ${TZONE}

users:
  - name: ${NEW_USER}
    gecos: ${NEW_USER}
    groups: [sudo, adm]
    shell: /bin/bash
    sudo: "ALL=(ALL) ALL"
    lock_passwd: false
    passwd: "${PASS_HASH}"
${SSH_BLOCK}

ssh_pwauth: true

runcmd:
  - [bash, /opt/pi-setup/bootstrap.sh]
UD

if [ -n "$WIFI_SSID" ]; then
  if [ -n "$WIFI_PASS" ]; then
    AP_BODY=$(printf '        password: "%s"' "$WIFI_PASS")
  else
    AP_BODY='        {}'
  fi
  cat > "$MB/network-config" << NC
version: 2
ethernets:
  eth0:
    dhcp4: true
    optional: true
wifis:
  wlan0:
    dhcp4: true
    optional: true
    regulatory-domain: "${COUNTRY}"
    access-points:
      "${WIFI_SSID}":
${AP_BODY}
NC
  chmod 600 "$MB/network-config" 2>/dev/null || true
fi
unset WIFI_PASS AP_BODY

# ---------------------------------------------------------------------
# 9. Скрипт першого запуску + команди
# ---------------------------------------------------------------------
log "Пишу скрипт першого запуску..."
mkdir -p "$MR/opt/pi-setup" "$MR/usr/local/bin" "$MR/etc/systemd/system"

cat > "$MR/opt/pi-setup/setup.conf" << CONF
SERVER_USER=${NEW_USER}
LAN_CIDR=${LAN_CIDR}
INSTALL_DOCKER=${INSTALL_DOCKER}
INSTALL_ARGON=${INSTALL_ARGON}
CONF

# ---- запасний контролер вентилятора Argon (працює без офіційного драйвера) ----
cat > "$MR/usr/local/bin/argon-fan" << 'FAN'
#!/usr/bin/env python3
# Запасний контролер вентилятора Argon ONE (I2C 0x1a на шині 1).
# Крива: (температура °C, швидкість %). Змінюй тут, потім: sudo systemctl restart argon-fan
CURVE = [(65, 100), (60, 55), (55, 30)]
HYSTERESIS = 3     # °C: знижувати оберти тільки коли стало на 3° холодніше
INTERVAL = 10      # секунд між перевірками

import sys, time, signal
try:
    import smbus
except ImportError:
    sys.exit("Немає python3-smbus: sudo apt install python3-smbus")

ADDR = 0x1a
bus = smbus.SMBus(1)
current = -1

def temp():
    with open("/sys/class/thermal/thermal_zone0/temp") as f:
        return int(f.read()) / 1000

def speed_for(t):
    for threshold, speed in CURVE:
        if t >= threshold:
            return speed
    return 0

def set_speed(s):
    global current
    if s == current:
        return
    try:
        bus.write_byte(ADDR, s)
        current = s
        print(f"fan {s}%", flush=True)
    except OSError as e:
        print(f"I2C error: {e}", flush=True)

signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))

while True:
    t = temp()
    up, down = speed_for(t), speed_for(t + HYSTERESIS)
    if up > current:
        set_speed(up)
    elif down < current:
        set_speed(down)
    time.sleep(INTERVAL)
FAN

cat > "$MR/etc/systemd/system/argon-fan.service" << 'FANSVC'
[Unit]
Description=Argon ONE fan control (fallback)
After=multi-user.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/argon-fan
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
FANSVC

# Перевірка при кожному старті: якщо офіційний драйвер не працює → вмикаємо запасний
cat > "$MR/usr/local/bin/argon-check" << 'CHK'
#!/usr/bin/env bash
sleep 60
if systemctl is-active --quiet argononed 2>/dev/null; then
  systemctl disable --now argon-fan 2>/dev/null || true
  echo "argon-check: офіційний драйвер працює"
else
  systemctl disable --now argononed 2>/dev/null || true
  systemctl enable --now argon-fan
  echo "argon-check: офіційний драйвер не працює, увімкнено запасний argon-fan"
fi
CHK

cat > "$MR/etc/systemd/system/argon-check.service" << 'CHKSVC'
[Unit]
Description=Make sure Argon ONE fan is controlled
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/argon-check

[Install]
WantedBy=multi-user.target
CHKSVC

cat > "$MR/usr/local/bin/argon-fan-test" << 'TEST'
#!/usr/bin/env bash
# Перевірка вентилятора: 100% на 5 секунд, потім повертаємо керування драйверу
[ "$EUID" -eq 0 ] || exec sudo "$0" "$@"
echo "I2C пристрої на шині 1 (має бути 1a):"
i2cdetect -y 1 | grep -E "^10:|1a" || true
systemctl stop argononed argon-fan 2>/dev/null
echo "Вентилятор 100% на 5 секунд..."
python3 -c "import smbus; smbus.SMBus(1).write_byte(0x1a, 100)" && sleep 5
python3 -c "import smbus; smbus.SMBus(1).write_byte(0x1a, 0)"
systemctl start argon-check >/dev/null 2>&1 &
echo "Якщо вентилятор загудів, усе працює. Керування повернеться драйверу за хвилину."
TEST

# ---- bootstrap: виконується ОДИН раз при першому старті Ubuntu ----
cat > "$MR/opt/pi-setup/bootstrap.sh" << 'BOOT'
#!/usr/bin/env bash
set -uo pipefail
exec > >(tee -a /var/log/pi-setup.log) 2>&1
MARK=/opt/pi-setup/.done
[ -f "$MARK" ] && { echo "Налаштування вже виконано"; exit 0; }
# shellcheck disable=SC1091
source /opt/pi-setup/setup.conf
export DEBIAN_FRONTEND=noninteractive
APT="apt-get -y -o DPkg::Lock::Timeout=900"
step(){ echo; echo "=== $(date '+%F %T')  $1 ==="; }

step "Оновлення системи"
$APT update
$APT full-upgrade
$APT install ufw fail2ban python3-systemd unattended-upgrades htop git curl i2c-tools python3-smbus avahi-daemon

if [ "$INSTALL_DOCKER" = "yes" ]; then
  step "Docker"
  $APT install docker.io docker-compose-v2
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json << 'J'
{ "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }
J
  systemctl enable docker
  systemctl restart docker
  usermod -aG docker "$SERVER_USER"
fi

step "Файрвол UFW"
ufw default deny incoming
ufw default allow outgoing
ufw allow from "$LAN_CIDR" to any port 22 proto tcp comment 'SSH only from LAN'
ufw allow from "$LAN_CIDR" to any port 5353 proto udp comment 'mDNS: hostname.local in LAN'
ufw --force enable

step "SSH"
cat > /etc/ssh/sshd_config.d/10-hardening.conf << EOF2
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
MaxSessions 5
LoginGraceTime 30
X11Forwarding no
AllowUsers ${SERVER_USER}
ClientAliveInterval 300
ClientAliveCountMax 2
EOF2
if ! grep -q '^# pi-setup: password only from LAN' /etc/ssh/sshd_config; then
  printf '\n# pi-setup: password only from LAN\nMatch Address %s\n    PasswordAuthentication yes\n' "$LAN_CIDR" >> /etc/ssh/sshd_config
fi
mkdir -p /run/sshd
if sshd -t; then
  systemctl restart ssh
else
  echo "!!! Помилка конфігу SSH, відкочую"
  rm -f /etc/ssh/sshd_config.d/10-hardening.conf
  sed -i '/^# pi-setup: password only from LAN/,$d' /etc/ssh/sshd_config
fi

step "fail2ban"
cat > /etc/fail2ban/jail.local << 'F2B'
[DEFAULT]
bantime  = 1h
bantime.increment = true
bantime.maxtime = 1w
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1
backend  = systemd

[sshd]
enabled = true
F2B
systemctl enable fail2ban
systemctl restart fail2ban

step "Автооновлення безпеки"
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'AU'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AU

step "Захист мережі на рівні ядра"
cat > /etc/sysctl.d/99-hardening.conf << 'SC'
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.log_martians = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
SC

step "Автовідновлення після збоїв"
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/watchdog.conf << 'WD'
[Manager]
RuntimeWatchdogSec=15s
RebootWatchdogSec=2min
WD
cat > /etc/sysctl.d/98-autoreboot.conf << 'KP'
kernel.panic = 10
kernel.panic_on_oops = 1
KP
sysctl --system >/dev/null
CMDLINE=/boot/firmware/cmdline.txt
if [ -f "$CMDLINE" ] && ! grep -q 'fsck.repair' "$CMDLINE"; then
  sed -i '1 s/$/ fsck.mode=auto fsck.repair=yes/' "$CMDLINE"
fi
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/size.conf << 'JR'
[Journal]
Storage=persistent
SystemMaxUse=300M
JR
systemctl restart systemd-journald

if [ "$INSTALL_ARGON" = "yes" ]; then
  step "Вентилятор Argon ONE"
  # I2C потрібен для керування вентилятором
  CFG=/boot/firmware/config.txt
  grep -q '^dtparam=i2c_arm=on' "$CFG" || echo 'dtparam=i2c_arm=on' >> "$CFG"
  echo i2c-dev > /etc/modules-load.d/i2c-dev.conf
  modprobe i2c-dev 2>/dev/null || true
  chmod 755 /usr/local/bin/argon-fan /usr/local/bin/argon-check /usr/local/bin/argon-fan-test

  # Офіційний драйвер Argon40
  if curl -fsSL https://download.argon40.com/argon1.sh -o /tmp/argon1.sh; then
    timeout 900 bash /tmp/argon1.sh < /dev/null || echo "!!! Офіційний драйвер встановився з помилкою"
  else
    echo "!!! Не вдалося завантажити офіційний драйвер"
  fi

  # Якщо офіційний не з'явився, одразу вмикаємо запасний
  if [ -f /lib/systemd/system/argononed.service ] || [ -f /etc/systemd/system/argononed.service ]; then
    echo "Офіційний драйвер встановлено"
  else
    echo "Офіційного драйвера немає, вмикаю запасний argon-fan"
    systemctl enable argon-fan
  fi
  # При кожному старті перевіряємо, що вентилятором щось керує
  systemctl daemon-reload
  systemctl enable argon-check
fi

step "Прибирання"
printf '#cloud-config\n# Налаштування застосовано, файл очищено.\n' > /boot/firmware/user-data
touch "$MARK"

step "ГОТОВО. Перезавантаження через 1 хвилину"
shutdown -r +1 "pi-setup: фінальне перезавантаження"
BOOT
chmod 700 "$MR/opt/pi-setup/bootstrap.sh"

cat > "$MR/usr/local/bin/server-status" << 'ST'
#!/usr/bin/env bash
echo "== Система ==";   hostname; uptime -p; df -h / | tail -1; free -h | sed -n 2p
[ -r /sys/class/thermal/thermal_zone0/temp ] && echo "CPU: $(( $(cat /sys/class/thermal/thermal_zone0/temp) / 1000 ))°C"
echo; echo "== Мережа =="; ip -4 -br addr | grep -v '^lo'
echo; echo "== Файрвол ==";  sudo ufw status
echo; echo "== fail2ban (SSH) =="; sudo fail2ban-client status sshd | grep -E "Currently|Total"
echo; echo "== Вентилятор Argon =="
if systemctl is-active --quiet argononed 2>/dev/null; then echo "офіційний драйвер працює"
elif systemctl is-active --quiet argon-fan 2>/dev/null; then echo "запасний драйвер працює"
else echo "НЕ ПРАЦЮЄ (перевір: argon-fan-test)"; fi
if command -v docker >/dev/null; then echo; echo "== Контейнери =="; docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"; fi
ST

cat > "$MR/usr/local/bin/server-update" << 'UPD'
#!/usr/bin/env bash
set -euo pipefail
sudo apt-get update && sudo apt-get -y full-upgrade && sudo apt-get -y autoremove
if command -v docker >/dev/null; then docker image prune -f; fi
if [ -f /var/run/reboot-required ]; then echo "Потрібне перезавантаження: sudo reboot"; else echo "Готово"; fi
UPD
chmod 755 "$MR/usr/local/bin/server-status" "$MR/usr/local/bin/server-update" \
          "$MR/usr/local/bin/argon-fan" "$MR/usr/local/bin/argon-check" "$MR/usr/local/bin/argon-fan-test"

sync
umount "$MB" "$MR"
trap - EXIT

echo
log "Все записано на SSD."
echo -e "${B}Далі:${NC}"
echo "  1. sudo reboot   (EEPROM оновиться, Pi стартує з SSD)"
echo "  2. Зачекай 10–20 хв: ставляться пакети, в кінці Pi сам перезавантажиться ще раз"
echo "  3. ssh ${NEW_USER}@${HOST}.local  або  ssh ${NEW_USER}@<IP Pi>"
echo "  4. server-status      і перевір вентилятор:  argon-fan-test"
echo "  5. Можна вимкнути Pi і витягти microSD"
