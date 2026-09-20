#!/usr/bin/env bash
# firstboot.sh — everything that must happen the first time the server boots Ubuntu.
#
# Started by pi-setup.service (see install.sh), not by cloud-init: cloud-init's runcmd
# runs once and can end up empty after an unclean shutdown. The unit retries on every
# boot until /opt/pi-setup/.done exists, so a power cut mid-setup is not fatal.
#
# Reads /opt/pi-setup/setup.conf written by install.sh.
# Log: /var/log/pi-setup.log

set -uo pipefail
exec > >(tee -a /var/log/pi-setup.log) 2>&1

MARK=/opt/pi-setup/.done
[ -f "$MARK" ] && { echo "Налаштування вже виконано"; exit 0; }

# shellcheck disable=SC1091
source /opt/pi-setup/setup.conf

REPO=${REPO_DIR:-/opt/pi-server}
export DEBIAN_FRONTEND=noninteractive
APT="apt-get -y -o DPkg::Lock::Timeout=900"
step(){ echo; echo "=== $(date '+%F %T')  $1 ==="; }

step "Оновлення системи"
$APT update
$APT full-upgrade
# mc і tree — навігація по файловій системі з терміналу, sqlite3 потрібен бекапам
$APT install ufw fail2ban python3-systemd unattended-upgrades htop git curl \
             i2c-tools python3-smbus avahi-daemon mc tree sqlite3

step "Команди сервера"
# The repo is the source of truth for server-status and friends.
if [ ! -d "$REPO/.git" ]; then
    git clone --depth 1 "$REPO_URL" "$REPO" || echo "!!! Не вдалося клонувати $REPO_URL"
fi
if [ -d "$REPO" ]; then
    bash "$REPO/scripts/install-commands.sh"
else
    echo "!!! Команди сервера не встановлено — перевір мережу і запусти firstboot ще раз"
fi

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
    # Apps live here; each subfolder is one docker-compose project.
    mkdir -p /srv/apps
    chown "$SERVER_USER:$SERVER_USER" /srv/apps
fi

step "Файрвол UFW"
ufw default deny incoming
ufw default allow outgoing
ufw allow from "$LAN_CIDR" to any port 22 proto tcp comment 'SSH only from LAN'
ufw allow from "$LAN_CIDR" to any port 5353 proto udp comment 'mDNS: hostname.local in LAN'
ufw --force enable

step "SSH"
cat > /etc/ssh/sshd_config.d/10-hardening.conf << EOF
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
EOF
# Password login stays available from the local network, so you cannot lock
# yourself out before copying an SSH key.
if ! grep -q '^# pi-setup: password only from LAN' /etc/ssh/sshd_config; then
    printf '\n# pi-setup: password only from LAN\nMatch Address %s\n    PasswordAuthentication yes\n' \
        "$LAN_CIDR" >> /etc/ssh/sshd_config
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
    CFG=/boot/firmware/config.txt
    grep -q '^dtparam=i2c_arm=on' "$CFG" || echo 'dtparam=i2c_arm=on' >> "$CFG"
    echo i2c-dev > /etc/modules-load.d/i2c-dev.conf
    modprobe i2c-dev 2>/dev/null || true

    # Official Argon40 driver first; our fallback takes over only if it is missing.
    if curl -fsSL https://download.argon40.com/argon1.sh -o /tmp/argon1.sh; then
        timeout 900 bash /tmp/argon1.sh < /dev/null || echo "!!! Офіційний драйвер встановився з помилкою"
    else
        echo "!!! Не вдалося завантажити офіційний драйвер"
    fi

    if [ -f /lib/systemd/system/argononed.service ] || [ -f /etc/systemd/system/argononed.service ]; then
        echo "Офіційний драйвер встановлено"
    else
        echo "Офіційного драйвера немає, вмикаю запасний argon-fan"
        systemctl enable argon-fan
    fi
    systemctl daemon-reload
    systemctl enable argon-check   # re-checks on every boot that something drives the fan
fi

step "Прибирання"
printf '#cloud-config\n# Налаштування застосовано, файл очищено.\n' > /boot/firmware/user-data
touch "$MARK"
sync

step "ГОТОВО. Перезавантаження через 1 хвилину"
shutdown -r +1 "pi-setup: фінальне перезавантаження"
