__lazy_modules__ = ["boto3", "botocore.exceptions"]

import os
from contextlib import contextmanager
import logging
from typing import cast, TYPE_CHECKING, Mapping

import boto3
from botocore.exceptions import ClientError
from base import DNSProvider, normalize_fqdn

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


logger = logging.getLogger("dns-updater")


def _to_route53_rr_type(rtype: str) -> RRTypeType:
    """Cast generic str rtype to boto3's strict RRTypeType for type checking."""
    return cast(RRTypeType, rtype)


class AwsCredentialResolver:
    def __init__(self, env: Mapping[str, str]) -> None:
        self._env = env

    @staticmethod
    @contextmanager
    def _suppress_aws_profile():
        """Temporarily remove AWS_PROFILE to avoid boto3#4121 during Session creation.
        Restores it after Session is created to preserve global state for other code.
        """
        profile = os.environ.pop("AWS_PROFILE", None)
        try:
            yield
        finally:
            if profile is not None:
                os.environ["AWS_PROFILE"] = profile

    def resolve(self) -> boto3.session.Session:
        aws_access_key = self._env.get("AWS_ACCESS_KEY_ID")
        aws_secret_key = self._env.get("AWS_SECRET_ACCESS_KEY")
        env_creds = aws_access_key and aws_secret_key

        profile = self._env.get("AWS_PROFILE")
        credentials_path = self._credentials_path()

        if env_creds:
            logger.info("Using AWS credentials from environment variables.")
            with self._suppress_aws_profile():
                return boto3.session.Session()
        elif profile and profile.strip() and os.path.exists(credentials_path):
            logger.info(f"Using AWS profile '{profile}' from {credentials_path}")
            logger.debug(
                f"Using AWS creds file: {os.environ.get('AWS_SHARED_CREDENTIALS_FILE', 'N/A')}"
            )
            logger.debug(
                f"Using AWS config file: {os.environ.get('AWS_CONFIG_FILE', 'N/A')}"
            )
            return boto3.session.Session(profile_name=profile.strip())
        elif os.path.exists(credentials_path):
            logger.info(f"Using default AWS profile from {credentials_path}")
            logger.debug(
                f"Using AWS creds file: {os.environ.get('AWS_SHARED_CREDENTIALS_FILE', 'N/A')}"
            )
            logger.debug(
                f"Using AWS config file: {os.environ.get('AWS_CONFIG_FILE', 'N/A')}"
            )
            return boto3.session.Session()
        else:
            raise RuntimeError(
                "No valid AWS credentials found (env vars or ~/.aws/credentials)"
            )

    def _credentials_path(self) -> str:
        return os.environ.get(
            "AWS_SHARED_CREDENTIALS_FILE",
            os.path.expanduser("~/.aws/credentials"),
        )


class Route53Provider(DNSProvider):
    allows_apex_cname = False

    def __init__(self, hosted_zone_id: str, session: boto3.session.Session) -> None:
        self._hz = hosted_zone_id
        self._session = session
        self._r53 = session.client("route53")

    @classmethod
    def from_env(cls, env: Mapping[str, str]) -> "Route53Provider":
        hz = env["AWS_HOSTED_ZONE_ID"]
        session = AwsCredentialResolver(env).resolve()
        return cls(hz, session)

    def validate(self) -> None:
        try:
            ident = self._session.client("sts").get_caller_identity()
            logger.info("AWS identity: %s (Account %s)", ident["Arn"], ident["Account"])
            self._r53.get_hosted_zone(Id=self._hz)
        except Exception as e:
            raise RuntimeError(f"Route53 validation failed: {e}") from e

    def record_is(self, name: str, rtype: str, value: str) -> bool:
        n_name = normalize_fqdn(name) + "."
        n_value = normalize_fqdn(value)
        rr_type = _to_route53_rr_type(rtype)
        try:
            resp = self._r53.list_resource_record_sets(
                HostedZoneId=self._hz,
                StartRecordName=n_name,
                StartRecordType=rr_type,
                MaxItems="1",
            )
            rrsets = resp.get("ResourceRecordSets", [])
            if not rrsets:
                return False

            rrset = rrsets[0]
            if (
                normalize_fqdn(rrset.get("Name", "")) + "." != n_name
                or rrset.get("Type") != rr_type
            ):
                return False

            if "AliasTarget" in rrset:
                logger.warning(
                    f"Record {n_name} {rr_type} is an alias; skipping management."
                )
                return True

            vals = [
                normalize_fqdn(rr.get("Value", ""))
                for rr in rrset.get("ResourceRecords", [])
            ]
            if len(vals) > 1:
                logger.warning(
                    f"Record {n_name} {rr_type} has multiple values {vals}; skipping management."
                )
                return True

            return len(vals) == 1 and vals[0] == n_value

        except ClientError as e:
            code = e.response.get("Error", {}).get("Code", "Unknown")
            logger.error(f"Error checking {n_name} {rr_type}: {e} ({code})")
            return True

    def upsert(
        self, name: str, rtype: str, value: str, ttl: int, proxied: bool = False
    ) -> bool:
        n_name = normalize_fqdn(name) + "."
        n_value = normalize_fqdn(value)
        rr_type = _to_route53_rr_type(rtype)
        if self.record_is(name, rtype, value):
            return False

        rr: ResourceRecordTypeDef = {"Value": n_value}
        rrset: ResourceRecordSetTypeDef = {
            "Name": n_name,
            "Type": rr_type,
            "TTL": ttl,
            "ResourceRecords": [rr],
        }
        change: ChangeTypeDef = {"Action": "UPSERT", "ResourceRecordSet": rrset}

        self._r53.change_resource_record_sets(
            HostedZoneId=self._hz,
            ChangeBatch={
                "Comment": f"Auto-updated {rr_type} record for {name}",
                "Changes": [change],
            },
        )
        return True
