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
GUEST_NET="guest"
GUEST_IP="192.168.10.1"
FREEDOM_NET="freedom"
FREEDOM_IP="192.168.20.1"

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
	--guest-ip=*) GUEST_IP="${arg#*=}" ;;
	--freedom-ip=*) FREEDOM_IP="${arg#*=}" ;;
	--sub=*) SUB_URL="${arg#*=}" ;;
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
    'if .subscription.domain_whitelist | index($d) then . else .subscription.domain_whitelist += [$d] end' \
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
# 5. Настраиваем гостевую сеть и лимиты скорости
# =============================================
echo "5. Настройка Guest Network и SQM:"

# 5.1. Guest Bridge + Interface
uci -q delete network.${GUEST_NET}_dev
uci set network.${GUEST_NET}_dev="device"
uci set network.${GUEST_NET}_dev.type="bridge"
uci set network.${GUEST_NET}_dev.name="br-${GUEST_NET}"
uci set network.${GUEST_NET}_dev.mtu="1500"

# Переносим lan4 из br-lan в br-guest
LAN_DEV=$(uci show network | sed -n "s/^\(network\.[^=]*\)\.name='br-lan'$/\1/p" | head -1)
if [ -n "$LAN_DEV" ]; then
    uci del_list ${LAN_DEV}.ports='lan4' 2>/dev/null
    echo "  → lan4 убран из br-lan"
fi
uci add_list network.${GUEST_NET}_dev.ports='lan4'
echo "  → lan4 добавлен в br-guest"

uci -q delete network.$GUEST_NET
uci set network.$GUEST_NET="interface"
uci set network.$GUEST_NET.proto="static"
uci set network.$GUEST_NET.device="br-${GUEST_NET}"
uci set network.$GUEST_NET.ipaddr="$GUEST_IP"
uci set network.$GUEST_NET.netmask="255.255.255.0"
uci set network.$GUEST_NET.force_link="1"
uci commit network
echo "  → Guest Bridge + Interface настроены: br-${GUEST_NET} (${GUEST_IP}/24)"

# 5.2. DHCP Guest
uci -q delete dhcp.$GUEST_NET
uci set dhcp.$GUEST_NET="dhcp"
uci set dhcp.$GUEST_NET.interface="$GUEST_NET"
uci set dhcp.$GUEST_NET.start="100"
uci set dhcp.$GUEST_NET.limit="150"
uci set dhcp.$GUEST_NET.leasetime="12h"
uci set dhcp.$GUEST_NET.force="1"
uci set dhcp.$GUEST_NET.ignore="0"
uci commit dhcp
echo "  → DHCP для Guest настроен: $GUEST_NET"

# 5.3. Firewall Guest Zone + Rules
uci -q delete firewall.$GUEST_NET
uci set firewall.$GUEST_NET="zone"
uci set firewall.$GUEST_NET.name="$GUEST_NET"
uci set firewall.$GUEST_NET.network="$GUEST_NET"
uci set firewall.$GUEST_NET.input="REJECT"
uci set firewall.$GUEST_NET.output="ACCEPT"
uci set firewall.$GUEST_NET.forward="REJECT"
uci set firewall.$GUEST_NET.masq="1"
uci set firewall.$GUEST_NET.mtu_fix="1"
echo "  → Firewall зона для Guest создана: $GUEST_NET"

# 5.4 Firewall DNS
uci -q delete firewall.${GUEST_NET}_dns
uci set firewall.${GUEST_NET}_dns="rule"
uci set firewall.${GUEST_NET}_dns.name="Allow-DNS-Guest"
uci set firewall.${GUEST_NET}_dns.src="$GUEST_NET"
uci set firewall.${GUEST_NET}_dns.dest_port="53"
uci set firewall.${GUEST_NET}_dns.proto="tcp udp"
uci set firewall.${GUEST_NET}_dns.target="ACCEPT"
echo "  → Firewall правило для DNS создано: $GUEST_NET"

# 5.5 Firewall DHCP
uci -q delete firewall.${GUEST_NET}_dhcp
uci set firewall.${GUEST_NET}_dhcp="rule"
uci set firewall.${GUEST_NET}_dhcp.name="Allow-DHCP-Guest"
uci set firewall.${GUEST_NET}_dhcp.src="$GUEST_NET"
uci set firewall.${GUEST_NET}_dhcp.dest_port="67-68"
uci set firewall.${GUEST_NET}_dhcp.proto="udp"
uci set firewall.${GUEST_NET}_dhcp.target="ACCEPT"
echo "  → Firewall правило для DHCP создано: $GUEST_NET"

# 5.6 Forward to WAN
uci -q delete firewall.${GUEST_NET}_wan
uci set firewall.${GUEST_NET}_wan="forwarding"
uci set firewall.${GUEST_NET}_wan.src="$GUEST_NET"
uci set firewall.${GUEST_NET}_wan.dest="wan"
uci commit firewall
echo "  → Firewall правило для доступа Guest в WAN создано: $GUEST_NET → wan"

echo "[+] Настройка Guest Network завершена (изменения применятся после перезагрузки)"

# =============================================
# 5b. Настраиваем сеть Freedom
# =============================================
echo "5b. Настройка Freedom Network:"

# 5b.1. Freedom Bridge + Interface
uci -q delete network.${FREEDOM_NET}_dev
uci set network.${FREEDOM_NET}_dev="device"
uci set network.${FREEDOM_NET}_dev.type="bridge"
uci set network.${FREEDOM_NET}_dev.name="br-${FREEDOM_NET}"
uci set network.${FREEDOM_NET}_dev.bridge_empty="1"
uci set network.${FREEDOM_NET}_dev.mtu="1500"

uci -q delete network.$FREEDOM_NET
uci set network.$FREEDOM_NET="interface"
uci set network.$FREEDOM_NET.proto="static"
uci set network.$FREEDOM_NET.device="br-${FREEDOM_NET}"
uci set network.$FREEDOM_NET.ipaddr="$FREEDOM_IP"
uci set network.$FREEDOM_NET.netmask="255.255.255.0"
uci set network.$FREEDOM_NET.force_link="1"
uci commit network
echo "  → Freedom Bridge + Interface настроены: br-${FREEDOM_NET} (${FREEDOM_IP}/24)"

# 5b.2. DHCP Freedom
uci -q delete dhcp.$FREEDOM_NET
uci set dhcp.$FREEDOM_NET="dhcp"
uci set dhcp.$FREEDOM_NET.interface="$FREEDOM_NET"
uci set dhcp.$FREEDOM_NET.start="100"
uci set dhcp.$FREEDOM_NET.limit="150"
uci set dhcp.$FREEDOM_NET.leasetime="12h"
uci set dhcp.$FREEDOM_NET.force="1"
uci set dhcp.$FREEDOM_NET.ignore="0"
uci commit dhcp
echo "  → DHCP для Freedom настроен: $FREEDOM_NET"

# 5b.3. Firewall Freedom Zone + Rules
uci -q delete firewall.$FREEDOM_NET
uci set firewall.$FREEDOM_NET="zone"
uci set firewall.$FREEDOM_NET.name="$FREEDOM_NET"
uci set firewall.$FREEDOM_NET.network="$FREEDOM_NET"
uci set firewall.$FREEDOM_NET.input="REJECT"
uci set firewall.$FREEDOM_NET.output="ACCEPT"
uci set firewall.$FREEDOM_NET.forward="REJECT"
uci set firewall.$FREEDOM_NET.masq="1"
uci set firewall.$FREEDOM_NET.mtu_fix="1"
echo "  → Firewall зона для Freedom создана: $FREEDOM_NET"

# 5b.4 Firewall DNS
uci -q delete firewall.${FREEDOM_NET}_dns
uci set firewall.${FREEDOM_NET}_dns="rule"
uci set firewall.${FREEDOM_NET}_dns.name="Allow-DNS-Freedom"
uci set firewall.${FREEDOM_NET}_dns.src="$FREEDOM_NET"
uci set firewall.${FREEDOM_NET}_dns.dest_port="53"
uci set firewall.${FREEDOM_NET}_dns.proto="tcp udp"
uci set firewall.${FREEDOM_NET}_dns.target="ACCEPT"
echo "  → Firewall правило для DNS создано: $FREEDOM_NET"

# 5b.5 Firewall DHCP
uci -q delete firewall.${FREEDOM_NET}_dhcp
uci set firewall.${FREEDOM_NET}_dhcp="rule"
uci set firewall.${FREEDOM_NET}_dhcp.name="Allow-DHCP-Freedom"
uci set firewall.${FREEDOM_NET}_dhcp.src="$FREEDOM_NET"
uci set firewall.${FREEDOM_NET}_dhcp.dest_port="67-68"
uci set firewall.${FREEDOM_NET}_dhcp.proto="udp"
uci set firewall.${FREEDOM_NET}_dhcp.target="ACCEPT"
echo "  → Firewall правило для DHCP создано: $FREEDOM_NET"

# 5b.6 Forward to WAN
uci -q delete firewall.${FREEDOM_NET}_wan
uci set firewall.${FREEDOM_NET}_wan="forwarding"
uci set firewall.${FREEDOM_NET}_wan.src="$FREEDOM_NET"
uci set firewall.${FREEDOM_NET}_wan.dest="wan"
uci commit firewall
echo "  → Firewall правило для доступа Freedom в WAN создано: $FREEDOM_NET → wan"

echo "[+] Настройка Freedom Network завершена (изменения применятся после перезагрузки)"

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