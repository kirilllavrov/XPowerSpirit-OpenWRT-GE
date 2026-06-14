#!/usr/bin/env python3
"""
Xray Config Generator for OpenWrt TProxy
Поддерживает три входных формата:
  --format unified - унифицированный JSON из xray-sub-parser.py (рекомендуемый)
  --format vless   - старый режим: VLESS outbounds из xray-sub-parser.py
  --format json    - старый режим: сырая JSON-подписка Happ/Sing-box/XPower

Специальная обработка "hole":
  Если в подписке обнаружен outbound с address="hole", генерируется DIRECT-конфиг
  (весь трафик идёт напрямую, прокси отключены). Это сигнал об окончании срока подписки.

Балансировка:
  Используется стратегия leastLoad с burstObservatory для выбора наиболее стабильного прокси.

Настройки:
  Читает /etc/xray/settings.json — единый конфигурационный файл:
    - domain_whitelist: список доменов для приоритетного выбора сервера
"""

import json
import sys
import re
import argparse
import os

# ============================================
#   КОНФИГУРАЦИЯ
# ============================================

SETTINGS_FILE = "/etc/xray/settings.json"

# Значения по умолчанию (переопределяются из settings.json)
DOMAIN_WHITELIST = []
ROUTING_CONFIG = {}


def load_settings():
    """Загружает настройки из /etc/xray/settings.json"""
    global DOMAIN_WHITELIST, ROUTING_CONFIG
    if os.path.isfile(SETTINGS_FILE):
        try:
            with open(SETTINGS_FILE) as f:
                settings = json.load(f)
            DOMAIN_WHITELIST = settings.get("subscription", {}).get("domain_whitelist", [])
            ROUTING_CONFIG = settings.get("routing", {})
        except Exception:
            pass


# ============================================
#   ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ============================================

def log_error(msg: str) -> None:
    """Выводит сообщение об ошибке в stderr"""
    print(msg, file=sys.stderr)


def normalize_tag(tag: str) -> str:
    """Нормализует тег для использования в Xray"""
    if not tag:
        return "proxy"
    tag = tag.replace(" ", "_")
    tag = tag.replace("(", "").replace(")", "")
    # Только буквы, цифры, дефис, подчёркивание
    tag = re.sub(r"[^0-9A-Za-zА-Яа-яЁё_\-]", "", tag)
    return tag or "proxy"


def normalize_outbound(ob: dict) -> dict:
    """
    Дополняет outbound из подписки недостающими полями.
    Добавляет sockopt (mark, tcpNoDelay, tcpKeepAliveInterval) и отключает mux.
    """
    # Убеждаемся, что streamSettings существует
    if "streamSettings" not in ob:
        ob["streamSettings"] = {}
    
    # Добавляем sockopt с правильными параметрами
    if "sockopt" not in ob["streamSettings"]:
        ob["streamSettings"]["sockopt"] = {}
    
    ob["streamSettings"]["sockopt"]["mark"] = 2
    ob["streamSettings"]["sockopt"]["tcpNoDelay"] = True
    ob["streamSettings"]["sockopt"]["tcpKeepAliveInterval"] = 30
    
    # Отключаем mux (не нужен для TProxy)
    if "mux" not in ob:
        ob["mux"] = {}
    ob["mux"]["enabled"] = False
    
    return ob


# ============================================
#   ФУНКЦИИ ДЛЯ JSON ФОРМАТА (Happ/Sing-box/XPower)
# ============================================

def load_json_subscription() -> list:
    """Загружает JSON-подписку из stdin (формат Happ/Sing-box/XPower)"""
    try:
        data = json.load(sys.stdin)
        if isinstance(data, list):
            return data
        return [data]
    except Exception as e:
        log_error(f"Failed to parse JSON subscription: {e}")
        return []


def has_hole_in_subscription(sub_data: list) -> bool:
    """
    Проверяет, есть ли в подписке outbound с адресом 'hole'.
    Это сигнал об окончании срока подписки.
    """
    for config in sub_data:
        if "outbounds" not in config:
            continue
        for ob in config["outbounds"]:
            try:
                addr = ob.get("settings", {}).get("vnext", [{}])[0].get("address", "")
                if addr == "hole":
                    return True
            except Exception:
                pass
    return False


def extract_outbounds_from_subscription(sub_data: list, remarks_filter: str = '') -> list:
    """
    Извлекает все outbounds из JSON-подписки.
    Пропускает служебные outbounds (freedom, blackhole, dns).
    Нормализует теги и добавляет недостающие поля.
    Если указан remarks_filter, выбирает только профиль с этим remarks.
    """
    all_outbounds = []
    seen_tags = set()
    found_profile = False
    
    for config in sub_data:
        config_remarks = config.get("remarks", "")
        
        # Фильтрация по remarks
        if remarks_filter:
            if remarks_filter.lower() not in config_remarks.lower():
                print(f"  → Пропускаем профиль: {config_remarks}", file=sys.stderr)
                continue
        
        found_profile = True
        print(f"  → Используем профиль: {config_remarks}", file=sys.stderr)
        
        if "outbounds" not in config:
            continue
        
        for ob in config["outbounds"]:
            # Пропускаем служебные outbounds
            protocol = ob.get("protocol", "")
            if protocol in ["freedom", "blackhole", "dns"]:
                continue
            
            # Нормализуем тег
            if "tag" not in ob or not ob["tag"]:
                ob["tag"] = "proxy"
            
            # Дедупликация тегов
            original_tag = ob["tag"]
            tag = normalize_tag(original_tag)
            counter = 2
            while tag in seen_tags:
                tag = f"{original_tag}-{counter}"
                tag = normalize_tag(tag)
                counter += 1
            ob["tag"] = tag
            seen_tags.add(tag)
            
            # Добавляем недостающие поля (sockopt, mux)
            ob = normalize_outbound(ob)
            
            all_outbounds.append(ob)
            print(f"  → Outbound: {tag} ({protocol})", file=sys.stderr)
    
    if remarks_filter and not found_profile:
        print(f"  [X] Профиль с remarks '{remarks_filter}' не найден!", file=sys.stderr)
        print(f"  → Доступные профили:", file=sys.stderr)
        for config in sub_data:
            config_remarks = config.get("remarks", "")
            print(f"      - {config_remarks}", file=sys.stderr)
    
    return all_outbounds


# ============================================
#   ФУНКЦИИ ДЛЯ VLESS ФОРМАТА (через парсер)
# ============================================

def load_vless_outbounds() -> list:
    """Загружает outbounds из stdin (формат от xray-sub-parser.py)"""
    try:
        data = json.load(sys.stdin)
        if isinstance(data, dict):
            return [data]
        if isinstance(data, list):
            return data
    except Exception:
        return []
    return []


def extract_address(ob):
    try:
        return ob["settings"]["vnext"][0]["address"]
    except Exception:
        return None


def extract_id(ob):
    try:
        return ob["settings"]["vnext"][0]["users"][0]["id"]
    except Exception:
        return None


def is_placeholder(ob):
    addr = extract_address(ob)
    uid = extract_id(ob)
    port = None
    try:
        port = ob["settings"]["vnext"][0]["port"]
    except Exception:
        pass
    return (
        uid == "00000000-0000-0000-0000-000000000000"
        or addr in ["0.0.0.0", "127.0.0.1", "hole"]
        or str(port) == "1"
    )


def has_hole(servers):
    for ob in servers:
        if extract_address(ob) == "hole":
            return True
    return False


def choose_best_server(servers):
    if not servers:
        return None
    servers = [s for s in servers if not is_placeholder(s)]
    if not servers:
        return None
    if DOMAIN_WHITELIST:
        for ob in servers:
            addr = extract_address(ob)
            if addr in DOMAIN_WHITELIST:
                return ob
    return servers[0]


def normalize_vless_outbound(ob: dict, chosen_tag: str) -> dict:
    """Нормализует outbound из VLESS формата (делегирует в normalize_outbound)"""
    if "tag" not in ob:
        ob["tag"] = chosen_tag
    return normalize_outbound(ob)


# ============================================
#   БАЗОВАЯ КОНФИГУРАЦИЯ
# ============================================

def base_config() -> dict:
    """Возвращает базовую конфигурацию Xray с TProxy и DNS"""
    return {
        "log": {
            "loglevel": "none",
            "access": "/tmp/log/xray-access.log",
            "error": "/tmp/log/xray-error.log"
        },
        "dns": {
            "tag": "dns-inbuilt",
            "queryStrategy": "UseIPv4",
            "disableCache": False,
            "serveStale": True,
            "serveExpiredTTL": 600,
            "disableFallback": False,
            "disableFallbackIfMatch": True,
            "enableParallelQuery": True,
            "hosts": {
                "common.dot.dns.yandex.net": ["77.88.8.1", "77.88.8.8"],
                "cloudflare-dns.com": ["1.0.0.1", "1.1.1.1"],
                "dns.nextdns.io": ["45.90.28.0", "45.90.30.0"]
            },
            "servers": [
                {
                    "address": "https+local://common.dot.dns.yandex.net/dns-query",
                    "domains": ["geosite:category-ru"],
                    "expectedIPs": ["geoip:ru"],
                    "skipFallback": True
                },
                {
                    "address": "https+local://cloudflare-dns.com/dns-query",
                    "skipFallback": False
                },
                {
                    "address": "https+local://dns.nextdns.io",
                    "skipFallback": False
                }
            ]
        },
        "inbounds": [
            {
                "tag": "tproxy-in",
                "listen": "0.0.0.0",
                "port": 12345,
                "protocol": "dokodemo-door",
                "settings": {
                    "network": "tcp,udp",
                    "followRedirect": True
                },
                "streamSettings": {
                    "sockopt": {
                        "tproxy": "tproxy"
                    }
                },
                "sniffing": {
                    "enabled": True,
                    "destOverride": ["http", "tls"],
                    "routeOnly": True
                }
            },
            {
                "tag": "dns-local",
                "listen": "127.0.0.1",
                "port": 5353,
                "protocol": "dokodemo-door",
                "settings": {
                    "network": "tcp,udp"
                }
            }
        ]
    }


def build_direct_outbound() -> dict:
    """Стандартный direct (freedom) outbound"""
    return {
        "protocol": "freedom",
        "tag": "direct",
        "settings": {"domainStrategy": "UseIPv4"},
        "streamSettings": {"sockopt": {"mark": 2, "tcpKeepAliveInterval": 30}}
    }


def build_block_outbound() -> dict:
    """Стандартный block (blackhole) outbound"""
    return {
        "protocol": "blackhole",
        "tag": "block",
        "settings": {"response": {"type": "http"}}
    }


def save_config(cfg: dict, path: str) -> None:
    """Сохраняет конфиг в файл"""
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    print(f"  ✓ Конфиг сохранён: {path}", file=sys.stderr)


def build_direct_config() -> dict:
    """Создаёт DIRECT-конфиг (без прокси) для режима 'hole'"""
    cfg = base_config()
    cfg["outbounds"] = [
        build_direct_outbound(),
        build_block_outbound(),
        build_dns_outbound()
    ]
    cfg["routing"] = {
        "domainStrategy": "IPOnDemand",
        "rules": build_rules([], direct_mode=True)
    }
    return cfg


def build_dns_outbound() -> dict:
    """Создаёт outbound 'dns-out' с hijack во встроенный DNS"""
    return {
        "protocol": "dns",
        "tag": "dns-out",
        "settings": {
            "rules": [
                {
                    "action": "hijack",
                    "qtype": "1,28"
                }
            ]
        }
    }


def build_rules(proxy_outbounds: list, direct_mode: bool = False) -> list:
    """
    Строит правила маршрутизации.
    Настраиваемые списки (block/direct/streaming/doh) читаются из ROUTING_CONFIG.
    Структурные правила (DNS hijack, NTP, QUIC, catch-all) — фиксированы.
    """
    rc = ROUTING_CONFIG  # краткий алиас

    rules = [
        # Клиентский DNS (от dnsmasq) → dns-out (hijack → dns-inbuilt)
        {
            "type": "field",
            "inboundTag": ["dns-local"],
            "outboundTag": "dns-out"
        },
        # Ловим DNS через DoH, которые прошли мимо dnsmasq (от браузера)
        {
            "type": "field",
            "domain": rc.get("doh_domains", []),
            "outboundTag": "direct"
        },
        # Блокировка (реклама, трекеры)
        {
            "type": "field",
            **rc.get("block", {}),
            "outboundTag": "block"
        },
        # NTP (порт 123) — напрямую
        {
            "type": "field",
            "port": "123",
            "network": "udp",
            "outboundTag": "direct"
        },
        # QUIC (UDP/443) — блокируем (VLESS+XTLS не поддерживает UDP)
        {
            "type": "field",
            "port": "443",
            "network": "udp",
            "outboundTag": "block"
        },
        # Прямые соединения (РФ, локальные)
        {
            "type": "field",
            **rc.get("direct", {}),
            "outboundTag": "direct"
        },
    ]

    if not direct_mode and proxy_outbounds:
        # Стриминг/игры — через балансировщик
        streaming = rc.get("streaming", {})
        if streaming:
            rules.append({
                "type": "field",
                **streaming,
                "balancerTag": "balancer"
            })

        # Всё остальное — через балансировщик
        rules.append({
            "type": "field",
            "network": "tcp,udp",
            "balancerTag": "balancer"
        })
    else:
        rules.append({
            "type": "field",
            "network": "tcp,udp",
            "outboundTag": "direct"
        })

    return rules


def build_balancer(proxy_outbounds: list) -> dict:
    """
    Создаёт конфигурацию балансировщика для нескольких прокси (leastLoad).    
    leastLoad выбирает наиболее стабильные серверы на основе данных burstObservatory.    
    Если все серверы не проходят — fallback на direct.
    """
    selector = [ob["tag"] for ob in proxy_outbounds]
    return {
        "tag": "balancer",
        "selector": selector,
        "strategy": {
            "type": "leastLoad",
        },
        "fallbackTag": "direct"
    }


def build_burst_observatory(proxy_outbounds: list) -> dict:
    """
    Создаёт конфигурацию burstObservatory для мониторинга прокси.
    Используется со стратегией leastLoad.
    
    Пингует connectivitycheck.gstatic.com (Google Connectivity Check) —
    более надёжный endpoint, чем google.com, не троттлится.
    GET вместо HEAD — лучше совместимость с прокси-протоколами.
    Таймаут 15s — с запасом на Reality/TLS handshake.
    """
    subject_selector = [ob["tag"] for ob in proxy_outbounds]
    return {
        "burstObservatory": {
            "subjectSelector": subject_selector,
            "pingConfig": {
                "destination": "http://connectivitycheck.gstatic.com/generate_204",
                "interval": "1m",
                "sampling": 10,
                "timeout": "15s",
                "httpMethod": "GET"
            }
        }
    }


def assemble_config(proxy_outbounds: list) -> dict:
    """
    Собирает полный конфиг Xray из списка прокси-outbounds.
    Единая точка сборки для всех форматов подписок.
    """
    cfg = base_config()
    cfg["outbounds"] = proxy_outbounds + [
        build_direct_outbound(),
        build_block_outbound(),
        build_dns_outbound()
    ]
    cfg.update(build_burst_observatory(proxy_outbounds))
    cfg["routing"] = {
        "domainStrategy": "IPOnDemand",
        "rules": build_rules(proxy_outbounds),
        "balancers": [build_balancer(proxy_outbounds)]
    }

    print(f"  ✓ Сгенерировано {len(proxy_outbounds)} прокси", file=sys.stderr)
    if len(proxy_outbounds) > 1:
        print(f"  ✓ Балансировщик: {len(proxy_outbounds)} серверов (leastLoad)", file=sys.stderr)
    else:
        print(f"  ✓ Балансировщик: 1 сервер + fallback DIRECT", file=sys.stderr)
    return cfg


# ============================================
#   ОСНОВНАЯ ФУНКЦИЯ
# ============================================

def parse_args():
    parser = argparse.ArgumentParser(description='Xray config generator for OpenWrt TProxy')
    parser.add_argument('--output', required=True, help='Output config file')
    parser.add_argument('--format', choices=['json', 'vless', 'unified'], default='vless',
                        help='Input format: unified (from xray-sub-parser --ua), '
                             'json (raw Happ/Sing-box/XPower), vless (parsed VLESS outbounds)')
    parser.add_argument('--remarks', default='', 
                        help='Filter outbounds by remarks (substring, case-insensitive). Only for JSON format')
    return parser.parse_args()


def main():
    args = parse_args()

    load_settings()
    if DOMAIN_WHITELIST:
        print(f"  → Domain whitelist из settings.json: {', '.join(DOMAIN_WHITELIST)}", file=sys.stderr)

    hole = False
    proxy_outbounds = []

    # ── ДИСПЕТЧЕР ФОРМАТОВ: получаем единый список proxy_outbounds ──
    if args.format == 'unified':
        print("  → Обработка унифицированной подписки", file=sys.stderr)
        try:
            data = json.load(sys.stdin)
        except Exception as e:
            log_error(f"Failed to parse unified input: {e}")
            sys.exit(1)
        hole = data.get("hole", False)
        raw_obs = data.get("outbounds", [])
        proxy_outbounds = [normalize_outbound(ob) for ob in raw_obs]

    elif args.format == 'json':
        print("  → Обработка JSON подписки", file=sys.stderr)
        subscription = load_json_subscription()
        if not subscription:
            log_error("Empty or invalid JSON subscription")
            sys.exit(1)
        hole = has_hole_in_subscription(subscription)
        proxy_outbounds = extract_outbounds_from_subscription(subscription, args.remarks)

    else:  # vless
        print("  → Обработка VLESS формата", file=sys.stderr)
        all_obs = load_vless_outbounds()
        hole = has_hole(all_obs)
        if not hole:
            chosen = choose_best_server(all_obs)
            if chosen is not None:
                tag = chosen.get("tag") or "proxy"
                tag = re.sub(r'[^\w\-]', '_', tag)[:64] or "proxy"
                chosen = normalize_vless_outbound(chosen, tag)
                proxy_outbounds = [chosen]

    # ── ЕДИНАЯ СБОРКА ──
    if hole:
        print("  [!] Обнаружен сервер 'hole' (срок подписки истёк).", file=sys.stderr)
        print("  [!] Включаем DIRECT-режим (весь трафик напрямую).", file=sys.stderr)
        cfg = build_direct_config()
    elif not proxy_outbounds:
        log_error("No valid outbounds — switching to DIRECT")
        cfg = build_direct_config()
    else:
        cfg = assemble_config(proxy_outbounds)

    save_config(cfg, args.output)


if __name__ == "__main__":
    main()