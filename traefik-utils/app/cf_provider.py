__lazy_modules__ = ["cloudflare"]

import logging
from typing import Mapping

from cloudflare import Cloudflare
from cloudflare.types.dns import RecordResponse

from base import DNSProvider, normalize_fqdn

logger = logging.getLogger("dns-updater")


class CloudflareProvider(DNSProvider):
    allows_apex_cname = True

    def __init__(self, zone_id: str, token: str) -> None:
        self._zone = zone_id
        self._cf = Cloudflare(api_token=token)

    @classmethod
    def from_env(cls, env: Mapping[str, str]) -> "CloudflareProvider":
        return cls(env["CF_ZONE_ID"], env["CF_DNS_API_TOKEN"])

    def validate(self) -> None:
        try:
            self._cf.dns.records.list(zone_id=self._zone, per_page=1)
        except Exception as e:
            raise RuntimeError(f"Cloudflare validation failed: {e}") from e

    def _get_record(self, name: str, rtype: str) -> RecordResponse | None:
        recs = self._cf.dns.records.list(
            zone_id=self._zone,
            type=rtype,
            name=normalize_fqdn(name),
            per_page=1,
        )
        return recs.result[0] if recs.result else None

    def record_is(
        self, name: str, rtype: str, value: str, proxied: bool = False
    ) -> bool:
        n_name, n_value = normalize_fqdn(name), normalize_fqdn(value)
        recs = self._cf.dns.records.list(zone_id=self._zone, type=rtype, name=n_name)

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
        self, name: str, rtype: str, value: str, ttl: int, proxied: bool = False
    ) -> bool:
        n_name, n_value = normalize_fqdn(name), normalize_fqdn(value)
        if self.record_is(n_name, rtype, n_value, proxied=proxied):
            return False
        existing = self._get_record(n_name, rtype)
        payload = {
            "type": rtype,
            "name": n_name,
            "content": n_value,
            "ttl": ttl,
            "proxied": proxied,
        }
        if existing:
            self._cf.dns.records.update(
                dns_record_id=existing.id,
                zone_id=self._zone,
                **payload,
            )
        else:
            self._cf.dns.records.create(
                zone_id=self._zone,
                **payload,
            )
        return True
