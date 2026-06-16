#!/usr/bin/env python3
"""
Xray Status Dashboard для OpenWrt
Читает /etc/xray/settings.json и /etc/xray/config.json,
выводит сводку о состоянии системы.

Использование:
  xray-status              # краткий дашборд (по умолчанию)
  xray-status --full       # полный дашборд со списком прокси
  xray-status --json       # вывод в JSON (для интеграций)
  xray-status --subscription  # только информация о подписке
  xray-status --proxies    # только список прокси
  xray-status --routing    # только настройки роутинга
  xray-status --health     # проверка здоровья (Xray запущен? порты? конфиг валиден?)
"""

import json
import os
import sys
import argparse
import subprocess
from datetime import datetime

SETTINGS_FILE = "/etc/xray/settings.json"
CONFIG_FILE = "/etc/xray/config.json"


# ============================================
#   ЗАГРУЗКА ДАННЫХ
# ============================================

def load_json(path: str) -> dict:
    """Загружает JSON-файл, возвращает {} при ошибке"""
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}


def load_settings() -> dict:
    return load_json(SETTINGS_FILE)


def load_config() -> dict:
    return load_json(CONFIG_FILE)


# ============================================
#   ПРОВЕРКА ЗДОРОВЬЯ
# ============================================

def check_xray_running() -> bool:
    """Проверяет, запущен ли процесс Xray"""
    try:
        result = subprocess.run(["pgrep", "-x", "xray"], capture_output=True, text=True, timeout=3)
        return result.returncode == 0
    except Exception:
        return False


def check_xray_port() -> bool:
    """Проверяет, слушается ли порт TProxy"""
    try:
        result = subprocess.run(
            ["ss", "-tuln"], capture_output=True, text=True, timeout=3
        )
        return ":12345" in result.stdout
    except Exception:
        try:
            result = subprocess.run(
                ["netstat", "-tuln"], capture_output=True, text=True, timeout=3
            )
            return ":12345" in result.stdout
        except Exception:
            return False


def check_config_valid() -> tuple[bool, str]:
    """Проверяет валидность config.json через xray run -test"""
    if not os.path.isfile(CONFIG_FILE):
        return False, "config.json отсутствует"
    try:
        result = subprocess.run(
            ["xray", "run", "-test", "-config", CONFIG_FILE],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            return True, "OK"
        else:
            return False, result.stderr.strip().split("\n")[-1] or "невалиден"
    except FileNotFoundError:
        return False, "xray не установлен"
    except Exception as e:
        return False, str(e)


def check_nftables() -> bool:
    """Проверяет наличие цепочки xray_tproxy в nftables"""
    try:
        result = subprocess.run(
            ["nft", "list", "chain", "inet", "fw4", "xray_tproxy"],
            capture_output=True, text=True, timeout=3
        )
        return "tproxy ip to 127.0.0.1:12345" in result.stdout
    except Exception:
        return False


# ============================================
#   ФОРМАТИРОВАНИЕ
# ============================================

def green(text: str) -> str:
    return f"\033[32m{text}\033[0m"


def red(text: str) -> str:
    return f"\033[31m{text}\033[0m"


def yellow(text: str) -> str:
    return f"\033[33m{text}\033[0m"


def bold(text: str) -> str:
    return f"\033[1m{text}\033[0m"


def status_icon(ok: bool) -> str:
    return green("✓") if ok else red("✗")


def separator(char: str = "─", width: int = 60) -> str:
    return char * width


def section(title: str) -> str:
    return f"\n{bold('═══ ' + title + ' ')}{separator('═', max(0, 54 - len(title)))}"


# ============================================
#   ВЫВОД: ПРОВЕРКА ЗДОРОВЬЯ
# ============================================

def render_health() -> str:
    """Формирует секцию проверки здоровья"""
    lines = [section("ПРОВЕРКА ЗДОРОВЬЯ")]

    xray_ok = check_xray_running()
    lines.append(f"  Xray запущен:          {status_icon(xray_ok)}")

    port_ok = check_xray_port()
    lines.append(f"  Порт TProxy (:12345):  {status_icon(port_ok)}")

    config_ok, config_msg = check_config_valid()
    lines.append(f"  Конфиг валиден:        {status_icon(config_ok)}  ({config_msg})")

    nft_ok = check_nftables()
    lines.append(f"  nftables TProxy:       {status_icon(nft_ok)}")

    # Общий статус
    all_ok = xray_ok and port_ok and config_ok and nft_ok
    overall = green("ВСЁ РАБОТАЕТ ✓") if all_ok else red("ЕСТЬ ПРОБЛЕМЫ ✗")
    lines.append(f"\n  Статус: {overall}")

    return "\n".join(lines)


def health_json() -> dict:
    return {
        "xray_running": check_xray_running(),
        "tproxy_port": check_xray_port(),
        "config_valid": check_config_valid()[0],
        "config_message": check_config_valid()[1],
        "nftables_ok": check_nftables(),
    }


# ============================================
#   ВЫВОД: ИНФОРМАЦИЯ О СИСТЕМЕ
# ============================================

def render_system(settings: dict) -> str:
    """Формирует секцию с информацией о системе"""
    lines = [section("СИСТЕМА")]

    device = settings.get("device_model", "") or "не определена"
    os_name = settings.get("device_os", "") or "не определена"
    os_ver = settings.get("ver_os", "") or "не определена"
    hwid = settings.get("hwid", "") or "не задан"

    lines.append(f"  Устройство:    {device}")
    lines.append(f"  ОС:            {os_name} {os_ver}")
    lines.append(f"  HWID:          {hwid[:16]}{'...' if len(hwid) > 16 else ''}")

    # Время конфига
    if os.path.isfile(CONFIG_FILE):
        mtime = os.path.getmtime(CONFIG_FILE)
        dt = datetime.fromtimestamp(mtime).strftime("%Y-%m-%d %H:%M:%S")
        lines.append(f"  Конфиг от:     {dt}")
    else:
        lines.append(f"  Конфиг:        {red('отсутствует')}")

    return "\n".join(lines)


# ============================================
#   ВЫВОД: ИНФОРМАЦИЯ О ПОДПИСКЕ
# ============================================

def render_subscription(settings: dict, cfg: dict) -> str:
    """Формирует секцию с информацией о подписке"""
    lines = [section("ПОДПИСКА")]

    sub = settings.get("subscription", {})
    url = sub.get("url", "")
    ua = sub.get("user_agent", "не задан")
    remarks = sub.get("remarks_filter", "")
    whitelist = sub.get("domain_whitelist", [])

    lines.append(f"  URL:           {url[:50]}{'...' if len(url) > 50 else ''}" if url else f"  URL:           {red('не задан')}")
    lines.append(f"  User-Agent:    {ua}")
    if remarks:
        lines.append(f"  Фильтр:        {remarks}")

    if whitelist:
        lines.append(f"  Whitelist:     {', '.join(whitelist)}")

    # Анализируем config.json
    if cfg:
        outbounds = cfg.get("outbounds", [])
        proxy_count = sum(
            1 for ob in outbounds
            if ob.get("protocol") not in ("freedom", "blackhole", "dns")
        )
        has_hole = not proxy_count

        lines.append(f"  Прокси:        {green(str(proxy_count)) if proxy_count else red('нет (hole/direct)')}")

        balancer = cfg.get("routing", {}).get("balancers", [{}])
        if balancer and len(balancer[0].get("selector", [])) > 1:
            lines.append(f"  Балансировка:  {green('leastLoad')} ({len(balancer[0]['selector'])} серверов)")
        elif proxy_count == 1:
            lines.append(f"  Режим:         {green('один сервер + fallback DIRECT')}")
    else:
        lines.append(f"  Статус:        {red('config.json не найден')}")

    return "\n".join(lines)


# ============================================
#   ВЫВОД: СПИСОК ПРОКСИ
# ============================================

def render_proxies(cfg: dict) -> str:
    """Формирует секцию со списком прокси-серверов"""
    lines = [section("ПРОКСИ-СЕРВЕРЫ")]

    outbounds = cfg.get("outbounds", [])
    proxies = [
        ob for ob in outbounds
        if ob.get("protocol") not in ("freedom", "blackhole", "dns")
    ]

    if not proxies:
        lines.append("  Нет прокси-серверов (DIRECT-режим или hole)")
        return "\n".join(lines)

    for i, ob in enumerate(proxies):
        tag = ob.get("tag", f"proxy-{i}")
        protocol = ob.get("protocol", "?").upper()
        vnext = ob.get("settings", {}).get("vnext", [{}])
        addr = vnext[0].get("address", "?") if vnext else "?"
        port = vnext[0].get("port", "?") if vnext else "?"
        stream = ob.get("streamSettings", {})
        network = stream.get("network", "tcp")
        security = stream.get("security", "none")

        # Собираем строку транспорта
        transport = f"{security}/{network}"
        if network == "ws":
            path = stream.get("wsSettings", {}).get("path", "/")
            transport += f" path={path}"
        elif network == "grpc":
            svc = stream.get("grpcSettings", {}).get("serviceName", "")
            if svc:
                transport += f" svc={svc}"

        lines.append(f"  {i+1}. {bold(tag)}")
        lines.append(f"     {green(protocol)} → {addr}:{port}  [{transport}]")

    return "\n".join(lines)


# ============================================
#   ВЫВОД: НАСТРОЙКИ РОУТИНГА
# ============================================

def render_routing(settings: dict) -> str:
    """Формирует секцию с настройками роутинга"""
    routing = settings.get("routing", {})
    lines = [section("НАСТРОЙКИ РОУТИНГА")]

    strategy = routing.get("domainStrategy", "?")
    lines.append(f"  Стратегия DNS:     {strategy}")

    doh = routing.get("doh_domains", [])
    if doh:
        lines.append(f"  DoH-домены:        {', '.join(doh[:3])}")
        if len(doh) > 3:
            lines.append(f"                     ... и ещё {len(doh) - 3}")

    direct_domains = routing.get("direct_domains", [])
    lines.append(f"  Прямые домены:     {len(direct_domains)} правил")
    for d in direct_domains[:3]:
        lines.append(f"    • {d}")
    if len(direct_domains) > 3:
        lines.append(f"    ... и ещё {len(direct_domains) - 3}")

    direct_ips = routing.get("direct_ips", [])
    lines.append(f"  Прямые IP:         {len(direct_ips)} правил")
    for ip in direct_ips:
        lines.append(f"    • {ip}")

    proxy_domains = routing.get("proxy_domains", [])
    lines.append(f"  Прокси-домены:     {len(proxy_domains)} правил")
    for d in proxy_domains:
        lines.append(f"    • {d}")

    block_domains = routing.get("block_domains", [])
    lines.append(f"  Блокировка:        {len(block_domains)} правил")
    for d in block_domains:
        lines.append(f"    • {d}")

    # Geo-базы
    geo = settings.get("geo", {})
    if geo:
        lines.append(f"\n  GeoIP:  {geo.get('geoip_url', '?')[:50]}...")
        lines.append(f"  GeoSite: {geo.get('geosite_url', '?')[:50]}...")

    return "\n".join(lines)


# ============================================
#   ПОЛНЫЙ ДАШБОРД
# ============================================

def render_full(settings: dict, cfg: dict) -> str:
    """Формирует полный дашборд"""
    parts = [
        render_system(settings),
        render_health(),
        render_subscription(settings, cfg),
        render_proxies(cfg),
        render_routing(settings),
    ]
    return "\n".join(parts)


def render_compact(settings: dict, cfg: dict) -> str:
    """Формирует компактный дашборд (без списка прокси и роутинга)"""
    parts = [
        render_system(settings),
        render_health(),
        render_subscription(settings, cfg),
    ]
    return "\n".join(parts)


def to_json(settings: dict, cfg: dict) -> dict:
    """Экспорт всех данных в JSON"""
    return {
        "system": {
            "device_model": settings.get("device_model", ""),
            "device_os": settings.get("device_os", ""),
            "ver_os": settings.get("ver_os", ""),
            "hwid": settings.get("hwid", ""),
            "config_mtime": os.path.getmtime(CONFIG_FILE) if os.path.isfile(CONFIG_FILE) else None,
        },
        "health": health_json(),
        "subscription": {
            "url": settings.get("subscription", {}).get("url", ""),
            "user_agent": settings.get("subscription", {}).get("user_agent", ""),
            "remarks_filter": settings.get("subscription", {}).get("remarks_filter", ""),
            "domain_whitelist": settings.get("subscription", {}).get("domain_whitelist", []),
        },
        "proxies": [
            {
                "tag": ob.get("tag", ""),
                "protocol": ob.get("protocol", ""),
                "address": ob.get("settings", {}).get("vnext", [{}])[0].get("address", ""),
                "port": ob.get("settings", {}).get("vnext", [{}])[0].get("port", 0),
                "network": ob.get("streamSettings", {}).get("network", "tcp"),
                "security": ob.get("streamSettings", {}).get("security", "none"),
            }
            for ob in cfg.get("outbounds", [])
            if ob.get("protocol") not in ("freedom", "blackhole", "dns")
        ],
        "routing": settings.get("routing", {}),
        "geo": settings.get("geo", {}),
    }


# ============================================
#   MAIN
# ============================================

def main():
    parser = argparse.ArgumentParser(
        description="Xray Status Dashboard для OpenWrt",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Примеры:
  xray-status                  # компактный дашборд
  xray-status --full           # полный дашборд
  xray-status --json           # вывод в JSON
  xray-status --subscription   # только информация о подписке
  xray-status --proxies        # только список прокси
  xray-status --routing        # только настройки роутинга
  xray-status --health         # только проверка здоровья
        """
    )
    parser.add_argument("--full", action="store_true", help="Полный дашборд со списком прокси и роутингом")
    parser.add_argument("--json", action="store_true", help="Вывод в формате JSON")
    parser.add_argument("--subscription", action="store_true", help="Только информация о подписке")
    parser.add_argument("--proxies", action="store_true", help="Только список прокси")
    parser.add_argument("--routing", action="store_true", help="Только настройки роутинга")
    parser.add_argument("--health", action="store_true", help="Только проверка здоровья")
    args = parser.parse_args()

    settings = load_settings()
    cfg = load_config()

    if not settings and not cfg:
        print(red("[X] Ни settings.json, ни config.json не найдены"), file=sys.stderr)
        print(f"    Ожидаемые пути: {SETTINGS_FILE}, {CONFIG_FILE}", file=sys.stderr)
        sys.exit(1)

    # JSON-режим
    if args.json:
        print(json.dumps(to_json(settings, cfg), indent=2, ensure_ascii=False))
        return

    # Отдельные секции
    if args.subscription:
        print(render_subscription(settings, cfg))
    elif args.proxies:
        print(render_proxies(cfg))
    elif args.routing:
        print(render_routing(settings))
    elif args.health:
        print(render_health())
    elif args.full:
        print(render_full(settings, cfg))
    else:
        # По умолчанию — компактный дашборд
        print(render_compact(settings, cfg))

    # Всегда показываем подсказку, если не JSON
    if not args.json:
        print(f"\n{separator()}")
        print(yellow("Подсказка:") + " xray-status --full   для полного вывода")
        print("          xray-status --json   для машинного вывода")
        print("          xray-status --health для проверки здоровья")


if __name__ == "__main__":
    main()
