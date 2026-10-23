"""The browser mode refuses pages from other sites."""

import unittest

from aiohttp import web
from aiohttp.test_utils import make_mocked_request

from ethd_tui.web import local_only


async def _ok(request: web.Request) -> web.StreamResponse:
    return web.Response(text="ok")


class LocalOnly(unittest.IsolatedAsyncioTestCase):
    async def check(self, headers: dict[str, str]) -> bool:
        try:
            await local_only(make_mocked_request("GET", "/ws", headers=headers), _ok)
        except web.HTTPForbidden:
            return False
        return True

    async def test_local_pages_pass(self) -> None:
        self.assertTrue(await self.check({"Host": "localhost:8000"}))
        # An SSH tunnel may use another local port
        self.assertTrue(
            await self.check(
                {"Host": "127.0.0.1:9000", "Origin": "http://127.0.0.1:9000"}
            )
        )

    async def test_other_sites_are_refused(self) -> None:
        self.assertFalse(
            await self.check(
                {"Host": "localhost:8000", "Origin": "https://evil.example"}
            )
        )
        # DNS rebinding: an attacker's name that resolves to 127.0.0.1
        self.assertFalse(
            await self.check(
                {"Host": "evil.example:8000", "Origin": "http://evil.example:8000"}
            )
        )


if __name__ == "__main__":
    unittest.main()
