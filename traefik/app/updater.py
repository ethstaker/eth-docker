import os
import json
import logging
import time
import requests
from tenacity import retry, wait_exponential, stop_after_attempt, retry_if_exception_type
import boto3
from botocore.exceptions import ClientError
import sys

logger = logging.getLogger("dns-updater")
if not logger.handlers:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    logger.propagate = False  # Prevent propagation to root logger

# Load environment variables
HOSTED_ZONE_ID = os.environ["AWS_HOSTED_ZONE_ID"]
A_RECORD_NAME = os.environ["A_RECORD_NAME"]
CNAME_LIST = os.getenv("CNAME_LIST", "")
TTL = int(os.getenv("TTL", 300))
SLEEP = int(os.getenv("SLEEP", 300))


# Parse CNAME targets
CNAME_TARGETS = [c.strip() for c in CNAME_LIST.split(",") if c.strip()]

def check_credentials():
    aws_access_key = os.getenv("AWS_ACCESS_KEY_ID")
    aws_secret_key = os.getenv("AWS_SECRET_ACCESS_KEY")
    env_creds = aws_access_key and aws_secret_key

    profile = os.getenv("AWS_PROFILE")
    credentials_path = "/root/.aws/credentials"

    # 1. Use env vars if both are present
    if env_creds:
        logger.info("Using AWS credentials from environment variables.")
        os.unsetenv("AWS_PROFILE")
        os.environ.pop("AWS_PROFILE", None)
        return

    # 2. Use profile only if it's not None and not empty/whitespace
    if profile and profile.strip() and os.path.exists(credentials_path):
        logger.info(f"Using AWS profile '{profile}' from {credentials_path}")
        return

    # 3. If profile is missing/empty but credentials file exists, use default
    if os.path.exists(credentials_path):
        logger.info(f"Using default AWS profile from {credentials_path}")
        return

    # 4. Nothing found
    raise RuntimeError("No valid AWS credentials found (env vars or ~/.aws/credentials)")

check_credentials()
session = boto3.session.Session()
route53 = session.client("route53")

def validate_ipv4(ip):
    parts = ip.split(".")
    return len(parts) == 4 and all(part.isdigit() and 0 <= int(part) <= 255 for part in parts)


@retry(wait=wait_exponential(multiplier=1, min=2, max=10), stop=stop_after_attempt(5),
       retry=retry_if_exception_type(requests.RequestException))
def get_external_ip():
    ip_services = [
        "https://checkip.amazonaws.com",
        "https://api64.ipify.org",
        "https://ipinfo.io/ip",
        "https://icanhazip.com",
        "https://ifconfig.me",
        "https://ident.me",
        "https://ipecho.net/plain",
        "https://wtfismyip.com/text",
        "https://bot.whatismyipaddress.com",
        "https://myexternalip.com/raw",
        "http://whatismyip.akamai.com",
        "http://ip.42.pl/raw",
        "https://ip.seeip.org",
        "https://ip.tyk.nu",
        "https://api.my-ip.io/ip",
        "https://ipv4.icanhazip.com",
        "https://ipwho.is/?format=text"
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


def record_exists(name, rtype, value):
    try:
        resp = route53.list_resource_record_sets(
            HostedZoneId=HOSTED_ZONE_ID,
            StartRecordName=name,
            StartRecordType=rtype,
            MaxItems="1"
        )
        records = resp.get("ResourceRecordSets", [])
        if records and records[0]["Name"] == name and records[0]["Type"] == rtype:
            existing_values = [r["Value"] for r in records[0]["ResourceRecords"]]
            return value in existing_values
    except ClientError as e:
        logger.error(f"Error checking existing record: {e}")
    return False


def upsert_record(name, rtype, value):
    change = {
        "Action": "UPSERT",
        "ResourceRecordSet": {
            "Name": name,
            "Type": rtype,
            "TTL": TTL,
            "ResourceRecords": [{"Value": value}]
        }
    }
    try:
        route53.change_resource_record_sets(
            HostedZoneId=HOSTED_ZONE_ID,
            ChangeBatch={
                "Comment": f"Auto-updated {rtype} record for {name}",
                "Changes": [change]
            }
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

def run():
    DOMAIN = ".".join(A_RECORD_NAME.split(".")[1:])
    while True:
        try:
            ip = get_external_ip()
            fqdn = A_RECORD_NAME if A_RECORD_NAME.endswith('.') else A_RECORD_NAME + '.'

            if not record_exists(fqdn, "A", ip):
                upsert_record(fqdn, "A", ip)
            else:
                logger.info(f"A record {fqdn} already up-to-date with IP {ip}")

            for cname in CNAME_TARGETS:
                cname_fqdn = build_cname_fqdn(cname, DOMAIN)
                if not record_exists(cname_fqdn, "CNAME", fqdn):
                    upsert_record(cname_fqdn, "CNAME", fqdn)
                else:
                    logger.info(f"CNAME {cname_fqdn} already points to {fqdn}")

        except Exception as e:
            logger.error(f"Error during update cycle: {e}")

        logger.info(f"Sleeping {SLEEP} seconds")
        time.sleep(SLEEP)


if __name__ == "__main__":
    run()
