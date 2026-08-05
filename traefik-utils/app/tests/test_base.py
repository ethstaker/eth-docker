from unittest.mock import Mock

import pytest

import base
import provider_registry


def test_normalize_fqdn_canonicalizes_names() -> None:
    assert base.normalize_fqdn("  WWW.Example.COM... ") == "www.example.com"
    assert base.normalize_fqdn(".") == "."


def test_register_and_build_provider_are_case_insensitive() -> None:
    provider = Mock()
    provider.from_env.return_value = provider
    base._provider_registry.clear()
    base.register_provider("Example", provider)
    privilege = Mock()

    result = base.build_provider(privilege, "EXAMPLE", {})

    assert result is provider
    privilege.setup.assert_called_once_with(need_aws_config=False)
    provider.from_env.assert_called_once_with({})
    provider.validate.assert_called_once_with()


def test_build_provider_enables_aws_config_for_route53() -> None:
    provider = Mock()
    provider.from_env.return_value = provider
    base._provider_registry.clear()
    base.register_provider("route53", provider)
    privilege = Mock()

    base.build_provider(privilege, "Route53", {})

    privilege.setup.assert_called_once_with(need_aws_config=True)


def test_build_provider_rejects_unknown_provider() -> None:
    base._provider_registry.clear()

    with pytest.raises(SystemExit, match="Unknown DNS_PROVIDER=missing"):
        base.build_provider(Mock(), "missing", {})


def test_register_all_registers_supported_providers() -> None:
    base._provider_registry.clear()

    provider_registry.register_all()

    assert set(base._provider_registry) == {"route53", "cloudflare"}
