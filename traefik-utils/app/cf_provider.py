import logging
from collections.abc import Mapping
from typing import Any, cast

lazy from cloudflare import Cloudflare
lazy from cloudflare.types.dns import RecordResponse

from base import DNSProvider, RecordType, normalize_fqdn

logger = logging.getLogger("dns-updater")

_CloudflareRecords = Any


class CloudflareProvider(DNSProvider):
    allows_apex_cname = True

    def __init__(self, zone_id: str, token: str) -> None:
        self._zone = zone_id
        self._cf = Cloudflare(api_token=token)

    @classmethod
    def from_env(cls, env: Mapping[str, str]) -> CloudflareProvider:
        return cls(env["CF_ZONE_ID"], env["CF_DNS_API_TOKEN"])

    def validate(self) -> None:
        try:
            self._cf.dns.records.list(zone_id=self._zone, per_page=1)
        except Exception as e:
            raise RuntimeError(f"Cloudflare validation failed: {e}") from e

    def _get_record(self, name: str, rtype: RecordType) -> RecordResponse | None:
        recs = self._cf.dns.records.list(
            zone_id=self._zone,
            type=rtype,
            name=cast(Any, normalize_fqdn(name)),
            per_page=1,
        )
        return recs.result[0] if recs.result else None

    def record_is(
        self, name: str, rtype: RecordType, value: str, proxied: bool = False
    ) -> bool:
        n_name, n_value = normalize_fqdn(name), normalize_fqdn(value)
        recs = self._cf.dns.records.list(
            zone_id=self._zone,
            type=rtype,
            name=cast(Any, n_name),
        )

        # No records exist
        if not recs.result:
            return False

        # Multiple records (skip management)
        if len(recs.result) > 1:
            logger.warning(
                f"Record {n_name} {rtype} has multiple records; skipping management."
            )
            return True

        # One record, check value match
        have = normalize_fqdn(str(recs.result[0].content))
        have_proxied = recs.result[0].proxied
        return have == n_value and have_proxied == proxied

    def upsert(
        self,
        name: str,
        rtype: RecordType,
        value: str,
        ttl: int,
        proxied: bool = False,
    ) -> bool:
        n_name, n_value = normalize_fqdn(name), normalize_fqdn(value)
        if self.record_is(n_name, rtype, n_value, proxied=proxied):
            return False
        existing = self._get_record(n_name, rtype)
        records = cast(_CloudflareRecords, self._cf.dns.records)
        if rtype in ("A", "AAAA"):
            if existing:
                records.update(
                    dns_record_id=existing.id,
                    zone_id=self._zone,
                    name=n_name,
                    type=rtype,
                    content=n_value,
                    ttl=ttl,
                    proxied=proxied,
                )
            else:
                records.create(
                    zone_id=self._zone,
                    name=n_name,
                    type=rtype,
                    content=n_value,
                    ttl=ttl,
                    proxied=proxied,
                )
        else:
            if existing:
                records.update(
                    dns_record_id=existing.id,
                    zone_id=self._zone,
                    name=n_name,
                    type="CNAME",
                    content=n_value,
                    proxied=proxied,
                )
            else:
                records.create(
                    zone_id=self._zone,
                    name=n_name,
                    type="CNAME",
                    content=n_value,
                    proxied=proxied,
                )
        return True
