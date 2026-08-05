from unittest.mock import Mock
import logging

import pytest
import requests

import updater


@pytest.mark.parametrize(
    ("value", "expected"),
    [("192.0.2.1", True), ("2001:db8::1", False), ("not-an-ip", False)],
)
def test_validate_ipv4(value: str, expected: bool) -> None:
    assert updater.validate_ipv4(value) is expected


@pytest.mark.parametrize(
    ("value", "expected"),
    [("2001:db8::1", True), ("192.0.2.1", False), ("not-an-ip", False)],
)
def test_validate_ipv6(value: str, expected: bool) -> None:
    assert updater.validate_ipv6(value) is expected


@pytest.mark.parametrize(
    ("label", "domain", "expected"),
    [
        ("api", "Example.COM.", "api.Example.COM."),
        ("api.", "example.com", "api.example.com."),
        ("api.example.com.", "example.com", "api.example.com."),
    ],
)
def test_build_cname_fqdn(label: str, domain: str, expected: str) -> None:
    assert updater.build_cname_fqdn(label, domain) == expected


def test_build_cname_fqdn_rejects_empty_label() -> None:
    with pytest.raises(ValueError, match="Empty CNAME entry"):
        updater.build_cname_fqdn(" . ", "example.com")


def test_get_external_ip4_uses_first_valid_service(monkeypatch) -> None:
    responses = [
        Mock(ok=True, text="not an address"),
        Mock(ok=True, text=" 192.0.2.7\n"),
    ]
    request = Mock(side_effect=responses)
    monkeypatch.setattr(updater.requests, "get", request)

    assert (
        updater.get_external_ip4.retry_with(stop=updater.stop_after_attempt(1))()
        == "192.0.2.7"
    )
    assert request.call_count == 2


def test_get_external_ip6_returns_none_when_services_have_no_ipv6(monkeypatch) -> None:
    monkeypatch.setattr(
        updater.requests,
        "get",
        Mock(return_value=Mock(ok=True, text="192.0.2.1")),
    )

    assert (
        updater.get_external_ip6.retry_with(stop=updater.stop_after_attempt(1))()
        is None
    )


def test_get_external_ip4_retries_request_failures(monkeypatch) -> None:
    monkeypatch.setattr(
        updater.requests,
        "get",
        Mock(side_effect=requests.RequestException("offline")),
    )

    with pytest.raises(Exception) as exc_info:
        updater.get_external_ip4.retry_with(stop=updater.stop_after_attempt(1))()
    assert exc_info.value.__cause__ is not None
    assert "Unable to fetch" in str(exc_info.value.__cause__)


def test_main_runs_one_cycle_and_applies_proxy_overrides(monkeypatch) -> None:
    provider = Mock(allows_apex_cname=False)
    privilege = Mock()
    monkeypatch.setattr(updater, "register_all", Mock())
    monkeypatch.setattr(updater, "PrivilegeManager", Mock(return_value=privilege))
    monkeypatch.setattr(updater, "build_provider", Mock(return_value=provider))
    monkeypatch.setattr(updater, "get_external_ip4", Mock(return_value="192.0.2.7"))
    monkeypatch.setattr(updater, "get_external_ip6", Mock(return_value="2001:db8::7"))
    monkeypatch.setattr(updater.signal, "signal", Mock())
    monkeypatch.setenv("RUN_AS_USER", "dns")
    monkeypatch.setenv("DNS_PROVIDER", "cloudflare")
    monkeypatch.setenv("DDNS_HOST", "node")
    monkeypatch.setenv("DOMAIN", "Example.COM.")
    monkeypatch.setenv("CNAME_LIST", "grafana:proxy,rpc:noproxy, plain")
    monkeypatch.setenv("CF_PROXY", "true")
    monkeypatch.setenv("TTL", "60")
    monkeypatch.setenv("SLEEP", "1")

    def stop(_):
        raise RuntimeError("stop")

    monkeypatch.setattr(updater.time, "sleep", stop)

    with pytest.raises(RuntimeError, match="stop"):
        updater.main()

    assert provider.upsert.call_args_list == [
        (("node.example.com.", "A", "192.0.2.7", 60), {"proxied": True}),
        (("node.example.com.", "AAAA", "2001:db8::7", 60), {"proxied": True}),
        (("grafana.Example.COM.", "CNAME", "node.example.com.", 60), {"proxied": True}),
        (("rpc.Example.COM.", "CNAME", "node.example.com.", 60), {"proxied": False}),
        (("plain.Example.COM.", "CNAME", "node.example.com.", 60), {"proxied": True}),
    ]


def test_main_skips_aaaa_when_no_external_ipv6(monkeypatch) -> None:
    provider = Mock(allows_apex_cname=True)
    monkeypatch.setattr(updater, "register_all", Mock())
    monkeypatch.setattr(updater, "PrivilegeManager", Mock(return_value=Mock()))
    monkeypatch.setattr(updater, "build_provider", Mock(return_value=provider))
    monkeypatch.setattr(updater, "get_external_ip4", Mock(return_value="192.0.2.7"))
    monkeypatch.setattr(updater, "get_external_ip6", Mock(return_value=None))
    monkeypatch.setattr(updater.signal, "signal", Mock())
    monkeypatch.setenv("DDNS_HOST", "node")
    monkeypatch.setenv("DOMAIN", "example.com")
    monkeypatch.setenv("CNAME_LIST", "")
    monkeypatch.setenv("SLEEP", "1")

    monkeypatch.setattr(updater.time, "sleep", Mock(side_effect=RuntimeError("stop")))

    with pytest.raises(RuntimeError, match="stop"):
        updater.main()

    assert [call.args[1] for call in provider.upsert.call_args_list] == ["A"]


def test_main_continues_after_provider_error(monkeypatch) -> None:
    provider = Mock(allows_apex_cname=True)
    provider.upsert.side_effect = RuntimeError("provider unavailable")
    sleeps = Mock(side_effect=[None, RuntimeError("stop")])
    monkeypatch.setattr(updater, "register_all", Mock())
    monkeypatch.setattr(updater, "PrivilegeManager", Mock(return_value=Mock()))
    monkeypatch.setattr(updater, "build_provider", Mock(return_value=provider))
    monkeypatch.setattr(updater, "get_external_ip4", Mock(return_value="192.0.2.7"))
    monkeypatch.setattr(updater, "get_external_ip6", Mock(return_value=None))
    monkeypatch.setattr(updater.signal, "signal", Mock())
    monkeypatch.setattr(updater.time, "sleep", sleeps)
    monkeypatch.setenv("DDNS_HOST", "node")
    monkeypatch.setenv("DOMAIN", "example.com")
    monkeypatch.setenv("CNAME_LIST", "")
    monkeypatch.setenv("SLEEP", "1")

    with pytest.raises(RuntimeError, match="stop"):
        updater.main()

    assert provider.upsert.call_count == 2
    assert sleeps.call_count == 2


def test_main_skips_apex_cname_for_provider_that_disallows_it(monkeypatch) -> None:
    provider = Mock(allows_apex_cname=False)
    monkeypatch.setattr(updater, "register_all", Mock())
    monkeypatch.setattr(updater, "PrivilegeManager", Mock(return_value=Mock()))
    monkeypatch.setattr(updater, "build_provider", Mock(return_value=provider))
    monkeypatch.setattr(updater, "get_external_ip4", Mock(return_value="192.0.2.7"))
    monkeypatch.setattr(updater, "get_external_ip6", Mock(return_value=None))
    monkeypatch.setattr(updater.signal, "signal", Mock())
    monkeypatch.setenv("DDNS_HOST", "node")
    monkeypatch.setenv("DOMAIN", "example.com")
    monkeypatch.setenv("CNAME_LIST", "example.com")
    monkeypatch.setenv("SLEEP", "1")
    monkeypatch.setattr(updater, "build_cname_fqdn", Mock(return_value="example.com."))
    monkeypatch.setattr(updater.time, "sleep", Mock(side_effect=RuntimeError("stop")))

    with pytest.raises(RuntimeError, match="stop"):
        updater.main()

    provider.upsert.assert_called_once_with(
        "node.example.com.", "A", "192.0.2.7", 300, proxied=False
    )


def test_shutdown_exits_successfully() -> None:
    with pytest.raises(SystemExit) as exc_info:
        updater._shutdown(15, None)

    assert exc_info.value.code == 0


def test_setup_logger_configures_handler_and_level(monkeypatch) -> None:
    logger = logging.getLogger("dns-updater")
    logger.handlers.clear()
    monkeypatch.setattr(updater, "logger", logger)
    monkeypatch.setenv("LOG_LEVEL", "DEBUG")

    result = updater.setup_logger()

    assert result is logger
    assert logger.level == logging.DEBUG
    assert len(logger.handlers) == 1
    updater.setup_logger()
    assert len(logger.handlers) == 1
