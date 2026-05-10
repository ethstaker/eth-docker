import os
import pwd
import grp
import shutil
import subprocess


class PrivilegeManager:
    def __init__(self, user: str) -> None:
        self._user = user
        self._pw = pwd.getpwnam(user)

    def copy_aws_config(self) -> None:
        src = "/root/.aws"
        dst = os.path.join(self._pw.pw_dir, ".aws")

        if not os.path.exists(src):
            return

        if os.path.exists(dst):
            shutil.rmtree(dst)

        shutil.copytree(src, dst)

        subprocess.check_call(
            ["chown", "-R", f"{self._pw.pw_uid}:{self._pw.pw_gid}", dst]
        )

        for root, dirs, files in os.walk(dst):
            for d in dirs:
                os.chmod(os.path.join(root, d), 0o700)
            for f in files:
                os.chmod(os.path.join(root, f), 0o600)

    def drop(self) -> None:
        try:
            if hasattr(os, "initgroups"):
                os.initgroups(self._user, self._pw.pw_gid)
            else:
                gids = [g.gr_gid for g in grp.getgrall() if self._user in g.gr_mem]
                os.setgroups(gids + [self._pw.pw_gid])
        except PermissionError:
            pass

        if hasattr(os, "setresgid") and hasattr(os, "setresuid"):
            os.setresgid(self._pw.pw_gid, self._pw.pw_gid, self._pw.pw_gid)
            os.setresuid(self._pw.pw_uid, self._pw.pw_uid, self._pw.pw_uid)
        else:
            os.setgid(self._pw.pw_gid)
            os.setuid(self._pw.pw_uid)

        os.environ.update(
            HOME=self._pw.pw_dir,
            USER=self._pw.pw_name,
            LOGNAME=self._pw.pw_name,
        )
        os.environ.setdefault(
            "AWS_SHARED_CREDENTIALS_FILE",
            f"{self._pw.pw_dir}/.aws/credentials",
        )
        os.environ.setdefault(
            "AWS_CONFIG_FILE",
            f"{self._pw.pw_dir}/.aws/config",
        )

        os.chdir(self._pw.pw_dir)

    def setup(self, need_aws_config: bool = False) -> None:
        if need_aws_config:
            self.copy_aws_config()
        self.drop()
