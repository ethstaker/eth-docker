from base import register_provider

from route53_provider import Route53Provider
from cf_provider import CloudflareProvider


def register_all() -> None:
    register_provider("route53", Route53Provider)
    register_provider("cloudflare", CloudflareProvider)
