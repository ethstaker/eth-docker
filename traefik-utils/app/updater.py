from __future__ import annotations
import os
import pwd
import grp
import shutil
import subprocess
import signal
import logging
import time
import requests
from tenacity import (
    retry,
    wait_exponential,
    stop_after_attempt,
    retry_if_exception_type,
)
import boto3
from botocore.exceptions import ClientError
import sys
import ipaddress
from types import FrameType
from typing import (
    TYPE_CHECKING,
    NoReturn,
)

if TYPE_CHECKING:
    from mypy_boto3_route53.client import Route53Client
    from mypy_boto3_route53.literals import RRTypeType
    from mypy_boto3_route53.type_defs import (
        ChangeTypeDef,
        ResourceRecordSetTypeDef,
        ResourceRecordTypeDef,
    )
else:
    Route53Client = object  # runtime placeholder


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
        logger.propagate = False  # Prevent propagation to root logger
    return logger


def drop_privileges(user: str) -> None:
    pw = pwd.getpwnam(user)
    # Supplementary groups
    try:
        if hasattr(os, "initgroups"):
            os.initgroups(user, pw.pw_gid)
        else:
            gids = [g.gr_gid for g in grp.getgrall() if user in g.gr_mem]
            os.setgroups(gids + [pw.pw_gid])
    except PermissionError:
        pass  # container may lack CAP_SETGID

    # Drop GID/UID (use setres* when available)
    if hasattr(os, "setresgid") and hasattr(os, "setresuid"):
        os.setresgid(pw.pw_gid, pw.pw_gid, pw.pw_gid)
        os.setresuid(pw.pw_uid, pw.pw_uid, pw.pw_uid)
    else:
        os.setgid(pw.pw_gid)
        os.setuid(pw.pw_uid)

    os.environ.update(HOME=pw.pw_dir, USER=pw.pw_name, LOGNAME=pw.pw_name)
    os.environ.setdefault(
        "AWS_SHARED_CREDENTIALS_FILE", f"{pw.pw_dir}/.aws/credentials"
    )
    os.environ.setdefault("AWS_CONFIG_FILE", f"{pw.pw_dir}/.aws/config")

    os.chdir(pw.pw_dir)


def copy_aws_config(user: str) -> None:
    pw = pwd.getpwnam(user)
    src = "/root/.aws"
    dst = os.path.join(pw.pw_dir, ".aws")

    if not os.path.exists(src):
        return  # nothing to copy

    if os.path.exists(dst):
        shutil.rmtree(dst)

    shutil.copytree(src, dst)

    subprocess.check_call(["chown", "-R", f"{pw.pw_uid}:{pw.pw_gid}", dst])

    # perms: 700 for dirs, 600 for files
    for root, dirs, files in os.walk(dst):
        for d in dirs:
            os.chmod(os.path.join(root, d), 0o700)
        for f in files:
            os.chmod(os.path.join(root, f), 0o600)


def check_credentials(user: str) -> None:
    pw = pwd.getpwnam(user)
    aws_access_key = os.getenv("AWS_ACCESS_KEY_ID")
    aws_secret_key = os.getenv("AWS_SECRET_ACCESS_KEY")
    env_creds = aws_access_key and aws_secret_key

    profile = os.getenv("AWS_PROFILE")
    credentials_path = f"{pw.pw_dir}/.aws/credentials"

    # 1. Use env vars if both are present
    if env_creds:
        logger.info("Using AWS credentials from environment variables.")
        os.unsetenv("AWS_PROFILE")
        os.environ.pop("AWS_PROFILE", None)
        return

    # 2. Use profile only if it's not None and not empty/whitespace
    if profile and profile.strip() and os.path.exists(credentials_path):
        logger.info(f"Using AWS profile '{profile}' from {credentials_path}")
        logger.debug(
            f"Using AWS creds file: {os.environ['AWS_SHARED_CREDENTIALS_FILE']}"
        )
        logger.debug(f"Using AWS config file: {os.environ['AWS_CONFIG_FILE']}")
        return

    # 3. If profile is missing/empty but credentials file exists, use default
    if os.path.exists(credentials_path):
        logger.info(f"Using default AWS profile from {credentials_path}")
        logger.debug(
            f"Using AWS creds file: {os.environ['AWS_SHARED_CREDENTIALS_FILE']}"
        )
        logger.debug(f"Using AWS config file: {os.environ['AWS_CONFIG_FILE']}")
        return

    # 4. Nothing found
    raise RuntimeError(
        "No valid AWS credentials found (env vars or ~/.aws/credentials)"
    )


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
def get_external_ip() -> str:
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
        "https://ident.me",  # works on v6 if reachable via v6
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


def normalize_fqdn(s: str) -> str:
    return s.strip().rstrip(".").lower()


def record_exists(
    name: str,
    rtype: RRTypeType,
    value: str,
    hosted_zone_id: str,
    route53: Route53Client,
) -> bool:
    try:
        resp = route53.list_resource_record_sets(
            HostedZoneId=hosted_zone_id,
            StartRecordName=name,
            StartRecordType=rtype,
            MaxItems="1",
        )
        records = resp.get("ResourceRecordSets", [])
        if records and records[0]["Name"] == name and records[0]["Type"] == rtype:
            rrset = records[0]
            if "AliasTarget" in rrset:
                logger.warning(
                    f"{rtype} {name} is an AliasTarget; skipping management."
                )
                return True  # don’t try to manage alias records
            existing_values = [r["Value"] for r in rrset.get("ResourceRecords", [])]
            if rtype == "CNAME":
                ev = {normalize_fqdn(v) for v in existing_values}
                return normalize_fqdn(value) in ev
            return value in existing_values
    except ClientError as e:
        logger.error(f"Error checking existing record: {e}")
    return False


def upsert_record(
    name: str,
    rtype: RRTypeType,
    value: str,
    ttl: int,
    hosted_zone_id: str,
    route53: Route53Client,
) -> None:
    rr: ResourceRecordTypeDef = {"Value": value}
    rrset: ResourceRecordSetTypeDef = {
        "Name": name,
        "Type": rtype,
        "TTL": ttl,
        "ResourceRecords": [rr],
    }
    change: ChangeTypeDef = {"Action": "UPSERT", "ResourceRecordSet": rrset}
    try:
        route53.change_resource_record_sets(
            HostedZoneId=hosted_zone_id,
            ChangeBatch={
                "Comment": f"Auto-updated {rtype} record for {name}",
                "Changes": [change],
            },
        )
        logger.info(f"Upserted {rtype} record: {name} -> {value}")
    except ClientError as e:
        logger.error(f"Failed to upsert {rtype} record {name}: {e}")


def build_cname_fqdn(label_or_name: str, domain: str) -> str:
    """
    - 'api' -> 'api.<domain>.'
    - 'api.example.com' -> 'api.example.com.'
    - 'api.example.com.' -> 'api.example.com.'
    - '<domain>' or '<domain>.' -> '<domain>.'
    Always returns a trailing-dot FQDN.
    """
    n = label_or_name.strip().rstrip(".")
    d = domain.strip().rstrip(".")
    if not n:
        raise ValueError("Empty CNAME entry")

    # Already fully-qualified for this domain
    if n == d or n.endswith("." + d):
        return n + "."

    # Some other absolute name (contains a dot), just normalize trailing dot
    if "." in n:
        return n + "."

    # Short label: expand with domain
    return f"{n}.{d}."


# graceful shutdown
def _shutdown(signum: int, frame: FrameType | None) -> NoReturn:
    logger.info("Received shutdown signal, exiting.")
    raise SystemExit(0)


def main() -> None:
    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    USER_NAME = "dns"
    copy_aws_config(USER_NAME)
    drop_privileges(USER_NAME)

    check_credentials(USER_NAME)
    session = boto3.session.Session()
    try:
        sts = session.client("sts")
        ident = sts.get_caller_identity()
        logger.info(f"AWS identity: {ident['Arn']} (Account {ident['Account']})")
    except Exception as e:
        logger.error(f"Failed to verify AWS credentials: {e}")
        sys.exit(1)
    route53 = session.client("route53")

    # Load environment variables
    HOSTED_ZONE_ID = os.environ["AWS_HOSTED_ZONE_ID"]
    A_RECORD_NAME = os.environ["A_RECORD_NAME"]
    CNAME_LIST = os.getenv("CNAME_LIST", "")
    TTL = int(os.getenv("TTL", 300))
    SLEEP = int(os.getenv("SLEEP", 300))

    # Parse CNAME targets
    CNAME_TARGETS = [c.strip() for c in CNAME_LIST.split(",") if c.strip()]

    DOMAIN = ".".join(A_RECORD_NAME.split(".")[1:])
    while True:
        try:
            ip4 = get_external_ip()
            ip6 = get_external_ip6()
            fqdn = A_RECORD_NAME if A_RECORD_NAME.endswith(".") else A_RECORD_NAME + "."

            if not record_exists(fqdn, "A", ip4, HOSTED_ZONE_ID, route53):
                upsert_record(fqdn, "A", ip4, TTL, HOSTED_ZONE_ID, route53)
                logger.info(f"Updated A record {fqdn} with IP {ip4}")
            else:
                logger.info(f"A record {fqdn} already up-to-date with IP {ip4}")

            if ip6:
                if not record_exists(fqdn, "AAAA", ip6, HOSTED_ZONE_ID, route53):
                    upsert_record(fqdn, "AAAA", ip6, TTL, HOSTED_ZONE_ID, route53)
                    logger.info(f"Updated AAAA record {fqdn} with IP {ip6}")
                else:
                    logger.info(f"AAAA record {fqdn} already up-to-date with IP {ip6}")
            else:
                logger.debug("Skipping AAAA update: no external IPv6 detected")

            for cname in CNAME_TARGETS:
                cname_fqdn = build_cname_fqdn(cname, DOMAIN)
                # Guard: Route53 does not allow a CNAME at the zone apex
                if normalize_fqdn(cname_fqdn) == normalize_fqdn(DOMAIN):
                    logger.warning(f"Skipping apex CNAME for {cname_fqdn}")
                    continue
                if not record_exists(
                    cname_fqdn, "CNAME", fqdn, HOSTED_ZONE_ID, route53
                ):
                    upsert_record(
                        cname_fqdn, "CNAME", fqdn, TTL, HOSTED_ZONE_ID, route53
                    )
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
