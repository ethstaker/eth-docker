"""Drive the config screen headless at 80x24, with a stand-in for "ethd apply-config"."""

import argparse
import stat
import tempfile
import unittest
from pathlib import Path

from textual.widgets import RadioButton, Select

from ethd_tui import catalog
from ethd_tui.app import ConfigScreen, EthdApp, ReviewScreen

REPO = Path(__file__).resolve().parents[2]


class ConfigScreenTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        (self.tmp / ".env").write_text("CORE_FILES=teku.yml:besu.yml\nGRAFFITI=\n")
        fake = self.tmp / "ethd"
        # Like ethd, generate a Siren password while saving
        fake.write_text(
            '#!/bin/sh\ncp "$2" "$(dirname "$0")/applied"\n'
            'echo SIREN_PASSWORD=generated >> "$(dirname "$0")/.env"\n'
        )
        fake.chmod(fake.stat().st_mode | stat.S_IEXEC)
        self.app = EthdApp(
            argparse.Namespace(
                screen="config",
                env_file=str(self.tmp / ".env"),
                default_env=str(REPO / "default.env"),
                ethd=str(fake),
            )
        )

    async def test_choose_and_save(self) -> None:
        async with self.app.run_test(size=(80, 24)) as pilot:
            screen = self.app.screen
            assert isinstance(screen, ConfigScreen)
            await screen.jump("el", "EL_P2P_PORT")
            await pilot.pause()
            await pilot.click("#choice-el--reth")
            await pilot.pause()
            self.assertEqual(screen.stack.choice["el"], "reth")
            self.assertTrue(self.app.screen.query("#var-RETH_SNAPSHOT"))
            self.app.screen.query_one("#exposure-el-rpc", Select).value = "shared"
            await pilot.pause()
            await pilot.press("ctrl+s")
            await pilot.pause()
            self.assertIsInstance(self.app.screen, ReviewScreen)
            await pilot.click("#save")
            for _ in range(50):
                await pilot.pause(0.05)
                if (self.tmp / "applied").exists():
                    break
            await pilot.pause(0.2)
            # Nothing is left to save, so a second save cannot blank the generated password
            self.assertEqual(catalog.changes(screen.cat, screen.stack, screen.env), {})
        applied = (self.tmp / "applied").read_bytes().split(b"\0")
        self.assertEqual(
            dict(zip(applied[::2], applied[1::2])),
            {b"CORE_FILES": b"reth.yml:teku.yml:el-shared.yml"},
        )

    async def test_unavailable_client_is_disabled(self) -> None:
        (self.tmp / ".env").write_text("CORE_FILES=teku.yml:besu.yml\nNETWORK=gnosis\n")
        async with self.app.run_test(size=(80, 24)) as pilot:
            screen = self.app.screen
            assert isinstance(screen, ConfigScreen)
            await screen.jump("cl", "CL_P2P_PORT")
            await pilot.pause()
            self.assertTrue(
                self.app.screen.query_one("#choice-cl--prysm", RadioButton).disabled
            )


if __name__ == "__main__":
    unittest.main()
