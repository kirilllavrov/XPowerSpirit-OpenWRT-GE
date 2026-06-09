#!/bin/sh
# OpenWrt — Настройка Wi-Fi (Home + Guest) для России
# Явное задание band + htmode

LOG="/tmp/setup-wifi.log"
: >"$LOG"
exec > >(tee -a "$LOG") 2>&1

echo "=== Настройка Wi-Fi (Россия, WPA2+WPA3, PMF) ==="

[ "$(id -u)" != "0" ] && {
	echo "[X] Требуются права root"
	exit 1
}

# === Значения по умолчанию ===
HOME_SSID="Home-WiFi"
HOME_PASS="HomeSecure123!"
GUEST_SSID="Guest-WiFi"
GUEST_PASS="GuestSecure123!"

# Парсер аргументов
for arg in "$@"; do
	case $arg in
	--ssid=*) HOME_SSID="${arg#*=}" ;;
	--pass=*) HOME_PASS="${arg#*=}" ;;
	--ssid-guest=*) GUEST_SSID="${arg#*=}" ;;
	--pass-guest=*) GUEST_PASS="${arg#*=}" ;;
	esac
done

# === Валидация ===
validate_len() {
	local val="$1" min="$2" max="$3"
	[ "${#val}" -lt "$min" ] || [ "${#val}" -gt "$max" ] && {
		echo "[X] Ошибка длины: $val (должно быть $min-$max символов)"
		exit 1
	}
}

validate_len "$HOME_SSID" 1 32
validate_len "$GUEST_SSID" 1 32
validate_len "$HOME_PASS" 8 63
validate_len "$GUEST_PASS" 8 63

# === Проверка существования гостевой сети ===
GUEST_EXISTS=0
if uci -q get network.guest >/dev/null 2>&1; then
	GUEST_EXISTS=1
	echo "[+] Обнаружена гостевая сеть (network.guest), будет настроен Guest Wi-Fi"
else
	echo "[-] Гостевая сеть не найдена (network.guest отсутствует), Guest Wi-Fi не будет настроен"
fi

# === Очистка ===
echo "Очистка существующих Wi-Fi интерфейсов..."
while uci -q delete wireless.@wifi-iface[0]; do :; done
uci commit wireless

# === Настройка radio (с явным band + htmode) ===
echo "Настройка radio устройств..."

for RADIO in $(uci show wireless | sed -n 's/^wireless\.\([^=]*\)=wifi-device.*/\1/p'); do
	echo "→ Настраиваем $RADIO"

	uci set wireless.${RADIO}.country='RU'
	uci set wireless.${RADIO}.country_ie='1'
	uci set wireless.${RADIO}.channel='auto'
	uci set wireless.${RADIO}.legacy_rates='0'
	uci set wireless.${RADIO}.cell_density='2'
	uci set wireless.${RADIO}.ieee80211w='1'
	uci set wireless.${RADIO}.wmm='1'
	uci set wireless.${RADIO}.disassoc_low_ack='0'

	# === ЯВНОЕ ЗАДАНИЕ band + htmode ===
	if uci get wireless.${RADIO}.band >/dev/null 2>&1; then
		CURRENT_BAND=$(uci get wireless.${RADIO}.band)
	else
		# Определяем по имени radio (стандартно radio0=2.4, radio1=5)
		case "$RADIO" in
		*0* | *2g*)
			CURRENT_BAND="2g"
			;;
		*)
			CURRENT_BAND="5g"
			;;
		esac
	fi

	uci set wireless.${RADIO}.band="$CURRENT_BAND"

	if [ "$CURRENT_BAND" = "2g" ]; then
		uci set wireless.${RADIO}.htmode='HT20'
	else
		uci -q set wireless.${RADIO}.htmode='HE80'
	fi

done

uci commit wireless

# === Home Wi-Fi ===
echo "Настройка Home Wi-Fi..."
for RADIO in $(uci show wireless | sed -n 's/^\(wireless\.\([^=]*\)\)=wifi-device.*/\2/p'); do
	uci set wireless.home_${RADIO}="wifi-iface"
	uci set wireless.home_${RADIO}.device="$RADIO"
	uci set wireless.home_${RADIO}.mode="ap"
	uci set wireless.home_${RADIO}.network="lan"
	uci set wireless.home_${RADIO}.ssid="$HOME_SSID"
	uci set wireless.home_${RADIO}.encryption="sae-mixed"
	uci set wireless.home_${RADIO}.key="$HOME_PASS"
	uci set wireless.home_${RADIO}.isolate="0"
	uci set wireless.home_${RADIO}.bridge_isolate="0"
	uci set wireless.home_${RADIO}.disabled="0"
done
uci commit wireless

# === Guest Wi-Fi (только если существует гостевая сеть) ===
if [ $GUEST_EXISTS -eq 1 ]; then
	echo "Настройка Guest Wi-Fi..."
	for RADIO in $(uci show wireless | sed -n 's/^\(wireless\.\([^=]*\)\)=wifi-device.*/\2/p'); do
		uci set wireless.guest_${RADIO}="wifi-iface"
		uci set wireless.guest_${RADIO}.device="$RADIO"
		uci set wireless.guest_${RADIO}.mode="ap"
		uci set wireless.guest_${RADIO}.network="guest"
		uci set wireless.guest_${RADIO}.ssid="$GUEST_SSID"
		uci set wireless.guest_${RADIO}.encryption="sae-mixed"
		uci set wireless.guest_${RADIO}.key="$GUEST_PASS"
		uci set wireless.guest_${RADIO}.isolate="1"
		uci set wireless.guest_${RADIO}.bridge_isolate="1"
		uci set wireless.guest_${RADIO}.disabled="0"
	done
	uci commit wireless
else
	echo "Пропускаем настройку Guest Wi-Fi (нет сети guest в /etc/config/network)"
fi

echo "  → Применяем изменения..."
wifi reload
sleep 3

echo "=== Wi-Fi успешно настроен ==="
echo "Home  : $HOME_SSID"
if [ $GUEST_EXISTS -eq 1 ]; then
	echo "Guest : $GUEST_SSID"
else
	echo "Guest : не настроен"
fi
echo "Режим : WPA2 + WPA3 (sae-mixed) | PMF Required"