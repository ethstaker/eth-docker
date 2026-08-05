from unittest.mock import Mock, patch

import pytest
from botocore.exceptions import ClientError

from route53_provider import AwsCredentialResolver, Route53Provider


def error(code: str) -> ClientError:
    return ClientError({"Error": {"Code": code}}, "operation")


def provider_with_client() -> tuple[Route53Provider, Mock]:
    session = Mock()
    client = Mock()
    session.client.side_effect = lambda name: client
    return Route53Provider("Z123", session), client


def test_record_is_normalizes_and_matches_single_record() -> None:
    provider, client = provider_with_client()
    client.list_resource_record_sets.return_value = {
        "ResourceRecordSets": [
            {
                "Name": "WWW.Example.COM.",
                "Type": "A",
                "ResourceRecords": [{"Value": "192.0.2.1"}],
            }
        ]
    }

    assert provider.record_is("www.example.com", "A", "192.0.2.1.") is True
    client.list_resource_record_sets.assert_called_once_with(
        HostedZoneId="Z123",
        StartRecordName="www.example.com.",
        StartRecordType="A",
        MaxItems="1",
    )


def test_record_is_skips_alias_and_multi_value_records() -> None:
    provider, client = provider_with_client()
    client.list_resource_record_sets.return_value = {
        "ResourceRecordSets": [
            {"Name": "x.example.com.", "Type": "A", "AliasTarget": {}}
        ]
    }
    assert provider.record_is("x.example.com", "A", "192.0.2.1") is True
    client.list_resource_record_sets.return_value = {
        "ResourceRecordSets": [
            {
                "Name": "x.example.com.",
                "Type": "A",
                "ResourceRecords": [{"Value": "192.0.2.1"}, {"Value": "192.0.2.2"}],
            }
        ]
    }
    assert provider.record_is("x.example.com", "A", "192.0.2.1") is True


def test_record_is_fails_open_on_client_error() -> None:
    provider, client = provider_with_client()
    client.list_resource_record_sets.side_effect = error("AccessDenied")

    assert provider.record_is("x.example.com", "A", "192.0.2.1") is True


def test_upsert_skips_correct_record() -> None:
    provider, client = provider_with_client()
    client.list_resource_record_sets.return_value = {
        "ResourceRecordSets": [
            {
                "Name": "x.example.com.",
                "Type": "A",
                "ResourceRecords": [{"Value": "192.0.2.1"}],
            }
        ]
    }

    assert provider.upsert("x.example.com", "A", "192.0.2.1", 60) is False
    client.change_resource_record_sets.assert_not_called()


def test_upsert_sends_route53_upssert_payload() -> None:
    provider, client = provider_with_client()
    client.list_resource_record_sets.return_value = {"ResourceRecordSets": []}

    assert provider.upsert("x.example.com", "CNAME", "target.example.com.", 300) is True
    client.change_resource_record_sets.assert_called_once_with(
        HostedZoneId="Z123",
        ChangeBatch={
            "Comment": "Auto-updated CNAME record for x.example.com",
            "Changes": [
                {
                    "Action": "UPSERT",
                    "ResourceRecordSet": {
                        "Name": "x.example.com.",
                        "Type": "CNAME",
                        "TTL": 300,
                        "ResourceRecords": [{"Value": "target.example.com"}],
                    },
                }
            ],
        },
    )


def test_validate_wraps_errors() -> None:
    provider, client = provider_with_client()
    client.get_hosted_zone.side_effect = error("NoSuchHostedZone")
    provider._session.client.return_value.get_caller_identity.return_value = {
        "Arn": "arn",
        "Account": "1",
    }

    with pytest.raises(RuntimeError, match="Route53 validation failed"):
        provider.validate()


def test_credential_resolver_prefers_environment_credentials(monkeypatch) -> None:
    monkeypatch.setenv("AWS_PROFILE", "profile")
    env = {"AWS_ACCESS_KEY_ID": "key", "AWS_SECRET_ACCESS_KEY": "secret"}
    with patch("route53_provider.boto3.session.Session") as session:
        AwsCredentialResolver(env).resolve()
    session.assert_called_once_with()


def test_credential_resolver_uses_existing_profile_file(monkeypatch) -> None:
    monkeypatch.setenv("AWS_SHARED_CREDENTIALS_FILE", "/tmp/credentials")
    env = {"AWS_PROFILE": " profile "}
    with (
        patch("route53_provider.os.path.exists", return_value=True),
        patch("route53_provider.boto3.session.Session") as session,
    ):
        AwsCredentialResolver(env).resolve()
    session.assert_called_once_with(profile_name="profile")


def test_credential_resolver_rejects_incomplete_credentials(monkeypatch) -> None:
    monkeypatch.setenv("AWS_SHARED_CREDENTIALS_FILE", "/tmp/missing")
    with pytest.raises(RuntimeError, match="No valid AWS credentials"):
        AwsCredentialResolver({"AWS_ACCESS_KEY_ID": "key"}).resolve()
