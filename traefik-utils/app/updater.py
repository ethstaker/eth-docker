import os
import logging
import time
import signal
import sys
import ipaddress
import re
import requests
from types import FrameType
from typing import NoReturn

from tenacity import (
    retry,
    wait_exponential,
    stop_after_attempt,
    retry_if_exception_type,
)

from base import build_provider, normalize_fqdn
from privilege import PrivilegeManager
from provider_registry import register_all

logger = logging.getLogger("dns-updater")


def setup_logger() -> logging.Logger:
    logger = logging.getLogger("dns-updater")
    if not logger.handlers:
        _handler = logging.StreamHandler(sys.stdout)
        _handler.setFormatter(
            logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")
        )
        logger.addHandler(_handler)
        _level = os.getenv("LOG_LEVEL", "INFO").upper()
        logger.setLevel(getattr(logging, _level, logging.INFO))
        logger.propagate = False
    return logger


def validate_ipv4(ip: str) -> bool:
    try:
        return isinstance(ipaddress.ip_address(ip), ipaddress.IPv4Address)
    except ValueError:
        return False


def validate_ipv6(ip: str) -> bool:
    try:
        return isinstance(ipaddress.ip_address(ip), ipaddress.IPv6Address)
    except ValueError:
        return False


@retry(
    wait=wait_exponential(multiplier=1, min=2, max=10),
    stop=stop_after_attempt(5),
    retry=retry_if_exception_type(requests.RequestException),
)
def get_external_ip4() -> str:
    ip_services = [
        "https://ipv4.icanhazip.com",
        "https://checkip.amazonaws.com",
        "http://whatismyip.akamai.com",
        "http://ip.42.pl/raw",
        "https://api64.ipify.org",
        "https://ipinfo.io/ip",
        "https://ifconfig.me",
        "https://ident.me",
        "https://ipecho.net/plain",
        "https://wtfismyip.com/text",
        "https://bot.whatismyipaddress.com",
        "https://myexternalip.com/raw",
        "https://ip.seeip.org",
        "https://ip.tyk.nu",
        "https://api.my-ip.io/ip",
        "https://ipwho.is/?format=text",
    ]

    for url in ip_services:
        try:
            resp = requests.get(url, timeout=3)
            if resp.ok:
                text = resp.text.strip()
                ip = text.split()[0]
                if validate_ipv4(ip):
                    logger.info(f"Got external IP from {url}: {ip}")
                    return ip
                else:
                    logger.warning(f"Invalid IP format from {url}: {ip}")
        except Exception as e:
            logger.debug(f"Failed to get IP from {url}: {e}")

    raise requests.RequestException("Unable to fetch external IP from any source")


@retry(
    wait=wait_exponential(multiplier=1, min=2, max=10),
    stop=stop_after_attempt(5),
    retry=retry_if_exception_type(requests.RequestException),
)
def get_external_ip6() -> str | None:
    ip6_services = [
        "https://api6.ipify.org",
        "https://ipv6.icanhazip.com",
        "https://ifconfig.co/ip",
        "https://ident.me",
        "https://myexternalip.com/raw",
    ]
    for url in ip6_services:
        try:
            resp = requests.get(url, timeout=3)
            if resp.ok:
                ip = resp.text.strip().split()[0]
                if validate_ipv6(ip):
                    logger.info(f"Got external IPv6 from {url}: {ip}")
                    return ip
                else:
                    logger.debug(f"Invalid IPv6 format from {url}: {ip}")
        except Exception as e:
            logger.debug(f"Failed to get IPv6 from {url}: {e}")
    logger.info("No external IPv6 detected; skipping AAAA update")
    return None


def build_cname_fqdn(label: str, domain: str) -> str:
    n = label.strip().rstrip(".")
    d = domain.strip().rstrip(".")
    if not n:
        raise ValueError("Empty CNAME entry")
    return f"{n}.{d}."


def _shutdown(signum: int, frame: FrameType | None) -> NoReturn:
    logger.info("Received shutdown signal, exiting.")
    raise SystemExit(0)


def main() -> None:
    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    register_all()

    user = os.getenv("RUN_AS_USER", "dns")
    priv = PrivilegeManager(user)
    provider_name = os.getenv("DNS_PROVIDER", "route53")
    provider = build_provider(priv, provider_name, os.environ)

    DDNS_HOST = os.environ["DDNS_HOST"]
    DOMAIN = os.environ["DOMAIN"]
    CNAME_LIST = os.getenv("CNAME_LIST", "")
    CF_PROXY = os.getenv("CF_PROXY", "false").strip().lower() in ("true", "1", "yes")
    TTL = int(os.getenv("TTL", 300))
    SLEEP = int(os.getenv("SLEEP", 300))

    CNAME_PATTERN = re.compile(r"^(.+?):(proxy|noproxy)$", re.IGNORECASE)
    CNAME_ENTRIES: list[tuple[str, bool | None]] = []
    for c in CNAME_LIST.split(","):
        c = c.strip()
        if not c:
            continue
        if m := CNAME_PATTERN.match(c):
            CNAME_ENTRIES.append((m.group(1), m.group(2).lower() == "proxy"))
        else:
            CNAME_ENTRIES.append((c, None))

    normalized_domain = normalize_fqdn(DOMAIN)
    fqdn = f"{DDNS_HOST}.{normalized_domain}."

    while True:
        try:
            ip4 = get_external_ip4()
            ip6 = get_external_ip6()

            did_update = provider.upsert(fqdn, "A", ip4, TTL, proxied=CF_PROXY)
            if did_update:
                logger.info(f"Updated A record {fqdn} with IP {ip4}")
            else:
                logger.info(f"A record {fqdn} already up-to-date with IP {ip4}")

            if ip6:
                did_update = provider.upsert(fqdn, "AAAA", ip6, TTL, proxied=CF_PROXY)
                if did_update:
                    logger.info(f"Updated AAAA record {fqdn} with IP {ip6}")
                else:
                    logger.info(f"AAAA record {fqdn} already up-to-date with IP {ip6}")
            else:
                logger.debug("Skipping AAAA update: no external IPv6 detected")

            for cname_label, proxy_override in CNAME_ENTRIES:
                cname_proxied = (
                    proxy_override if proxy_override is not None else CF_PROXY
                )
                cname_fqdn = build_cname_fqdn(cname_label, DOMAIN)
                if (
                    not provider.allows_apex_cname
                    and normalize_fqdn(cname_fqdn) == normalized_domain
                ):
                    logger.warning(f"Skipping apex CNAME for {cname_fqdn}")
                    continue
                did_update = provider.upsert(
                    cname_fqdn, "CNAME", fqdn, TTL, proxied=cname_proxied
                )
                if did_update:
                    logger.info(f"Updated CNAME {cname_fqdn} for {fqdn}")
                else:
                    logger.info(f"CNAME {cname_fqdn} already points to {fqdn}")

        except Exception as e:
            logger.error(f"Error during update cycle: {e}")

        logger.info(f"Sleeping {SLEEP} seconds")
        time.sleep(SLEEP)


if __name__ == "__main__":
    logger = setup_logger()
    try:
        main()
    except Exception as e:
        logger.error(f"Fatal: {e}")
        sys.exit(1)
