#!/bin/sh
# OpenWrt 25.12.x — Xray TProxy (IPv4-only)

# Логируем установку
LOG_FILE="/tmp/xray_install.log"
exec 1> >(tee -a "$LOG_FILE")
exec 2>&1

echo "=== Установка Xray TProxy ==="
echo "  "
[ "$(id -u)" != "0" ] && {
	echo "Запускать нужно от root"
	exit 1
}

# Переменные
REPO="https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT-GE/main"
GENERATOR="/usr/share/xray/xray-generate-config.py"
PARSER="/usr/share/xray/xray-sub-parser.py"
UPDATER="/usr/share/xray/update-xray.sh"
NFT_UPDATER="/usr/share/xray/update-nft.sh"
CONFIG_DIR="/etc/xray"
CONFIG_JSON="$CONFIG_DIR/config.json"
SETTINGS_JSON="$CONFIG_DIR/settings.json"
TMP_DIR="/tmp/xray_install"
GEO_DIR="/usr/share/xray"
STATE_DIR="/etc/xray/state"

# Значения из CLI (если не указаны — берутся из settings.default.json)
SUB_USER_AGENT=""
SUB_URL=""
REMARKS_FILTER=""
DWL_DOMAIN=""
GUEST_ENABLED=0
GUEST_NET="Guest"
GUEST_IP="192.168.10.1"
FREEDOM_ENABLED=0
FREEDOM_NET="Freedom"
FREEDOM_IP="192.168.20.1"
XRAY_NETS="freedom"

# =============================================
#   ХЕЛПЕРЫ ДЛЯ ЕДИНОГО JSON-КОНФИГА
# =============================================

# Чтение значения из settings.json по jq-пути
# Пример: settings_get ".subscription.url"
settings_get() {
    local key="$1"
    [ -f "$SETTINGS_JSON" ] || return 1
    jq -r "
        if $key | type == \"boolean\" then
            if $key then \"1\" else \"0\" end
        elif $key | type == \"array\" then
            $key[]
        else
            $key // empty
        end
    " "$SETTINGS_JSON" 2>/dev/null
}

# Запись значения в settings.json по jq-пути
# Пример: settings_set ".subscription.url" "https://..."
settings_set() {
    local key="$1"
    local val="$2"
    mkdir -p "$(dirname "$SETTINGS_JSON")"
    [ -f "$SETTINGS_JSON" ] || echo '{}' > "$SETTINGS_JSON"
    if echo "$val" | grep -qE '^[0-9]+$'; then
        jq --argjson v "$val" "$key = \$v" "$SETTINGS_JSON" > "${SETTINGS_JSON}.tmp"
    else
        jq --arg v "$val" "$key = \$v" "$SETTINGS_JSON" > "${SETTINGS_JSON}.tmp"
    fi
    mv "${SETTINGS_JSON}.tmp" "$SETTINGS_JSON"
    chmod 600 "$SETTINGS_JSON"
}

# =============================================
#   ЕДИНАЯ ФУНКЦИЯ ЗАГРУЗКИ
# =============================================

# Универсальная загрузка файла (с авто-заголовками из settings.json + до 3 кастомных)
# Использование:
#   download_file "URL" "DEST" ["HEADER1" "HEADER2" "HEADER3"]
download_file() {
    local url="$1"
    local dst="$2"
    shift 2
    local max_retries=3
    local retry=1

    # Системные заголовки из settings.json (могут быть пустыми при первом запуске)
    local _ua _ver _model _os
    _ua=$(settings_get ".subscription.user_agent" 2>/dev/null || echo "XPower/1.0")
    _ver=$(settings_get ".ver_os" 2>/dev/null || echo "")
    _model=$(settings_get ".device_model" 2>/dev/null || echo "")
    _os=$(settings_get ".device_os" 2>/dev/null || echo "")

    while [ $retry -le $max_retries ]; do
        curl -s -L --max-time 15 \
            -H "User-Agent: $_ua" \
            ${_ver:+-H "X-Ver-Os: $_ver"} \
            ${_model:+-H "X-Device-Model: $_model"} \
            ${_os:+-H "X-Device-Os: $_os"} \
            ${1:+-H "$1"} \
            ${2:+-H "$2"} \
            ${3:+-H "$3"} \
            -o "$dst" "$url"
        local rc=$?

        if [ $rc -eq 0 ] && [ -s "$dst" ]; then
            if head -n 1 "$dst" 2>/dev/null | grep -qi "<html\|<!DOCTYPE"; then
                rm -f "$dst"
            else
                return 0
            fi
        fi

        if [ $retry -lt $max_retries ]; then
            sleep 2
        fi
        retry=$((retry + 1))
    done

    return 1
}

download_script() {
    local url="$1"
    local dst="$2"
    if download_file "$url" "$dst"; then
        chmod +x "$dst"
        echo "  → $dst"
    else
        echo "  [X] Ошибка: не удалось скачать $dst"
        exit 1
    fi
}

# Парсер аргументов
for arg in "$@"; do
	case $arg in
	--sub-ua=*) SUB_USER_AGENT="${arg#*=}" ;;
	--remarks=*) REMARKS_FILTER="${arg#*=}" ;;
	--guest=1) GUEST_ENABLED=1 ;;
	--guest-ip=*) GUEST_IP="${arg#*=}" ;;
	--freedom=1) FREEDOM_ENABLED=1 ;;
	--freedom-ip=*) FREEDOM_IP="${arg#*=}" ;;
	--xray-nets=*) XRAY_NETS="${arg#*=}" ;;	--sub=*) SUB_URL="${arg#*=}" ;;
	--dwl=*) DWL_DOMAIN="${arg#*=}" ;;
	*) echo "[!] Неизвестный аргумент: $arg" ;;
	esac
done

# Валидация
if [ -z "$SUB_URL" ]; then
	echo "[!] Ошибка: --sub=URL обязателен"
	exit 1
fi

# Создаём необходимые директории
mkdir -p "$CONFIG_DIR" "$TMP_DIR" "$GEO_DIR" "$STATE_DIR"

# Инициализируем settings.json из репозитория (если файла нет)
if [ ! -f "$SETTINGS_JSON" ]; then
    echo "  → Скачиваем settings.default.json из репозитория..."
    download_file "$REPO/settings.default.json" "$SETTINGS_JSON" || {
        echo "  [X] Не удалось скачать settings.default.json"
        exit 1
    }
    chmod 600 "$SETTINGS_JSON"
    echo "  ✓ settings.json инициализирован"
fi

# =============================================
# 1. Устанавливаем Timezone и синхронизируем время
# =============================================
echo "1. Устанавливаем Timezone и синхронизируем время..."
uci set system.@system[0].zonename='Europe/Moscow'
uci set system.@system[0].timezone='MSK-3'
uci commit system

ntpd -q -p ru.pool.ntp.org 2>/dev/null ||
	ntpd -q -p time.google.com 2>/dev/null ||
	echo " [!] Синхронизация времени не удалась, продолжаем..."

echo "[+] Timezone установлен в Europe/Moscow, время синхронизировано"

# =============================================
# 2. Загружаем скрипты из репозитория
# =============================================
echo "2. Загружаем скрипты из репозитория..."

download_script "$REPO/xray-generate-config.py" "$GENERATOR"
download_script "$REPO/xray-sub-parser.py" "$PARSER"
download_script "$REPO/update-xray.sh" "$UPDATER"
download_script "$REPO/update-nft.sh" "$NFT_UPDATER"

echo "[+] Все скрипты загружены и готовы к использованию"

# =============================================
# 3. Сохраняем настройки в единый settings.json
# =============================================
echo "3. Сохраняем настройки в settings.json..."

# Определяем модель устройства
echo "  → Определяем модель устройства..."
DEVICE_MODEL=$(dmesg | sed -n 's/.*Machine model: //p' | head -1)
if [ -n "$DEVICE_MODEL" ]; then
    settings_set ".device_model" "$DEVICE_MODEL"
    echo "  ✓ Модель: $DEVICE_MODEL"
else
    echo "  [!] Не удалось определить модель устройства"
fi

# Определяем версию OpenWrt
echo "  → Определяем версию OpenWrt..."
if [ -f /etc/openwrt_release ]; then
    . /etc/openwrt_release
    [ -n "$DISTRIB_ID" ] && settings_set ".device_os" "$DISTRIB_ID"
    [ -n "$DISTRIB_RELEASE" ] && settings_set ".ver_os" "$DISTRIB_RELEASE"
    echo "  ✓ ОС: $DISTRIB_ID $DISTRIB_RELEASE"
else
    echo "  [!] /etc/openwrt_release не найден"
fi

settings_set ".subscription.url" "$SUB_URL"
[ -n "$SUB_USER_AGENT" ] && settings_set ".subscription.user_agent" "$SUB_USER_AGENT"
[ -n "$REMARKS_FILTER" ] && settings_set ".subscription.remarks_filter" "$REMARKS_FILTER"
[ -n "$DWL_DOMAIN" ] && jq --arg d "$DWL_DOMAIN" \
    'if .domain_whitelist | index($d) then . else .domain_whitelist += [$d] end' \
    "$SETTINGS_JSON" > "${SETTINGS_JSON}.tmp" && mv "${SETTINGS_JSON}.tmp" "$SETTINGS_JSON"
# Сохраняем список сетей, трафик которых пойдёт через Xray
jq --arg nets "$XRAY_NETS" '.xray_nets = ($nets | split(","))' \
    "$SETTINGS_JSON" > "${SETTINGS_JSON}.tmp" && mv "${SETTINGS_JSON}.tmp" "$SETTINGS_JSON"
echo "[+] settings.json сохранён: $SETTINGS_JSON"

# =============================================
# 4. Отключаем IPv6
# =============================================
echo "4. Отключаем IPv6..."

uci set network.lan.ipv6='0'
uci set network.wan.ipv6='0'
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='disabled'
uci -q delete network.wan6
uci commit network
uci commit dhcp

/etc/init.d/odhcpd stop 2>/dev/null || true
/etc/init.d/odhcpd disable 2>/dev/null || true

echo "[+] Сеть настроена (изменения применятся после перезагрузки), IPv6 отключён"

# =============================================
# 5. Настраиваем гостевые сети
# =============================================
if [ $GUEST_ENABLED -eq 1 ] || [ $FREEDOM_ENABLED -eq 1 ]; then
	echo "5. Настройка гостевых сетей:"

	# === Guest (первая гостевая сеть) ===
	if [ $GUEST_ENABLED -eq 1 ]; then
		echo "  → Настройка Guest Network:"

		# Bridge device (config device)
		# Сначала убираем lan4 из br-lan (если он там был), чтобы порт не висел в двух мостах
		for sec in $(uci show network | grep "\.ports=" | grep "lan4" | sed 's/\.ports=.*//'); do
			uci del_list ${sec}.ports="lan4"
		done
		uci -q delete network.Guest_dev
		uci set network.Guest_dev="device"
		uci set network.Guest_dev.type="bridge"
		uci set network.Guest_dev.name="br-guest"
		uci add_list network.Guest_dev.ports="lan4"
		uci set network.Guest_dev.igmp_snooping="1"

		# Interface
		uci -q delete network.Guest
		uci set network.Guest="interface"
		uci set network.Guest.proto="static"
		uci set network.Guest.device="br-guest"
		uci set network.Guest.ipaddr="$GUEST_IP"
		uci set network.Guest.netmask="255.255.255.0"
		uci set network.Guest.type="bridge"
		uci commit network
		echo "  → Guest Bridge + Interface: br-guest (${GUEST_IP}/24)"

		# DHCP
		uci -q delete dhcp.Guest
		uci set dhcp.Guest="dhcp"
		uci set dhcp.Guest.interface="Guest"
		uci set dhcp.Guest.start="100"
		uci set dhcp.Guest.limit="150"
		uci set dhcp.Guest.leasetime="12h"
		uci set dhcp.Guest.force="1"
		uci set dhcp.Guest.ignore="0"
		uci commit dhcp
		echo "  → DHCP для Guest настроен"

		# Firewall Zone
		uci -q delete firewall.Guest
		uci set firewall.Guest="zone"
		uci set firewall.Guest.name="Guest"
		uci set firewall.Guest.network="Guest"
		uci set firewall.Guest.input="REJECT"
		uci set firewall.Guest.output="ACCEPT"
		uci set firewall.Guest.forward="REJECT"
		uci set firewall.Guest.masq="1"
		uci set firewall.Guest.mtu_fix="1"

		# Firewall DNS
		uci -q delete firewall.Guest_dns
		uci set firewall.Guest_dns="rule"
		uci set firewall.Guest_dns.name="Allow-DNS-Guest"
		uci set firewall.Guest_dns.src="Guest"
		uci set firewall.Guest_dns.dest_port="53"
		uci set firewall.Guest_dns.proto="tcp udp"
		uci set firewall.Guest_dns.target="ACCEPT"

		# Firewall DHCP
		uci -q delete firewall.Guest_dhcp
		uci set firewall.Guest_dhcp="rule"
		uci set firewall.Guest_dhcp.name="Allow-DHCP-Guest"
		uci set firewall.Guest_dhcp.src="Guest"
		uci set firewall.Guest_dhcp.dest_port="67-68"
		uci set firewall.Guest_dhcp.proto="udp"
		uci set firewall.Guest_dhcp.target="ACCEPT"

		# Forward to WAN
		uci -q delete firewall.Guest_wan
		uci set firewall.Guest_wan="forwarding"
		uci set firewall.Guest_wan.src="Guest"
		uci set firewall.Guest_wan.dest="wan"
		uci commit firewall

		echo "  [+] Guest Network настроена"
	fi

	# === Freedom (вторая гостевая сеть) ===
	if [ $FREEDOM_ENABLED -eq 1 ]; then
		echo "  → Настройка Freedom Network:"

		# Bridge device (config device)
		uci -q delete network.Freedom_dev
		uci set network.Freedom_dev="device"
		uci set network.Freedom_dev.type="bridge"
		uci set network.Freedom_dev.name="br-freedom"
		uci set network.Freedom_dev.igmp_snooping="1"

		# Interface
		uci -q delete network.Freedom
		uci set network.Freedom="interface"
		uci set network.Freedom.proto="static"
		uci set network.Freedom.ipaddr="$FREEDOM_IP"
		uci set network.Freedom.netmask="255.255.255.0"
		uci set network.Freedom.device="br-freedom"
		uci commit network
		echo "  → Freedom Bridge + Interface: br-freedom (${FREEDOM_IP}/24)"

		# DHCP
		uci -q delete dhcp.Freedom
		uci set dhcp.Freedom="dhcp"
		uci set dhcp.Freedom.interface="Freedom"
		uci set dhcp.Freedom.start="100"
		uci set dhcp.Freedom.limit="150"
		uci set dhcp.Freedom.leasetime="12h"
		uci set dhcp.Freedom.force="1"
		uci set dhcp.Freedom.ignore="0"
		uci commit dhcp
		echo "  → DHCP для Freedom настроен"

		# Firewall Zone
		uci -q delete firewall.Freedom
		uci set firewall.Freedom="zone"
		uci set firewall.Freedom.name="Freedom"
		uci set firewall.Freedom.network="Freedom"
		uci set firewall.Freedom.input="REJECT"
		uci set firewall.Freedom.output="ACCEPT"
		uci set firewall.Freedom.forward="REJECT"
		uci set firewall.Freedom.masq="1"
		uci set firewall.Freedom.mtu_fix="1"

		# Firewall DNS
		uci -q delete firewall.Freedom_dns
		uci set firewall.Freedom_dns="rule"
		uci set firewall.Freedom_dns.name="Allow-DNS-Freedom"
		uci set firewall.Freedom_dns.src="Freedom"
		uci set firewall.Freedom_dns.dest_port="53"
		uci set firewall.Freedom_dns.proto="tcp udp"
		uci set firewall.Freedom_dns.target="ACCEPT"

		# Firewall DHCP
		uci -q delete firewall.Freedom_dhcp
		uci set firewall.Freedom_dhcp="rule"
		uci set firewall.Freedom_dhcp.name="Allow-DHCP-Freedom"
		uci set firewall.Freedom_dhcp.src="Freedom"
		uci set firewall.Freedom_dhcp.dest_port="67-68"
		uci set firewall.Freedom_dhcp.proto="udp"
		uci set firewall.Freedom_dhcp.target="ACCEPT"

		# Forward to WAN
		uci -q delete firewall.Freedom_wan
		uci set firewall.Freedom_wan="forwarding"
		uci set firewall.Freedom_wan.src="Freedom"
		uci set firewall.Freedom_wan.dest="wan"
		uci commit firewall

		echo "  [+] Freedom Network настроена"
	fi

	echo "[+] Настройка гостевых сетей завершена (изменения применятся после перезагрузки)"
else
	echo "5. Пропускаем настройку гостевых сетей (--guest=1 и --freedom=1 не указаны)"
fi

# =============================================
# 6. Установка Xray из GitHub
# =============================================
echo "6. Устанавливаем Xray из GitHub..."

# Ждём доступности GitHub API
for i in $(seq 1 10); do
	if curl -s --max-time 3 https://api.github.com >/dev/null 2>&1; then
		break
	fi
	echo "  → Ожидание доступа к GitHub... ($i)"
	sleep 2
done

# Получаем версию Xray
LATEST_VERSION=$(curl -s --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest |
	sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')

[ -z "$LATEST_VERSION" ] && {
	echo "  [X] Ошибка: не удалось получить версию Xray"
	exit 1
}

LATEST_VER_NUM="${LATEST_VERSION#v}"

# Проверяем, какая версия уже установлена
CURRENT_VERSION=""
if [ -x /usr/bin/xray ]; then
	CURRENT_VERSION=$(/usr/bin/xray version 2>/dev/null | head -1 | awk '{print $2}')
fi

if [ "$CURRENT_VERSION" = "$LATEST_VER_NUM" ]; then
	echo "  ✓ Xray уже актуальной версии $LATEST_VERSION, пропускаем установку"
else
	[ -n "$CURRENT_VERSION" ] && echo "  → Текущая версия: $CURRENT_VERSION, будет обновлено до $LATEST_VER_NUM"

	ARCH=$(uname -m)
	case "$ARCH" in
	x86_64 | amd64) MACHINE="64" ;;
	aarch64) MACHINE="arm64-v8a" ;;
	armv7l) MACHINE="arm32-v7a" ;;
	*) MACHINE="64" ;;
	esac

	ZIP_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-${MACHINE}.zip"
	ZIP_DEST="$TMP_DIR/xray.zip"
	SHA_FILE="$STATE_DIR/xray.zip.sha256sum"
	DGST_FILE="$STATE_DIR/xray.dgst"

	extract_sha256() {
		grep '^SHA2-256' "$1" |
			sed 's/.*= *//' |
			tr -cd '0-9a-fA-F' |
			cut -c1-64
	}

	echo "  → Версия: $LATEST_VERSION, архитектура: $MACHINE"
	echo "  → URL: ${ZIP_URL}.dgst"

	echo "  → Скачиваем .dgst для Xray..."
	download_file "${ZIP_URL}.dgst" "$DGST_FILE" || {
		echo "  [X] Ошибка: не удалось скачать .dgst для Xray"
		exit 1
	}

	if [ ! -s "$DGST_FILE" ] || ! grep -q 'SHA2-256' "$DGST_FILE" 2>/dev/null; then
		echo "  [X] Ошибка: .dgst файл пустой или не содержит SHA2-256"
		echo "  → Содержимое ответа:"
		cat "$DGST_FILE" 2>/dev/null || echo " (файл пустой)"
		exit 1
	fi

	REMOTE_SHA="$(extract_sha256 "$DGST_FILE")"
	[ -z "$REMOTE_SHA" ] && {
		echo "  [X] Ошибка: не удалось извлечь SHA2-256 из .dgst"
		exit 1
	}

	echo "  → Ожидаемый SHA2-256: ${REMOTE_SHA:0:16}..."

	FREE_SPACE_TMP=$(df /tmp | awk 'NR==2 {print $4}')
	if [ "$FREE_SPACE_TMP" -lt 20480 ]; then
		echo "  [X] Недостаточно места в /tmp (нужно минимум 20MB)" >>"$LOG_FILE"
		exit 1
	fi

	if [ -f "$SHA_FILE" ] && [ "$(cat "$SHA_FILE")" = "$REMOTE_SHA" ] && [ -f "$ZIP_DEST" ]; then
		echo "  ✓ Найден локальный ZIP с тем же SHA, повторное скачивание не требуется"
	else
		echo "  → Скачиваем Xray ZIP (${LATEST_VERSION})..."
		download_file "$ZIP_URL" "$ZIP_DEST" || {
			echo "  [X] Ошибка: не удалось скачать Xray ZIP"
			exit 1
		}

		if [ ! -s "$ZIP_DEST" ]; then
			echo "  [X] Ошибка: скачанный ZIP пустой"
			exit 1
		fi

		LOCAL_SHA="$(sha256sum "$ZIP_DEST" | awk '{print $1}')"
		if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
			echo "  [X] Ошибка: SHA не совпадает!"
			echo "  ожидалось: $REMOTE_SHA"
			echo "  получено : $LOCAL_SHA"
			exit 1
		fi

		echo "$REMOTE_SHA" >"$SHA_FILE"
	fi

	unzip -q "$ZIP_DEST" -d "$TMP_DIR"

	cp "$TMP_DIR/xray" /usr/bin/xray
	chmod 755 /usr/bin/xray

	echo "[+] Xray установлен версии $LATEST_VERSION"
fi

# =============================================
# 7. Настройка DNS (dnsmasq → Xray)
# =============================================
echo "7. Настраиваем DNS (dnsmasq → Xray)..."

uci set dhcp.@dnsmasq[0].noresolv='1'
uci set dhcp.@dnsmasq[0].strictorder='1'
uci set dhcp.@dnsmasq[0].cachesize='1000'
uci set dhcp.@dnsmasq[0].min_cache_ttl='300'
uci set dhcp.@dnsmasq[0].max_cache_ttl='600'

uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5353'
uci add_list dhcp.@dnsmasq[0].server='77.88.8.8'
uci commit dhcp

echo "[+] DNS настроен (dnsmasq → Xray:5353 + fallback 77.88.8.8)"

# =============================================
# 8. Создаём init.d для Xray
# =============================================
echo "8. Создаём init.d для Xray..."

cat >/etc/init.d/xray <<'XRAYEOF'
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=85
STOP=10

CONF="/etc/xray/config.json"
ASSET_DIR="/usr/share/xray"

start_service() {
    # Ждём сеть
    for i in $(seq 1 15); do
        if ip route | grep -q default; then
            break
        fi
        logger -t xray "Waiting for network... ($i)"
        sleep 2
    done

    # Сохраняем IP шлюза (нужен генератору для dns-in)
    ip -4 addr show br-lan 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 > /etc/xray/gateway_ip 2>/dev/null || true

    # Синхронизация времени (важно для TLS/REALITY)
    ntpd -q -p ru.pool.ntp.org 2>/dev/null || \
    ntpd -q -p time.google.com 2>/dev/null || \
    logger -t xray "Time sync failed, continuing"
    sleep 1

    # Проверяем geo-файлы
    if [ ! -s "$ASSET_DIR/geoip.dat" ] || [ ! -s "$ASSET_DIR/geosite.dat" ]; then
        logger -t xray "Geo assets missing — run update-xray.sh"
        return 1
    fi

    # Валидация конфига
    if ! xray run -test -config "$CONF" >/dev/null 2>&1; then
        logger -t xray "Invalid config.json"
        return 1
    fi

    # Применяем nftables правила
    /usr/share/xray/update-nft.sh || {
        logger -t xray "Failed to apply nftables rules"
        return 1
    }

    procd_open_instance "xray"
    procd_set_param command /usr/bin/xray run -config "$CONF"
    procd_set_param env XRAY_LOCATION_ASSET="$ASSET_DIR"
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_set_param respawn 3600 5 5
    procd_set_param limits nofile="1000000 1000000"
    procd_set_param file "$CONF"
    procd_close_instance

    # procd запустит xray после возврата из start_service().
    # Конфиг уже проверен xray run -test. При падении — respawn 3600 5 5.
    logger -t xray "Xray registered with procd (transparent gateway mode)"
}

stop_service() {
    # Убираем jump-правила из fw4
    local _handle
    _handle=$(nft -a list chain inet fw4 prerouting 2>/dev/null \
        | grep 'jump xray_tproxy' | sed 's/.*handle //' | head -1)
    [ -n "$_handle" ] && nft delete rule inet fw4 prerouting handle "$_handle" 2>/dev/null

    _handle=$(nft -a list chain inet fw4 output 2>/dev/null \
        | grep 'jump xray_output' | sed 's/.*handle //' | head -1)
    [ -n "$_handle" ] && nft delete rule inet fw4 output handle "$_handle" 2>/dev/null

    # Чистим цепочки
    nft flush chain inet fw4 xray_tproxy 2>/dev/null
    nft delete chain inet fw4 xray_tproxy 2>/dev/null
    nft flush chain inet fw4 xray_output 2>/dev/null
    nft delete chain inet fw4 xray_output 2>/dev/null

    while ip rule del fwmark 1 table 100 2>/dev/null; do :; done
    ip route flush table 100 2>/dev/null
    logger -t xray "Stopped, network restored"
}

service_triggers() {
    procd_add_reload_trigger "xray"
}
XRAYEOF

chmod +x /etc/init.d/xray
/etc/init.d/xray enable

echo "[+] init.d для Xray создан и включён"

# =============================================
# 9. Настраиваем routing
# =============================================
echo "9. Настраиваем routing..."

if ! grep -q "^100[[:space:]]\+xray$" /etc/iproute2/rt_tables; then
	echo "100 xray" >>/etc/iproute2/rt_tables
fi

echo "[+] Routing настроен"

# =============================================
# 10. Настраиваем sysctl
# =============================================
echo "10. Настраиваем sysctl:"

sysctl -w net.ipv4.conf.all.route_localnet=1
sysctl -w net.ipv4.ip_forward=1

cat >"/etc/sysctl.d/99-xray.conf" <<EOF
net.ipv4.conf.all.route_localnet=1
net.ipv4.ip_forward=1
EOF
sysctl -p /etc/sysctl.d/99-xray.conf >/dev/null 2>&1

echo "[+] Sysctl настроен"

# =============================================
# 11. Geo + HWID + config.json
# =============================================
echo "11. Скачиваем геофайлы, делаем HWID, генерируем config.json..."

update_geo() {
	local URL="$1"
	local DEST="$2"

	local BASE="$(basename "$DEST")"
	local TMP="/tmp/$BASE.tmp"
	local TMP_SHA="/tmp/$BASE.sha256"
	local SHA_FILE="${STATE_DIR}/${BASE}.sha256sum"

	echo "  → Скачиваем $BASE"

	download_file "${URL}.sha256sum" "$TMP_SHA" || {
		echo "  [X] Не удалось получить SHA256 для $BASE" >>"$LOG_FILE"
		exit 1
	}
	REMOTE_SHA="$(cut -d' ' -f1 "$TMP_SHA")"

	if [ -z "$REMOTE_SHA" ]; then
		echo "  [X] Не удалось получить SHA256 для $BASE" >>"$LOG_FILE"
		exit 1
	fi

	download_file "$URL" "$TMP" || {
		echo "  [X] Не удалось скачать $BASE" >>"$LOG_FILE"
		exit 1
	}

	LOCAL_SHA="$(sha256sum "$TMP" | awk '{print $1}')"

	if [ "$LOCAL_SHA" != "$REMOTE_SHA" ]; then
		echo "  [X] SHA не совпадает для $BASE" >>"$LOG_FILE"
		echo "ожидаемый: $REMOTE_SHA" >>"$LOG_FILE"
		echo "фактический:   $LOCAL_SHA" >>"$LOG_FILE"
		rm -f "$TMP" "$TMP_SHA"
		exit 1
	fi

	mv "$TMP" "$DEST"
	echo "$REMOTE_SHA" >"$SHA_FILE"

	echo "  ✓ $BASE скачан и проверен"
}

GEOIP_URL=$(settings_get ".geo.geoip_url")
GEOSITE_URL=$(settings_get ".geo.geosite_url")

update_geo "$GEOIP_URL" "$GEO_DIR/geoip.dat"
update_geo "$GEOSITE_URL" "$GEO_DIR/geosite.dat"

echo "  → Генерируем HWID..."
HWID="$(cat /proc/sys/kernel/random/uuid | tr -d '-')"
settings_set ".hwid" "$HWID"
echo "  ✓ HWID сохранён в settings.json: $HWID"

echo "  → Генерируем config.json из подписки..."

# Все значения — из единого settings.json
SUB_URL=$(settings_get ".subscription.url")
SUB_UA=$(settings_get ".subscription.user_agent")
HWID=$(settings_get ".hwid")
REMARKS=$(settings_get ".subscription.remarks_filter")

echo "  → URL: $SUB_URL"
echo "  → User-Agent: $SUB_UA"
echo "  → HWID: $HWID"

# Скачиваем подписку с заголовками
if download_file "$SUB_URL" "/tmp/sub_raw.txt" "x-hwid: $HWID"; then
    
    # Проверяем, что скачалось не HTML
    if head -n 1 "/tmp/sub_raw.txt" 2>/dev/null | grep -qi "<html\|<!DOCTYPE"; then
        echo "  [X] Подписка вернула HTML, а не данные"
        rm -f "/tmp/sub_raw.txt"
        exit 1
    fi
    
    # Единый пайплайн: парсер (с автоопределением формата) → генератор
    if [ -n "$REMARKS" ]; then
        python3 "$PARSER" --ua "$SUB_UA" --remarks "$REMARKS" < "/tmp/sub_raw.txt" > "/tmp/parsed_outbounds.json" 2>>"$LOG_FILE"
    else
        python3 "$PARSER" --ua "$SUB_UA" < "/tmp/sub_raw.txt" > "/tmp/parsed_outbounds.json" 2>>"$LOG_FILE"
    fi
    
    if [ $? -eq 0 ]; then
        if python3 "$GENERATOR" --format unified --output "$CONFIG_JSON" < "/tmp/parsed_outbounds.json" 2>>"$LOG_FILE"; then
            echo "  ✓ config.json создан"
        else
            echo "  [X] Ошибка генератора конфига"
            rm -f "/tmp/sub_raw.txt" "/tmp/parsed_outbounds.json"
            exit 1
        fi
    else
        echo "  [X] Ошибка парсера подписки"
        rm -f "/tmp/sub_raw.txt"
        exit 1
    fi
    rm -f "/tmp/sub_raw.txt" "/tmp/parsed_outbounds.json"
else
    echo "  [X] Не удалось скачать подписку"
    exit 1
fi

if [ ! -s "$CONFIG_JSON" ]; then
    echo "  [X] Ошибка: не удалось создать config.json" >>"$LOG_FILE"
    exit 1
fi
echo ""
echo "[+] Геофайлы загружены, конфиг сгенерирован"

# =============================================
# 12. Cron: автообновление в 2.30 ночи
# =============================================
echo "12. Настройка Crontab..."

uci set system.@system[0].cronloglevel='9'
uci commit system

CRON_ENTRY="30 2 * * * $UPDATER"
if ! crontab -l 2>/dev/null | grep -qF "$UPDATER"; then
	(
		crontab -l 2>/dev/null || true
		echo "$CRON_ENTRY"
	) | crontab -
	echo "[+] Cron-задача для обновления Xray добавлена: $CRON_ENTRY"
else
	echo "[-] Cron-задача уже существует, пропускаем"
fi

# =============================================
# 13. Настройка hotplug (автообновление после включения WAN)
# =============================================
echo "13. Настройка hotplug..."

cat >/etc/hotplug.d/iface/99-xray-autoupdate <<'EOF'
#!/bin/sh
[ "$ACTION" = "ifup" ] || exit 0
[ "$INTERFACE" = "wan" ] || exit 0

if ! pidof xray >/dev/null; then
    /etc/init.d/xray start
    sleep 5
fi

for i in 1 2 3 4 5 6 7; do
    sleep 5
    if curl -fs --max-time 3 https://www.google.com/gen_204 >/dev/null; then
        /usr/share/xray/update-xray.sh &
        exit 0
    fi
done
EOF

chmod +x /etc/hotplug.d/iface/99-xray-autoupdate
echo "[+] Hotplug для автообновления после включения WAN настроен"

# =============================================
# 14. Проверяем config.json
# =============================================
echo "14. Проверяем config.json на валидность..."
if xray run -test -config "$CONFIG_JSON" >/dev/null 2>&1; then
	echo "  ✓ $CONFIG_JSON прошел проверку"
else
	echo "  [X] $CONFIG_JSON НЕ прошел проверку!"
	exit 1
fi

# =============================================
# 15. Перезагрузка
# =============================================
echo "15. Перезагрузка для применения всех изменений..."
echo ""
echo "=== Установка завершена ==="
echo "Устройство будет перезагружено через 5 секунд..."
sleep 5
reboot