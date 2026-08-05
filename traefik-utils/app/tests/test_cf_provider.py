from unittest.mock import Mock, patch

import pytest

from cf_provider import CloudflareProvider


def response(name="x.example.com", content="192.0.2.1", proxied=False, record_id="id"):
    return Mock(name=name, content=content, proxied=proxied, id=record_id)


def provider_with_records(records):
    client = Mock()
    client.dns.records.list.return_value = Mock(result=records)
    with patch("cf_provider.Cloudflare", return_value=client):
        provider = CloudflareProvider("zone", "token")
    return provider, client


def test_record_is_compares_content_and_proxy_state() -> None:
    provider, client = provider_with_records([response()])

    assert provider.record_is("X.Example.COM.", "A", "192.0.2.1.") is True
    assert provider.record_is("x.example.com", "A", "192.0.2.2") is False
    assert provider.record_is("x.example.com", "A", "192.0.2.1", proxied=True) is False
    assert client.dns.records.list.call_args.kwargs["name"] == "x.example.com"


def test_record_is_skips_multiple_records() -> None:
    provider, _ = provider_with_records([response(), response(content="192.0.2.2")])

    assert provider.record_is("x.example.com", "A", "192.0.2.1") is True


def test_upsert_creates_a_record_with_ttl() -> None:
    provider, client = provider_with_records([])

    assert provider.upsert("x.example.com.", "A", "192.0.2.7", 60, proxied=True) is True
    client.dns.records.create.assert_called_once_with(
        zone_id="zone",
        name="x.example.com",
        type="A",
        content="192.0.2.7",
        ttl=60,
        proxied=True,
    )


def test_upsert_updates_existing_cname_without_ttl() -> None:
    provider, client = provider_with_records(
        [response(content="old.example.com", record_id="record")]
    )

    assert provider.upsert("x.example.com", "CNAME", "new.example.com", 300) is True
    client.dns.records.update.assert_called_once_with(
        dns_record_id="record",
        zone_id="zone",
        name="x.example.com",
        type="CNAME",
        content="new.example.com",
        proxied=False,
    )


def test_upsert_skips_correct_record() -> None:
    provider, client = provider_with_records([response()])

    assert provider.upsert("x.example.com", "A", "192.0.2.1", 60) is False
    client.dns.records.create.assert_not_called()
    client.dns.records.update.assert_not_called()


def test_validate_wraps_api_errors() -> None:
    provider, client = provider_with_records([])
    client.dns.records.list.side_effect = RuntimeError("forbidden")

    with pytest.raises(RuntimeError, match="Cloudflare validation failed"):
        provider.validate()
