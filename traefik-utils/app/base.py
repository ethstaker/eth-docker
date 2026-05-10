from abc import ABC, abstractmethod
from typing import TYPE_CHECKING, Mapping, Self

if TYPE_CHECKING:
    from privilege import PrivilegeManager

_provider_registry: dict[str, type["DNSProvider"]] = {}


def register_provider(name: str, cls: type["DNSProvider"]) -> None:
    _provider_registry[name.lower()] = cls


def build_provider(
    priv: "PrivilegeManager", provider_name: str, env: Mapping[str, str]
) -> "DNSProvider":
    which = provider_name.lower()
    provider_class = _provider_registry.get(which)
    if provider_class is None:
        raise SystemExit(f"Unknown DNS_PROVIDER={which}")

    priv.setup(need_aws_config=(which == "route53"))

    provider = provider_class.from_env(env)
    provider.validate()
    return provider


class DNSProvider(ABC):
    @property
    @abstractmethod
    def allows_apex_cname(self) -> bool:
        """Whether this provider allows a CNAME at the zone apex."""
        ...

    @classmethod
    @abstractmethod
    def from_env(cls, env: Mapping[str, str]) -> Self:
        """Construct a provider from environment variables."""
        ...

    @abstractmethod
    def record_is(self, name: str, rtype: str, value: str) -> bool:
        """Return True if the existing RRSet equals `value`,
        or if it's an alias / a multi-value set (skip with warning).
        Return False to signal an upsert is needed."""
        ...

    @abstractmethod
    def upsert(
        self, name: str, rtype: str, value: str, ttl: int, proxied: bool = False
    ) -> bool:
        """Create or update a single-value record to exactly `value` with `ttl`.
        Return True if an update was performed, False if record was already correct."""
        ...

    @abstractmethod
    def validate(self) -> None:
        """Raise a clear exception if creds/zone are not usable."""
        ...


def normalize_fqdn(s: str) -> str:
    """Return the canonical lowercase form of an FQDN without a trailing dot.
    Route 53 API calls need the trailing dot added back;
    Cloudflare does not. Use this form for all comparisons."""
    s = s.strip().lower()
    return "." if s == "." else s.rstrip(".")
