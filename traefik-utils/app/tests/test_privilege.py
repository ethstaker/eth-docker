from types import SimpleNamespace
from unittest.mock import Mock, patch

from privilege import PrivilegeManager


def manager() -> PrivilegeManager:
    pw = SimpleNamespace(pw_dir="/home/dns", pw_uid=1000, pw_gid=1000, pw_name="dns")
    with patch("privilege.pwd.getpwnam", return_value=pw):
        return PrivilegeManager("dns")


def test_copy_aws_config_does_nothing_when_source_missing() -> None:
    instance = manager()
    with (
        patch("privilege.os.path.exists", return_value=False),
        patch("privilege.shutil.copytree") as copy,
    ):
        instance.copy_aws_config()
    copy.assert_not_called()


def test_copy_aws_config_replaces_destination_and_secures_files() -> None:
    instance = manager()
    with (
        patch("privilege.os.path.exists", side_effect=[True, True]),
        patch("privilege.shutil.rmtree") as remove,
        patch("privilege.shutil.copytree") as copy,
        patch(
            "privilege.os.walk",
            return_value=[("/home/dns/.aws", ["sub"], ["credentials"])],
        ),
        patch("privilege.os.chown") as chown,
        patch("privilege.os.chmod") as chmod,
    ):
        instance.copy_aws_config()

    remove.assert_called_once_with("/home/dns/.aws")
    copy.assert_called_once_with("/root/.aws", "/home/dns/.aws")
    assert chown.call_count == 3
    chmod.assert_any_call("/home/dns/.aws/sub", 0o700)
    chmod.assert_any_call("/home/dns/.aws/credentials", 0o600)


def test_setup_copies_config_only_when_requested() -> None:
    instance = manager()
    instance.copy_aws_config = Mock()
    instance.drop = Mock()

    instance.setup(need_aws_config=False)
    instance.copy_aws_config.assert_not_called()
    instance.drop.assert_called_once_with()

    instance.drop.reset_mock()
    instance.setup(need_aws_config=True)
    instance.copy_aws_config.assert_called_once_with()
    instance.drop.assert_called_once_with()
