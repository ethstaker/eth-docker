__lazy_modules__ = ["cloudflare"]

import logging
from typing import Mapping

from cloudflare import Cloudflare
from cloudflare.types.dns import DNSRecord

from base import DNSProvider, normalize_fqdn

logger = logging.getLogger("dns-updater")


class CloudflareProvider(DNSProvider):
    allows_apex_cname = True

    def __init__(
        self, zone_id: str, write_token: str, read_token: str | None = None
    ) -> None:
        self._zone = zone_id
        self._cf_w = Cloudflare(api_token=write_token)
        self._cf_r = Cloudflare(api_token=(read_token or write_token))

    @classmethod
    def from_env(cls, env: Mapping[str, str]) -> "CloudflareProvider":
        zone_id = env["CF_ZONE_ID"]
        write = env["CF_DNS_API_TOKEN"]
        read = env.get("CF_ZONE_API_TOKEN")
        return cls(zone_id, write, read)

    def validate(self) -> None:
        try:
            self._cf_r.dns.records.list(self._zone, params={"per_page": 1})
        except Exception as e:
            raise RuntimeError(f"Cloudflare validation failed: {e}") from e

    def _get_record(self, name: str, rtype: str) -> DNSRecord | None:
        recs = self._cf_r.dns.records.list(
            self._zone,
            params={"type": rtype, "name": normalize_fqdn(name), "per_page": 1},
        )
        return recs[0] if recs else None

    def record_is(self, name: str, rtype: str, value: str) -> bool:
        n_name, n_value = normalize_fqdn(name), normalize_fqdn(value)
        recs = self._cf_r.dns.records.list(
            self._zone, params={"type": rtype, "name": n_name}
        )

        # No records exist
        if not recs:
            return False

        # Multiple records (skip management)
        if len(recs) > 1:
            logger.warning(
                f"Record {n_name} {rtype} has multiple records; skipping management."
            )
            return True

        # One record, check value match
        have = normalize_fqdn(str(recs[0].content))
        return have == n_value

    def upsert(
        self, name: str, rtype: str, value: str, ttl: int, proxied: bool = False
    ) -> bool:
        n_name, n_value = normalize_fqdn(name), normalize_fqdn(value)
        if self.record_is(n_name, rtype, n_value):
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
            self._cf_w.dns.records.update(self._zone, existing.id, data=payload)
        else:
            self._cf_w.dns.records.create(self._zone, data=payload)
        return True
