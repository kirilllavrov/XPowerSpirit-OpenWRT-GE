# XPowerSpirit-OpenWRT

Комплексное решение для настройки прокси-сервера Xray с TProxy на OpenWrt. Проект включает автоматическую установку Xray, настройку гостевой сети, управление подписками, генерацию конфигурации и автоматическое обновление.

## 📋 Содержание

- [Возможности](#-возможности)
- [Архитектура проекта](#-архитектура-проекта)
- [Требования](#-требования)
- [Быстрый старт](#-быстрый-старт)
- [Детальное описание скриптов](#-детальное-описание-скриптов)
  - [install-openwrt-xray.sh](#install-openwrtxraysh)
  - [setup-wifi-network.sh](#setup-wifi-networksh)
  - [setup-led-status.sh](#setup-led-statussh)
  - [update-xray.sh](#update-xraysh)
  - [update-nft.sh](#update-nftsh)
  - [xray-sub-parser.py](#xray-sub-parserpy)
  - [xray-generate-config.py](#xray-generate-configpy)
- [Структура файлов](#-структура-файлов)
- [Примеры использования](#-примеры-использования)
- [Troubleshooting](#-troubleshooting)

---

## ✨ Возможности

- **Автоматическая установка Xray** — загрузка последней версии с GitHub с проверкой целостности (SHA256)
- **TProxy через nftables** — прозрачная проксификация TCP/UDP трафика без необходимости настройки клиентов
- **Три изолированные сети** — Home (LAN), Guest (гостевая, напрямую), Freedom (прокси через Xray)
- **Работа с подписками** — парсинг VLESS-ссылок из URL подписки с поддержкой Reality, WebSocket, gRPC, HTTP, XHTTP
- **Умная генерация конфигурации** — выбор лучшего сервера, маршрутизация по гео-базам (RU/частный трафик напрямую)
- **Балансировка прокси** — leastLoad + burstObservatory с автоматическим fallback на direct
- **Автообновление** — ежедневное обновление Xray, geoip/geosite и конфигурации по расписанию
- **Hotplug-обновление** — автоматическое обновление после восстановления WAN-соединения
- **Безопасность WiFi** — WPA2+WPA3 (sae-mixed), PMF, изоляция клиентов гостевых сетей

---

## 🏗 Архитектура проекта

```
┌──────────────────────────────────────────────────────────────────┐
│                         OpenWrt Router                           │
│                                                                  │
│  ┌──────────┐  ┌───────────┐  ┌─────────────┐  ┌──────────────┐ │
│  │ Home WiFi│  │Guest WiFi │  │Freedom WiFi │  │ WAN (Internet)│ │
│  │ (br-lan) │  │(br-guest) │  │(br-freedom) │  │               │ │
│  │ 192.168  │  │ 192.168   │  │ 192.168     │  │               │ │
│  │  .1.0/24 │  │ .10.0/24  │  │ .20.0/24    │  │               │ │
│  └────┬─────┘  └─────┬─────┘  └──────┬──────┘  └───────┬───────┘ │
│       │              │               │                  │        │
│       │    напрямую  │   напрямую    │   TProxy         │        │
│       │    ────────► │   ────────►   │   ──────────┐    │        │
│       │              │               │             ▼    │        │
│       │              │               │     ┌───────────────┐    │
│       │              │               │     │   nftables    │◄───┤
│       │              │               │     │ TProxy :12345 │    │
│       │              │               │     └───────┬───────┘    │
│       │              │               │             │            │
│       │              │               │             ▼            │
│       │              │               │     ┌───────────────┐    │
│       └──────────────┴───────────────┴────►│   Xray Core   │◄───┘
│                                            │  (TProxy +    │     │
│                                            │   DNS 5353)   │     │
│                                            └───────────────┘     │
│                                                                  │
│  ┌───────────────────────────────────────────────────────────┐   │
│  │               Управление и обновления                     │   │
│  │  • update-xray.sh (cron: 2:30 nightly + hotplug)          │   │
│  │  • xray-sub-parser.py → xray-generate-config.py           │   │
│  │  • settings.json — единый конфигурационный файл           │   │
│  └───────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

### Разделение сетей

| Сеть | Интерфейс | Подсеть | Трафик | Изоляция |
|------|-----------|---------|--------|----------|
| Home (LAN) | `br-lan` + lan1–lan3 | `192.168.1.0/24` | Напрямую | Нет |
| Guest | `br-guest` + lan4 | `192.168.10.0/24` | Напрямую | Да (isolate + firewall REJECT) |
| Freedom | `br-freedom` | `192.168.20.0/24` | Через прокси (Xray) | Да (isolate + firewall REJECT) |

### Поток трафика

1. **Клиент Freedom-сети** → трафик попадает в цепочку `prerouting` nftables
2. **Клиент LAN/Guest** → bypass в nftables (`iifname return`), трафик идёт напрямую в WAN
3. **nftables (fw4 → xray_tproxy)**: фильтрация локальных адресов, DNS, DHCP, bypass серверов подписки, bypass LAN/Guest; трафик Freedom → TProxy на `127.0.0.1:12345`, mark `0x1`
4. **Policy routing**: пакеты с mark `0x1` → таблица 100 → `local 0.0.0.0/0 dev lo`
5. **INPUT chain**: `meta mark 0x1 accept` (до зонных правил fw4, чтобы обойти `input=REJECT` зоны freedom)
6. **Xray TProxy**: прозрачно перехватывает трафик, выполняет DNS-over-HTTPS через встроенный DNS
7. **Маршрутизация в Xray**:
   - `geoip:ru`, `geoip:private` → напрямую (`direct`)
   - `geosite:category-ru`, `geosite:private`, `geosite:category-browser` и т.д. → напрямую
   - `geosite:category-streaming`, `geosite:category-games` → прокси (балансировщик)
   - Остальной TCP/UDP → прокси (балансировщик)

---

## 📦 Требования

### Аппаратные

- Устройство с OpenWrt 25.12.x или совместимой версией
- Минимум 20 MB свободного места в `/tmp`
- Поддержка nftables (ядро 4.19+)

### Программные зависимости

```bash
curl ca-certificates nftables kmod-nft-tproxy kmod-nft-socket python3 resolveip unzip jq
```

---

## 🚀 Быстрый старт

### 1. Загрузка и минимальная установка

```bash
cd /tmp
curl -fsSL https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT-GE/main/install-openwrt-xray.sh | sh -s -- \
  --sub=https://your-subscription-url.com
```

**Параметры установки:**

| Параметр | Описание | По умолчанию |
|----------|----------|--------------|
| `--sub=URL` | URL подписки (обязательно) | — |
| `--sub-ua=STRING` | User-Agent для запроса подписки | `XPower/1.0` |
| `--remarks=STRING` | Фильтр профиля по remarks (для JSON-подписок) | — |
| `--guest-ip=IP` | IP-адрес шлюза гостевой сети | `192.168.10.1` |
| `--freedom-ip=IP` | IP-адрес шлюза Freedom-сети | `192.168.20.1` |
| `--dwl=DOMAIN` | Домен для whitelist (приоритет при выборе сервера) | — |

### 2. Настройка Wi-Fi (опционально)

```bash
curl -fsSL https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT-GE/main/setup-wifi-network.sh | sh -s -- \
  --ssid=Home-WiFi \
  --pass=MySecurePass123 \
  --ssid-guest=Guest-WiFi \
  --pass-guest=GuestPass456
```

### 3. Настройка LED-индикации

```bash
curl -fsSL https://raw.githubusercontent.com/kirilllavrov/XPowerSpirit-OpenWRT-GE/main/setup-led-status.sh | sh
```

---

## 📜 Детальное описание скриптов

### install-openwrt-xray.sh

**Назначение:** Полный цикл установки и настройки Xray TProxy на OpenWrt.

**Что делает:**

1. **Настройка времени** — устанавливает таймзону `Europe/Moscow` (MSK-3), синхронизирует NTP
2. **Загрузка скриптов** — скачивает `xray-generate-config.py`, `xray-sub-parser.py`, `update-xray.sh`, `update-nft.sh` из репозитория
3. **Сохранение настроек** — записывает URL подписки, User-Agent, фильтр remarks, HWID и домен в whitelist в единый JSON-файл `/etc/xray/settings.json` (файл инициализируется из `settings.default.json` в репозитории)
4. **Отключение IPv6** — отключает на LAN/WAN, останавливает `odhcpd`
5. **Настройка сетей**:
   - **Guest** (`br-guest`, `192.168.10.0/24`): bridge, DHCP (`.100-.249`, аренда 12ч), firewall-зона с изоляцией от LAN
   - **Freedom** (`br-freedom`, `192.168.20.0/24`): bridge, DHCP (`.100-.249`, аренда 12ч), firewall-зона с изоляцией от LAN
   - Порт **lan4** выводится из `br-lan` и добавляется в `br-guest`
6. **Установка Xray**:
   - Загружает последнюю версию с GitHub
   - Проверяет SHA256 через `.dgst` файл
   - Кэширует ZIP при повторной установке (по SHA)
7. **Загрузка вспомогательных скриптов** в `/usr/share/xray/`
8. **Настройка DNS** — dnsmasq → `127.0.0.1:5353` (Xray DNS) + fallback `77.88.8.8`
9. **Init-скрипт** — `/etc/init.d/xray` с прокачкой времени, ожиданием сети, проверкой конфига
10. **Маршрутизация** — таблица `xray` (ID 100) в `/etc/iproute2/rt_tables`
11. **Sysctl** — `route_localnet`, `ip_forward`
12. **Гео-базы** — `geoip.dat` / `geosite.dat` с проверкой SHA256
13. **HWID** — уникальный ID устройства (UUID)
14. **Генерация config.json** — автоматическое определение формата подписки:
    - **Base64 (VLESS URI)** — через `xray-sub-parser.py` + `xray-generate-config.py`
    - **JSON (Happ/Sing-box)** — напрямую через `xray-generate-config.py --format json`
15. **Cron** — автообновление в 2:30 ночи
16. **Hotplug** — автообновление при подъёме WAN (`ifup wan`)

**Логирование:** Все этапы записываются в `/tmp/xray_install.log`

---

### setup-led-status.sh

**Назначение:** Настройка LED-индикации статуса интернета и активности Xray.

**Поддерживаемые устройства:** Проверено на Cudy WR3000S v1.

**Функционал:**

1. **LED Xray_Status (white:wps)**:
   - Мигает при сетевом трафике через loopback (`lo`)
   - Триггер: `netdev`, режим: `tx rx`, интервал: 100 мс
   - Индикация активной проксификации

2. **LED Интернет (white:wan-online)**:
   - Горит при доступности интернета
   - Проверка через `curl https://www.google.com/gen_204` каждые 1 минуту
   - Скрипт проверки: `/usr/share/xray/net-check.sh`

**Результат:**

- `white:wps` — мигает при трафике Xray
- `white:wan-online` — горит при наличии интернета

---

### setup-wifi-network.sh

**Назначение:** Настройка двухдиапазонного Wi-Fi с разделением на домашнюю, гостевую и Freedom-сети.

**Особенности:**

- **Безопасность:** WPA2+WPA3 mixed mode (`sae-mixed`) с обязательным PMF
- **Изоляция клиентов** — в гостевой и Freedom-сетях клиенты не видят друг друга
- **Country RU** — оптимизировано для России
- **Три сети**: Home (LAN), Guest (изолированная, напрямую), Freedom (изолированная, через прокси)

**Параметры:**

| Параметр | Описание | По умолчанию |
|----------|----------|--------------|
| `--ssid=NAME` | SSID домашней сети | `Home-WiFi` |
| `--pass=PASS` | Пароль домашней сети | `HomeSecure123!` |
| `--ssid-guest=NAME` | SSID гостевой сети | `Guest-WiFi` |
| `--pass-guest=PASS` | Пароль гостевой сети | `GuestSecure123!` |
| `--ssid-freedom=NAME` | SSID Freedom-сети | `Freedom-WiFi` |
| `--pass-freedom=PASS` | Пароль Freedom-сети | `FreedomSecure123!` |

**Валидация:**

- SSID: 1-32 символа
- Пароль: 8-63 символа

**Логирование:** `/tmp/setup-wifi.log`

---

### update-xray.sh

**Назначение:** Автоматическое обновление Xray, гео-баз и конфигурации.

**Выполняет:**

1. **Ротация логов** — очищает логи при превышении 1MB
2. **Проверка HWID и подписки** — читает все настройки из единого `/etc/xray/settings.json`
3. **Обновление Xray**:
   - Скачивает `.dgst` с GitHub, сверяет SHA256
   - Скачивает ZIP только если SHA изменился
   - Останавливает Xray, обновляет бинарник, проверяет целостность
4. **Обновление geoip/geosite**:
   - Загружает с GitHub с проверкой SHA256
   - Кэширует SHA256 в `/etc/xray/state/`
   - Атомарное обновление (mv)
5. **Пересборка config.json** (автоопределение формата подписки):

   **По User-Agent:**
   - `*happ*`, `*singbox*`, `*karing*`, `*sfa*`, `*sfi*`, `*sfm*`, `*sft*` → **JSON формат** (напрямую `xray-generate-config.py --format json`)
   - Любой другой → **Base64/VLESS формат** (через `xray-sub-parser.py` + `xray-generate-config.py`)

   Для JSON формата поддерживается фильтрация по `--remarks` из файла `sub_remarks`.
   
   Готовый конфиг проверяется через `xray run -test` перед установкой.

6. **Пересборка nftables** — вызывает `update-nft.sh`
7. **Перезапуск Xray** — применяет новые настройки

**Отказоустойчивость:** Если новый конфиг невалиден — старый остаётся, Xray не перезапускается. Если конфиг отсутствует — Xray останавливается.

**Логирование:** `/tmp/log/xray-update.log`

**Запуск:** Вручную или автоматически:

- Cron: `30 2 * * *` (ежедневно в 2:30)
- Hotplug: при событии `ifup wan`

---

### update-nft.sh

**Назначение:** Применение правил nftables для TProxy (интеграция с fw4 OpenWrt).

**Алгоритм:**

1. **Policy Routing**:

   ```bash
   ip rule add fwmark 1 table 100
   ip route add local 0.0.0.0/0 dev lo table 100
   ```

2. **Извлечение IP серверов** — парсит `config.json` через Python для исключения их из TProxy

3. **Создание/обновление цепочки `xray_tproxy`** в таблице `inet fw4`:
   - **Bypass**: локальные адреса (127.0.0.0/8, RFC1918, link-local), DNS-резолверы, DHCP (порт 67-68)
   - **Bypass прокси-серверов**: IP адреса серверов подписки
   - **Bypass LAN** (`br-lan`) — домашняя сеть не проксируется
   - **Bypass гостевой сети** (`br-guest`) — гостевая сеть не проксируется
   - **Bypass самого Xray**: `meta mark 2 return` (чтобы не зацикливать трафик)
   - **TProxy для Freedom** (`br-freedom`): TCP/UDP → `tproxy ip to 127.0.0.1:12345`, `meta mark set 0x1`
   - **Блокировка QUIC**: UDP/443 с Freedom (VLESS+XTLS не поддерживает UDP)
   - **TProxy для трафика роутера**: пакеты с mark `0x1` (из OUTPUT) → `tproxy to 127.0.0.1:12345`

4. **Создание/обновление цепочки `xray_output`** (OUTPUT — трафик самого роутера):
   - Bypass: mark 2, локальные адреса, DNS, DHCP, IP серверов
   - Маркировка `mark 1` для TCP/UDP → перенаправление через PREROUTING → TProxy

5. **Accept в INPUT** — `meta mark 0x1 accept` вставляется в начало цепочки `input`, до зонных правил fw4 (чтобы `input=REJECT` зоны freedom не дропал TProxy-пакеты)

6. Цепочка `xray_tproxy` вызывается из `prerouting` через `jump xray_tproxy`

---

### xray-sub-parser.py

**Назначение:** Парсинг URL подписки и преобразование VLESS-ссылок в JSON-аутбаунды для Xray.

**Поддерживаемые протоколы:**

- VLESS over TCP
- VLESS over WebSocket (WS)
- VLESS over gRPC
- VLESS over HTTP/HTTP2
- VLESS over XHTTP (с поддержкой `extra` JSON)

**Поддерживаемые режимы безопасности:**

- None (без шифрования)
- TLS (с SNI, ALPN, fingerprint, allowInsecure)
- Reality (с publicKey, shortId, spiderX)

**Функции:**

1. **Логирование** — ошибки пишутся в syslog (ident: `xray-parser`) и stderr
2. **Нормализация тегов** — очистка названий серверов от спецсимволов, замена пробелов на `_`
3. **Загрузка URL** — автоматическое скачивание, если входные данные — HTTP(S) URL (с проверкой на HTML-ошибку)
4. **Base64-декодирование** — умное определение (URL-safe, с/без padding), нужно ли декодировать
5. **Парсинг query-параметров**:
   - `encryption`, `flow`, `type` (транспорт)
   - `security`, `sni`, `fp`, `alpn`, `allowInsecure`
   - `pbk`, `sid`, `spx` (Reality)
   - `path`, `host`, `serviceName`, `mode`, `extra` (транспорт)

**Входные данные:** Чтение из stdin (URL подписки или base64-строка)

**Выходные данные:** JSON-массив аутбаундов формата Xray

**Пример использования:**

```bash
cat subscription.txt | python3 xray-sub-parser.py > outbounds.json
```

**Пример выхода:**

```json
[
  {
    "tag": "proxy-vless-0",
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "example.com",
        "port": 443,
        "users": [{"id": "uuid...", "encryption": "none", "flow": "xtls-rprx-vision"}]
      }]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "serverName": "example.com",
        "publicKey": "...",
        "shortId": "...",
        "fingerprint": "chrome"
      }
    }
  }
]
```

---

### xray-generate-config.py

**Назначение:** Генерация полного `config.json` для Xray на основе распарсенных аутбаундов.

**Входные данные:** JSON-массив аутбаундов (через stdin)

**Поддерживаемые форматы:**

- `--format vless` — аутбаунды из `xray-sub-parser.py` (выбирается лучший сервер)
- `--format json` — JSON-подписка Happ/Sing-box (все прокси, с опциональным фильтром `--remarks`)

**Выходные данные:** Полный конфиг Xray с inbound, outbound, routing, DNS, burstObservatory

**Ключевые функции:**

1. **Выбор лучшего сервера** (только для `--format vless`):
   - Фильтрация заглушек (UUID `0000...`, адрес `0.0.0.0`/`127.0.0.1`/`hole`, порт `1`)
   - Приоритет доменов из `DOMAIN_WHITELIST`
   - Выбор первого доступного сервера

2. **Множественные прокси и балансировка** (только для `--format json`):
   - Все найденные outbounds добавляются в конфиг
   - Если прокси > 1 — создаётся **балансировщик** (стратегия `leastLoad`)
   - **burstObservatory** на корневом уровне — мониторинг пингами (`HEAD` к `google.com/generate_204`)
   - Балансировщик использует результаты observatory для выбора наименее нагруженного сервера

3. **Режим "hole" (DIRECT-конфиг)**:
   - Если в подписке обнаружен сервер с адресом `"hole"` — генерируется конфиг без прокси
   - Весь трафик идёт напрямую (`direct`), реклама блокируется
   - Полезно при окончании срока подписки

4. **Базовая конфигурация:**
   - **Логирование:** access/error логи в `/tmp/log/`
   - **DNS:**
     - Yandex DoH (`common.dot.dns.yandex.net`) для `.ru` доменов
     - Cloudflare DoH (`cloudflare-dns.com`), NextDNS (`dns.nextdns.io`)
     - Стратегия: `UseIPv4`, `serveStale`, параллельные запросы
   - **Inbound:**
     - `tproxy-in`: порт 12345, dokodemo-door, TProxy, сниффинг http/tls
     - `dns-local`: порт 5353, UDP, для приёма DNS от dnsmasq

5. **Правила маршрутизации:**
   - DNS-трафик (с `dns-local`) → `dns-out` (hijack во встроенный DNS)
   - DoH-домены → `direct` (чтобы DNS-запросы не уходили в прокси)
   - `geosite:category-ads` → `block`
   - NTP (порт 123/UDP) → `direct`
   - `geoip:ru`, `geoip:private` → `direct`
   - `geosite:private`, `geosite:category-browser`, `geosite:category-cdn-ru`, `geosite:category-mobile`, `geosite:category-ru` → `direct`
   - `geosite:category-streaming`, `geosite:category-games` → прокси/балансировщик
   - `QUIC (UDP/443)` → `block` (VLESS+XTLS не поддерживает UDP)

   > **Важно:** QUIC/UDP-443 блокируется на двух уровнях:
   > 1. В nftables (до Xray) — только с `br-lan`
   > 2. В Xray routing — для любого источника, включая трафик с самого роутера
   >
   > Это предотвращает ошибку `XTLS rejected UDP/443 traffic`

6. **Stream settings:**
   - `mark: 0` — исключение трафика Xray из TProxy
   - `tcpKeepAliveInterval: 30`
   - Mux отключён

7. **Freedom (direct) outbound** — использует `domainStrategy: "UseIPv4"` для корректной работы в IPv4-only среде

8. **Blackhole (block) outbound** — возвращает HTTP 403 вместо глухого закрытия соединения, чтобы браузер сразу показывал ошибку, а не висел в таймауте

**Режим без серверов:** Если все сервера — заглушки, создаётся DIRECT-конфиг.

**Примеры использования:**

```bash
# VLESS формат (через парсер)
python3 xray-sub-parser.py < subscription.url | \
python3 xray-generate-config.py --format vless --output /etc/xray/config.json

# JSON формат (Happ/Sing-box)
python3 xray-generate-config.py --format json --output /etc/xray/config.json < subscription.json

# JSON формат с фильтром по remarks
python3 xray-generate-config.py --format json --remarks "best" --output config.json < sub.json
```

---

## 📁 Структура файлов

```
/etc/xray/
├── settings.json         # 🔥 ЕДИНЫЙ конфигурационный файл (см. ниже)
├── config.json           # Активная конфигурация Xray (генерируется автоматически)
├── gateway_ip            # IP шлюза (создаётся при старте, transient)
└── state/
    ├── xray.zip.sha256sum
    ├── xray.dgst
    ├── geoip.dat.sha256sum
    └── geosite.dat.sha256sum

/usr/share/xray/
├── xray-generate-config.py
├── xray-sub-parser.py
├── update-xray.sh
├── update-nft.sh
├── net-check.sh          # Скрипт проверки интернета для LED
├── geoip.dat             # Гео-база IP-адресов
└── geosite.dat           # Гео-база доменов

/etc/init.d/xray          # Init-скрипт для управления службой
/etc/hotplug.d/iface/99-xray-autoupdate  # Автообновление при ifup wan

/tmp/log/
├── xray-access.log       # Логи доступа Xray
├── xray-error.log        # Логи ошибок Xray
├── xray-update.log       # Логи обновлений
├── xray_install.log      # Логи установки
└── setup-wifi.log        # Логи настройки Wi-Fi
```

### settings.json — единый конфигурационный файл

Все настройки проекта хранятся в одном JSON-файле `/etc/xray/settings.json`:

```json
{
  "subscription": {
    "url": "https://your-subscription-url.com",
    "user_agent": "XPower/1.0",
    "remarks_filter": ""
  },
  "hwid": "a1b2c3d4e5f6...",
  "device_model": "Cudy WR3000S v1",
  "device_os": "OpenWrt",
  "ver_os": "25.12.4",
  "domain_whitelist": [
    "router.freenternet.top"
  ],
  "geo": {
    "geoip_url": "https://raw.githubusercontent.com/kirilllavrov/geoip-builder/release/geoip.dat",
    "geosite_url": "https://raw.githubusercontent.com/kirilllavrov/geosite-builder/release/geosite.dat"
  }
}
```

**Описание полей:**

| Путь | Тип | Описание |
|------|-----|----------|
| `subscription.url` | string | URL подписки |
| `subscription.user_agent` | string | User-Agent для запроса подписки |
| `subscription.remarks_filter` | string | Фильтр профиля по remarks (для JSON-подписок) |
| `hwid` | string | Уникальный ID устройства (UUID без дефисов) |
| `device_model` | string | Модель устройства (из dmesg) |
| `device_os` | string | Операционная система (DISTRIB_ID) |
| `ver_os` | string | Версия ОС (DISTRIB_RELEASE) |
| `domain_whitelist` | array | Домены для приоритетного выбора сервера |
| `geo.geoip_url` | string | URL geoip.dat |
| `geo.geosite_url` | string | URL geosite.dat |

> **Примечание:** Настройки сетей (`--guest-ip=`, `--freedom-ip=`) — это параметры установочного скрипта. Они применяются в UCI напрямую и не сохраняются в `settings.json`.

**Чтение/запись из командной строки:**

```bash
# Прочитать значение
jq -r '.subscription.url' /etc/xray/settings.json

# Изменить значение
jq --arg d 'new-domain.com' \
    'if .domain_whitelist | index($d) then . else .domain_whitelist += [$d] end' \
    /etc/xray/settings.json > /tmp/settings.tmp && mv /tmp/settings.tmp /etc/xray/settings.json
```

---

## 💡 Примеры использования

### Обновление подписки вручную

```bash
# Прочитать настройки из единого JSON-конфига
HWID=$(jq -r '.hwid' /etc/xray/settings.json)
SUB_URL=$(jq -r '.subscription.url' /etc/xray/settings.json)
SUB_UA=$(jq -r '.subscription.user_agent' /etc/xray/settings.json)

# Скачать подписку
curl -s -L -H "User-Agent: $SUB_UA" -H "x-hwid: $HWID" "$SUB_URL" > /tmp/sub.txt
```

**Для VLESS (Base64) подписки:**
```bash
python3 /usr/share/xray/xray-sub-parser.py < /tmp/sub.txt | \
python3 /usr/share/xray/xray-generate-config.py --format vless --output /etc/xray/config.json
```

**Для JSON (Happ/Sing-box) подписки:**
```bash
python3 /usr/share/xray/xray-generate-config.py --format json --output /etc/xray/config.json < /tmp/sub.txt
```

**С фильтром по remarks (JSON):**
```bash
python3 /usr/share/xray/xray-generate-config.py --format json --remarks "best" --output /etc/xray/config.json < /tmp/sub.txt
```

**Проверить и перезапустить:**
```bash
xray run -test -config /etc/xray/config.json && service xray restart
```

### Проверка статуса

```bash
# Статус службы
service xray status

# Просмотр логов
tail -f /tmp/log/xray-error.log
```

### Изменение IP-адресов сетей

```bash
# Изменить IP гостевой сети
uci set network.guest.ipaddr='192.168.50.1'
uci commit network
service network restart
```

### Добавление своего домена в whitelist

Добавить домен в `settings.json` (не нужно редактировать Python-скрипты):

```bash
jq --arg d 'your-custom-domain.com' \
    'if .domain_whitelist | index($d) then . else .domain_whitelist += [$d] end' \
    /etc/xray/settings.json > /tmp/settings.tmp && mv /tmp/settings.tmp /etc/xray/settings.json
```

Затем перегенерировать конфиг через `update-xray.sh`.

---

## 🔧 Troubleshooting

### Сайты не грузятся, но Xray запущен

1. **Проверьте правила nftables:**

   ```bash
   nft list chain inet fw4 xray_tproxy
   ip rule show | grep fwmark
   ip route show table 100
   ```

2. **Проверьте исключение DNS в nftables:**

   ```bash
   nft list chain inet fw4 xray_tproxy | grep 53
   ```

   Должно быть правило с `return` для порта 53.

3. **Проверьте dnsmasq:**

   ```bash
   uci show dhcp.@dnsmasq[0].server
   ```

   Должно быть: `127.0.0.1#5353`

4. **Автоматическое исправление (если диагностика выявила проблемы):**

   ```bash
   # Если TProxy правила отсутствуют:
   /usr/share/xray/update-nft.sh
   
   # Если dnsmasq не настроен:
   uci set dhcp.@dnsmasq[0].noresolv='1'
   uci add_list dhcp.@dnsmasq[0].server='127.0.0.1#5353'
   uci commit && service dnsmasq restart
   ```

### Ошибка: " Недостаточно места в /tmp"

Очистите временные файлы:

```bash
rm -rf /tmp/xray_*
rm -f /tmp/*.log
```

### Конфиг не проходит валидацию

Проверьте логи парсера:

```bash
HWID=$(jq -r '.hwid' /etc/xray/settings.json)
SUB_URL=$(jq -r '.subscription.url' /etc/xray/settings.json)

curl -s -L -H "x-hwid: $HWID" "$SUB_URL" | \
  python3 /usr/share/xray/xray-sub-parser.py 2>&1 | tee /tmp/debug.json
```

### Geo-файлы не загружаются

Проверьте доступность CDN:

```bash
curl -I https://cdn.jsdelivr.net/gh/kirilllavrov/geoip-builder@release/geoip.dat
```

Если недоступно — попробуйте альтернативный источник или обновите позже.

### Гостевая сеть не работает

1. Проверьте, создан ли интерфейс:

   ```bash
   uci show network.guest
   ```

2. Проверьте firewall:

   ```bash
   uci show firewall.guest
   ```

3. Перезапустите службы:

   ```bash
   service network restart
   service firewall restart
   service dnsmasq restart
   ```

---

## 📄 Лицензия

Проект распространяется под лицензией MIT. См. файл [LICENSE](LICENSE).

## 👤 Автор

- GitHub: [@kirilllavrov](https://github.com/kirilllavrov)
- Репозиторий: [XPowerSpirit-OpenWRT](https://github.com/kirilllavrov/XPowerSpirit-OpenWRT)

## 🤝 Вклад в проект

Pull requests приветствуются! Для серьёзных изменений сначала создайте issue для обсуждения.

## 📮 Контакты

По вопросам и предложениям обращайтесь через GitHub Issues.
