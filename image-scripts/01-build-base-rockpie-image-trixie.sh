#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 01-build-base-rockpie-image-trixie.sh
#
# Базовый образ Rock Pi E на основе Armbian (Debian 13 trixie, arm64).
# + Автозапуск hub как только это возможно (NetworkManager + tailscaled).
#
# Источник образа: https://www.armbian.com/rockpie/
#   Armbian Minimal CLI, Debian 13 Trixie, arm64
#
# Отличия от Raspberry Pi:
#   - SoC: Rockchip RK3328 (Cortex-A53 quad-core), НЕ Broadcom
#   - Два Ethernet порта (eth0 + eth1), WiFi опционален
#   - Armbian: один rootfs-раздел (ext4), u-boot в начале диска
#   - Нет RPi-специфичных: userconf.txt, config.txt, boot/firmware
#   - Нет GPIO-групп RPi (gpio/i2c/spi)
#   - Thermal zone: /sys/class/thermal/thermal_zone0/temp (RK3328)
#
# Требует артефакты из 00:
#   ARTIFACTS_DIR=/path/to/artifacts-arm64
#
# Требует исходники hub в папке рядом со скриптом:
#   ./hub/app.py, ./hub/requirements.txt, ./hub/templates, ./hub/static
#
# Логи:
#   logs/01-rockpie.<timestamp>.log
#   logs/01-rockpie.<timestamp>.err
# -----------------------------------------------------------------------------

set -euo pipefail
[[ ${DEBUG:-0} -eq 1 ]] && set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
mkdir -p "$LOG_DIR"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/01-rockpie.${RUN_ID}.log"
ERR_FILE="$LOG_DIR/01-rockpie.${RUN_ID}.err"

exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$ERR_FILE" >&2)
trap 'rc=$?; echo "----" >>"$ERR_FILE"; echo "[FATAL] rc=$rc line=${BASH_LINENO[0]} cmd=${BASH_COMMAND}" >>"$ERR_FILE"; echo "----" >>"$ERR_FILE"; exit $rc' ERR

echo "[INFO] Logs: $LOG_FILE"
echo "[INFO] Errs: $ERR_FILE"

START_TIME=$(date +%s)

ARCH="${ARCH:-arm64}"
TARGET_CODENAME="${TARGET_CODENAME:-trixie}"
IMG_SIZE="${IMG_SIZE:-16G}"
BASE_IMG="${BASE_IMG:-rockpie-base-$(date +%Y%m%d).img}"

ARTIFACTS_DIR="${ARTIFACTS_DIR:-}"
[[ -n "$ARTIFACTS_DIR" && -d "$ARTIFACTS_DIR" ]] || { echo "[ERROR] Set ARTIFACTS_DIR to artifacts-arm64 dir" >&2; exit 1; }

# Armbian image URL for Rock Pi E (Debian 13 Trixie, Minimal CLI)
ARMBIAN_URL="${ARMBIAN_URL:-https://dl.armbian.com/rockpi-e/Bookworm_current_minimal}"
# Если есть прямая ссылка на trixie — используем её, иначе ищем
ARMBIAN_IMG_XZ="${ARMBIAN_IMG_XZ:-}"

GOPROXY_IMG="${GOPROXY_IMG:-https://goproxy.cn,https://proxy.golang.org,direct}"
GOSUMDB_IMG="${GOSUMDB_IMG:-off}"

HOST_PWD="$(pwd)"
HUB_SRC="${SCRIPT_DIR}/hub"

err(){ echo "[ERROR] $*" >&2; exit 1; }
info(){ echo -e "\e[1;34m[INFO]\e[0m $*"; }
warn(){ echo -e "\e[1;33m[WARN]\e[0m $*"; }
need(){ command -v "$1" >/dev/null 2>&1; }

curl_retry(){ curl --http1.1 -fL --retry 8 --retry-all-errors --connect-timeout 20 --max-time 0 "$@"; }

# host deps
HOST_DEPS=(xz curl qemu-img parted losetup rsync qemu-aarch64-static jq openssl e2fsck resize2fs mountpoint tar)
MISS=(); for b in "${HOST_DEPS[@]}"; do need "$b" || MISS+=("$b"); done
if ((${#MISS[@]})); then
  info "Installing host deps: ${MISS[*]}"
  sudo apt-get update -qq
  sudo apt-get install -y -qq xz-utils curl qemu-utils parted qemu-user-static rsync jq openssl e2fsprogs util-linux tar
fi

WORK="$(mktemp -d)"
cleanup() {
  set +e
  if mountpoint -q "$WORK/root/dev/pts"; then sudo umount -l "$WORK/root/dev/pts"; fi
  for fs in proc sys dev; do
    if mountpoint -q "$WORK/root/$fs"; then sudo umount -lR "$WORK/root/$fs"; fi
  done
  if mountpoint -q "$WORK/root"; then sudo umount -l "$WORK/root"; fi
  if [[ -n "${LOOP:-}" ]]; then sudo losetup -d "$LOOP" 2>/dev/null || true; fi
  rm -rf "$WORK"
  cd "$HOST_PWD" || true
}
trap cleanup EXIT

# --- 1) Download / reuse Armbian image ---
info "Looking for Armbian Rock Pi E image (Debian trixie)…"

# Ищем локальный .img.xz файл
if [[ -n "$ARMBIAN_IMG_XZ" && -f "$ARMBIAN_IMG_XZ" ]]; then
  FNAME="$ARMBIAN_IMG_XZ"
  info "Using provided image: $FNAME"
else
  # Ищем уже скачанный файл
  LOCAL="$(find . -maxdepth 1 -type f -name "Armbian*rockpi-e*trixie*.img.xz" -print -quit 2>/dev/null || true)"
  if [[ -z "$LOCAL" ]]; then
    LOCAL="$(find . -maxdepth 1 -type f -name "Armbian*rockpi-e*.img.xz" -print -quit 2>/dev/null || true)"
  fi

  if [[ -n "$LOCAL" ]]; then
    FNAME="${LOCAL#./}"
    info "Found local image: $FNAME"
  else
    # Скачиваем с Armbian
    # Прямая ссылка на Trixie minimal для Rock Pi E
    DL_URL="https://dl.armbian.com/rockpi-e/Trixie_current_minimal"
    info "Downloading Armbian Rock Pi E (Trixie) from redirect…"
    # Armbian использует redirect, получаем финальный URL
    EFFECTIVE_URL="$(curl -Ls -o /dev/null -w '%{url_effective}' "$DL_URL" 2>/dev/null || true)"
    if [[ "$EFFECTIVE_URL" =~ \.img\.xz$ ]]; then
      FNAME="$(basename "$EFFECTIVE_URL")"
      info "Resolved: $FNAME"
      curl_retry "$EFFECTIVE_URL" -o "$FNAME"
    else
      # Fallback: попробуем прямой URL из rsync
      info "Redirect failed, trying rsync.armbian.com…"
      FNAME="$(curl -s https://rsync.armbian.com/dl/rockpi-e/archive/ 2>/dev/null | grep -oE 'Armbian[^"]*trixie[^"]*minimal[^"]*\.img\.xz' | tail -n1 || true)"
      if [[ -z "$FNAME" ]]; then
        err "Cannot find Armbian image URL. Download manually from https://www.armbian.com/rockpie/ and place .img.xz in current directory."
      fi
      curl_retry "https://rsync.armbian.com/dl/rockpi-e/archive/$FNAME" -o "$FNAME"
    fi
  fi
fi

[[ -f "$FNAME" ]] || err "Image file not found: $FNAME"

# --- 2) Decompress and resize ---
info "Decompressing $FNAME…"
xz -T0 -dkf "$FNAME"
SRC_IMG="${FNAME%.xz}"
[[ -f "$SRC_IMG" ]] || err "Missing decompressed image"

cp "$SRC_IMG" "$BASE_IMG"
info "Resizing to $IMG_SIZE…"
qemu-img resize -f raw "$BASE_IMG" "$IMG_SIZE" >/dev/null

# Armbian Rock Pi E: один раздел (p1), начинается с сектора 32768
# Расширяем раздел до конца образа
parted -s "$BASE_IMG" unit % resizepart 1 100% >/dev/null

LOOP_TMP="$(sudo losetup -f --show -P "$BASE_IMG")"
sudo e2fsck -f -y "${LOOP_TMP}p1" >/dev/null
sudo resize2fs "${LOOP_TMP}p1" >/dev/null
sudo losetup -d "$LOOP_TMP"

# --- 3) Mount ---
info "Mounting image…"
LOOP="$(sudo losetup -f --show -P "$BASE_IMG")"
sudo mkdir -p "$WORK/root"
sudo mount "${LOOP}p1" "$WORK/root"

# Проверка версии ОС
if [[ -f "$WORK/root/etc/os-release" ]]; then
  info "Image OS:"
  grep -E "^(PRETTY_NAME|VERSION_CODENAME)" "$WORK/root/etc/os-release" || true
fi

# DNS
sudo rm -f "$WORK/root/etc/resolv.conf"
sudo cp /etc/resolv.conf "$WORK/root/etc/resolv.conf"
sudo install -m0755 /usr/bin/qemu-aarch64-static "$WORK/root/usr/bin/qemu-aarch64-static"
for fs in proc sys dev; do sudo mount --bind "/$fs" "$WORK/root/$fs"; done
sudo mount -t devpts devpts "$WORK/root/dev/pts" 2>/dev/null || true


# --- 3a) Copy hub into image ---
if [[ -d "$HUB_SRC" && -f "$HUB_SRC/app.py" ]]; then
  info "Copy hub → /opt/hub (exclude .git)…"
  sudo mkdir -p "$WORK/root/opt/hub"
  sudo rsync -a --delete --exclude '.git' "$HUB_SRC"/ "$WORK/root/opt/hub/"
else
  info "No hub sources at $HUB_SRC (skip hub copy)."
fi

# --- 3b) Copy artifacts into image ---
info "Copying artifacts into image…"
sudo install -d -m0755 "$WORK/root/opt/artifacts"

GO_TGZ="$(ls -1 "$ARTIFACTS_DIR"/go-*.linux-arm64.tar.gz 2>/dev/null | head -n1 || true)"
[[ -n "$GO_TGZ" ]] || err "No go-*.linux-arm64.tar.gz in ARTIFACTS_DIR"
sudo cp -f "$GO_TGZ" "$WORK/root/opt/artifacts/"

for m in "$ARTIFACTS_DIR"/NEEDS_IN_IMAGE_*; do
  [[ -f "$m" ]] && sudo cp -f "$m" "$WORK/root/opt/artifacts/" || true
done

if [[ -d "$ARTIFACTS_DIR/cache/gomod" ]]; then
  sudo mkdir -p "$WORK/root/opt/artifacts/cache"
  sudo rsync -a --delete "$ARTIFACTS_DIR/cache/gomod/" "$WORK/root/opt/artifacts/cache/gomod/"
fi

if [[ -d "$ARTIFACTS_DIR/bin" ]]; then
  sudo mkdir -p "$WORK/root/opt/artifacts/bin"
  sudo rsync -a --delete "$ARTIFACTS_DIR/bin/" "$WORK/root/opt/artifacts/bin/"
fi

# tailscale into /usr/sbin
sudo install -d -m0755 "$WORK/root/usr/sbin" "$WORK/root/etc/systemd/system" "$WORK/root/etc/default"
sudo install -m0755 "$ARTIFACTS_DIR/bin/tailscale"  "$WORK/root/usr/sbin/tailscale"
sudo install -m0755 "$ARTIFACTS_DIR/bin/tailscaled" "$WORK/root/usr/sbin/tailscaled"
sudo install -m0644 "$ARTIFACTS_DIR/systemd/tailscaled.service" "$WORK/root/etc/systemd/system/tailscaled.service"
echo -e 'PORT="0"\nFLAGS=""' | sudo tee "$WORK/root/etc/default/tailscaled" >/dev/null

# other prebuilt go bins into /usr/local/bin
sudo install -d -m0755 "$WORK/root/usr/local/bin"
if [[ -d "$ARTIFACTS_DIR/bin" ]]; then
  for f in "$ARTIFACTS_DIR/bin/"*; do
    bn="$(basename "$f")"
    [[ "$bn" == "tailscale" || "$bn" == "tailscaled" ]] && continue
    sudo install -m0755 "$f" "$WORK/root/usr/local/bin/$bn"
  done
fi

# sources/templates
sudo install -d -m0755 "$WORK/root/opt" "$WORK/root/usr/share"
[[ -d "$ARTIFACTS_DIR/src/Responder" ]]        && sudo rsync -a --delete "$ARTIFACTS_DIR/src/Responder/"        "$WORK/root/opt/Responder/"
[[ -d "$ARTIFACTS_DIR/src/dirsearch" ]]        && sudo rsync -a --delete "$ARTIFACTS_DIR/src/dirsearch/"        "$WORK/root/opt/dirsearch/"
[[ -d "$ARTIFACTS_DIR/src/sqlmap" ]]           && sudo rsync -a --delete "$ARTIFACTS_DIR/src/sqlmap/"           "$WORK/root/opt/sqlmap/"
[[ -d "$ARTIFACTS_DIR/src/SecLists" ]]         && sudo rsync -a --delete "$ARTIFACTS_DIR/src/SecLists/"         "$WORK/root/usr/share/seclists/"
[[ -d "$ARTIFACTS_DIR/src/nuclei-templates" ]] && sudo rsync -a --delete "$ARTIFACTS_DIR/src/nuclei-templates/" "$WORK/root/opt/nuclei-templates/"

# --- 4) Chroot install/config ---
info "Entering chroot…"
sudo --preserve-env=GOPROXY_IMG,GOSUMDB_IMG chroot "$WORK/root" /bin/bash -euxo pipefail -c "$(cat <<'EOS'
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

log(){ echo -e "\e[32m[CHROOT]\e[0m $*"; }

GOPROXY_IMG="${GOPROXY_IMG:-https://goproxy.cn,https://proxy.golang.org,direct}"
GOSUMDB_IMG="${GOSUMDB_IMG:-off}"

cat >/etc/apt/apt.conf.d/80retries <<'APT'
Acquire::Retries "8";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
Acquire::Queue-Mode "access";
APT

cat >/usr/sbin/policy-rc.d <<'PRC'
#!/bin/sh
exit 101
PRC
chmod +x /usr/sbin/policy-rc.d

enable_unit() {
  local unit="$1" target="${2:-multi-user.target}"
  mkdir -p "/etc/systemd/system/${target}.wants"
  local src=""
  if [[ -f "/etc/systemd/system/${unit}" ]]; then src="/etc/systemd/system/${unit}"
  elif [[ -f "/lib/systemd/system/${unit}" ]]; then src="/lib/systemd/system/${unit}"
  else return 0; fi
  ln -sf "${src}" "/etc/systemd/system/${target}.wants/${unit}"
}

curl_retry(){ curl --http1.1 -fL --retry 8 --retry-all-errors --connect-timeout 20 --max-time 0 "$@"; }

echo "krb5-config krb5-config/default_realm string EXAMPLE.LOCAL" | debconf-set-selections || true
echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections || true
echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections || true

export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_DEFAULT_TIMEOUT=600
PIP_RETRIES=25
export PIP_INDEX_URL="https://pypi.org/simple"

pip_retry() { local desc="$1"; shift; local i
  for i in 1 2 3; do
    log "pip install (${desc}) attempt ${i}/3"
    if python3 -m pip install --no-cache-dir --break-system-packages --ignore-installed --retries "${PIP_RETRIES}" --timeout "${PIP_DEFAULT_TIMEOUT}" "$@"; then return 0; fi
    sleep 15
  done; return 1
}

pipx_install_retry() { local pkg="$1"; local i
  for i in 1 2 3; do
    log "pipx install ${pkg} attempt ${i}/3"
    if pipx install --pip-args="--retries ${PIP_RETRIES} --timeout ${PIP_DEFAULT_TIMEOUT}" "$pkg"; then return 0; fi
    sleep 15
  done; return 1
}

log "APT update/upgrade + packages"
apt-get update
apt-get -y -o DPkg::Options::='--force-confdef' -o DPkg::Options::='--force-confold' upgrade

apt-get -y --no-install-recommends install \
  ca-certificates curl wget git gnupg gnupg2 \
  build-essential cmake pkg-config \
  libjson-c-dev libwebsockets-dev libuv1-dev \
  network-manager ethtool \
  sudo iptables iptables-persistent \
  python3 python3-dev python3-pip python3-venv python3-wheel pipx \
  locales less dialog texinfo openssh-server jq bash-completion \
  postgresql postgresql-contrib \
  nmap tcpdump masscan hydra macchanger nikto \
  bind9-dnsutils vim ldap-utils krb5-user krb5-config \
  libpcap-dev libusb-1.0-0-dev libnetfilter-queue-dev \
  libffi-dev libssl-dev libpq-dev zlib1g-dev libldap2-dev libsasl2-dev libkrb5-dev \
  libcap2-bin isc-dhcp-client

apt-get -y --no-install-recommends install fastfetch || true

log "Locales"
sed -Ei 's/^# ?(en_US\.UTF-8 UTF-8)/\1/' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

log "User kali + sudo NOPASSWD"
id -u kali >/dev/null 2>&1 || useradd -m -s /bin/bash kali
echo 'kali:YOUR_PASSWORD' | chpasswd
usermod -aG sudo,adm,dialout,cdrom,audio,video,plugdev,games,users,input,netdev kali
printf '%sudo ALL=(ALL:ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/010-sudo-nopasswd
chmod 440 /etc/sudoers.d/010-sudo-nopasswd

log "Install Go"
GO_TGZ="$(ls -1 /opt/artifacts/go-*.linux-arm64.tar.gz | head -n1)"
rm -rf /usr/local/go && tar -C /usr/local -xzf "$GO_TGZ"
ln -sf /usr/local/go/bin/go /usr/local/bin/go

export PATH="/usr/local/go/bin:/usr/local/bin:/usr/sbin:/usr/bin:$PATH"
export GOPROXY="$GOPROXY_IMG" GOSUMDB="$GOSUMDB_IMG" GODEBUG="http2client=0"
export GIT_TERMINAL_PROMPT=0 GOBIN="/usr/local/bin" GOCACHE="/tmp/go-build"
mkdir -p "$GOCACHE"
[ -d /opt/artifacts/cache/gomod ] && export GOMODCACHE="/opt/artifacts/cache/gomod"

go_install_retry() { local desc="$1"; shift; local i
  for i in 1 2 3; do log "go install (${desc}) attempt ${i}/3"; timeout 45m go install -v "$@" && return 0; sleep 5; done; return 1
}

export PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin
mkdir -p "$PIPX_HOME"
pipx ensurepath || true

ln -sf /opt/Responder/Responder.py /usr/local/bin/responder || true
ln -sf /opt/dirsearch/dirsearch.py /usr/local/bin/dirsearch || true
ln -sf /opt/sqlmap/sqlmap.py /usr/local/bin/sqlmap || true
chmod +x /opt/Responder/Responder.py /opt/dirsearch/dirsearch.py /opt/sqlmap/sqlmap.py 2>/dev/null || true
[ -f /opt/Responder/requirements.txt ] && pip_retry "Responder" -r /opt/Responder/requirements.txt
[ -f /opt/dirsearch/requirements.txt ] && pip_retry "dirsearch" -r /opt/dirsearch/requirements.txt

# Networking: eth1=management, eth0=unmanaged
log "NetworkManager dual-Ethernet config"
install -d -m 0755 /etc/NetworkManager/conf.d
cat >/etc/NetworkManager/conf.d/10-rockpie-ethernet.conf <<'CNF'
[keyfile]
unmanaged-devices=interface-name:eth0
CNF

mkdir -p /etc/NetworkManager/system-connections
cat >/etc/NetworkManager/system-connections/eth1-management.nmconnection <<'NMC'
[connection]
id=eth1-management
type=ethernet
interface-name=eth1
autoconnect=true

[ipv4]
method=auto

[ipv6]
method=auto
NMC
chmod 600 /etc/NetworkManager/system-connections/eth1-management.nmconnection

log "Enable core units"
enable_unit tailscaled.service multi-user.target
enable_unit NetworkManager.service multi-user.target
enable_unit ssh.service multi-user.target

log "CGO tools"
[ -f /opt/artifacts/NEEDS_IN_IMAGE_NAABU ]     && CGO_ENABLED=1 go_install_retry naabu github.com/projectdiscovery/naabu/v2/cmd/naabu@latest
[ -f /opt/artifacts/NEEDS_IN_IMAGE_BETTERCAP ] && CGO_ENABLED=1 go_install_retry bettercap github.com/bettercap/bettercap@latest
[ -f /opt/artifacts/NEEDS_IN_IMAGE_KATANA ]    && CGO_ENABLED=1 go_install_retry katana github.com/projectdiscovery/katana/cmd/katana@latest

if [ ! -x /usr/local/bin/ligolo-agent ] || [ -f /opt/artifacts/NEEDS_IN_IMAGE_LIGOLO ]; then
  go_install_retry ligolo-agent github.com/nicocha30/ligolo-ng/cmd/agent@latest
  go_install_retry ligolo-proxy github.com/nicocha30/ligolo-ng/cmd/proxy@latest
fi

log "Build ttyd"
rm -rf /usr/local/src/ttyd && git clone --depth 1 https://github.com/tsl0922/ttyd.git /usr/local/src/ttyd
cd /usr/local/src/ttyd && mkdir -p build && cd build && cmake .. -DCMAKE_BUILD_TYPE=Release && make -j"$(nproc)" && make install
cat >/etc/systemd/system/ttyd.service <<'UNIT'
[Unit]
Description=ttyd web terminal
After=network.target
[Service]
User=kali
ExecStart=/usr/local/bin/ttyd -p 7681 -W /bin/bash -l
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
enable_unit ttyd.service multi-user.target

# iptables: блокируем все входящие кроме Tailscale (безопасность на операции)
log "Firewall: allow only Tailscale inbound"
iptables -F INPUT
iptables -A INPUT -i tailscale0 -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -j DROP
mkdir -p /etc/iptables
iptables-save > /etc/iptables/rules.v4
rm -rf /tmp/ponysay && git clone --depth 1 https://github.com/erkin/ponysay.git /tmp/ponysay
cd /tmp/ponysay && python3 ./setup.py --freedom=partial install && rm -rf /tmp/ponysay

log "pipx tools"
pipx_install_retry impacket
pipx_install_retry mitmproxy
pipx_install_retry mitm6
pipx_install_retry certipy-ad

log "Rust + uv + NetExec"
export RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
cd /root
curl_retry https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
export PATH="/opt/cargo/bin:$PATH"
ln -sf /opt/cargo/bin/rustc /usr/local/bin/rustc
ln -sf /opt/cargo/bin/cargo /usr/local/bin/cargo
curl_retry https://astral.sh/uv/install.sh | sh
[ -x /root/.local/bin/uv ] && install -m0755 /root/.local/bin/uv /usr/local/bin/uv
uv tool install --force "git+https://github.com/Pennyw0rth/NetExec"
install -m0755 /root/.local/bin/{NetExec,netexec,nxc,nxcdb} /usr/local/bin/ 2>/dev/null || true

setcap 'cap_net_raw+ep' /usr/bin/masscan 2>/dev/null || true
setcap 'cap_net_raw+ep' /usr/bin/tcpdump 2>/dev/null || true

log "Zabbix agent2"
install -d -m0755 /etc/apt/keyrings
curl_retry https://repo.zabbix.com/zabbix-official-repo.key | gpg --dearmor -o /etc/apt/keyrings/zabbix.gpg
cat >/etc/apt/sources.list.d/zabbix.list <<'SRC'
deb [arch=arm64 signed-by=/etc/apt/keyrings/zabbix.gpg] https://repo.zabbix.com/zabbix/7.0/debian-arm64 bookworm main
SRC
apt-get update && apt-get -y install zabbix-agent2
enable_unit zabbix-agent2.service multi-user.target

log "Metasploit"
apt-get clean
curl_retry https://raw.githubusercontent.com/rapid7/metasploit-omnibus/master/config/templates/metasploit-framework-wrappers/msfupdate.erb -o /tmp/msfinstall
chmod 755 /tmp/msfinstall && /tmp/msfinstall
enable_unit postgresql.service multi-user.target

log "kubectl"
curl_retry "https://dl.k8s.io/release/v1.30.8/bin/linux/arm64/kubectl" -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl

log "Hub setup"
if [ -d /opt/hub ] && [ -f /opt/hub/app.py ]; then
  python3 -m venv /opt/hub/venv
  /opt/hub/venv/bin/pip install --no-cache-dir -r /opt/hub/requirements.txt || true
  chown -R kali:kali /opt/hub || true
  cat >/etc/systemd/system/hub.service <<'UNIT'
[Unit]
Description=Hub web UI
After=network.target NetworkManager.service tailscaled.service
[Service]
Type=simple
User=kali
WorkingDirectory=/opt/hub
ExecStart=/opt/hub/venv/bin/python /opt/hub/app.py
Restart=always
[Install]
WantedBy=multi-user.target
UNIT
  enable_unit hub.service multi-user.target
fi

# Restore prebuilt bins
if [ -d /opt/artifacts/bin ]; then
  for f in /opt/artifacts/bin/*; do
    bn="$(basename "$f")"; [[ "$bn" == "tailscale" || "$bn" == "tailscaled" ]] && continue
    install -m0755 "$f" "/usr/local/bin/$bn" || true
  done
fi
ln -sf /usr/local/go/bin/go /usr/local/bin/go

# Cleanup
rm -rf /opt/artifacts/cache /opt/artifacts/bin /opt/artifacts/go-*.tar.gz /opt/artifacts/NEEDS_IN_IMAGE_*
rm -f /usr/sbin/policy-rc.d
apt-get clean
log "Done"
EOS
)"

# finalize
info "Finalising base image…"
sudo umount -l "$WORK/root/dev/pts" 2>/dev/null || true
for fs in proc sys dev; do sudo umount -lR "$WORK/root/$fs" 2>/dev/null || true; done
sudo umount -l "$WORK/root"
sudo losetup -d "$LOOP"

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
info "✓ Base Rock Pi E image ready: $BASE_IMG (size: $IMG_SIZE)"
echo "[INFO] Elapsed: $((ELAPSED/60))m $((ELAPSED%60))s"
echo "Next: sudo bash 02-personalize-rockpie-image-trixie.sh $BASE_IMG"
