"""Serving the TUI to a browser on localhost, reached through an SSH tunnel."""

from urllib.parse import urlsplit

from aiohttp import web
from aiohttp.typedefs import Handler
from textual_serve.server import Server

LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1"}


@web.middleware
async def local_only(request: web.Request, handler: Handler) -> web.StreamResponse:
    """textual-serve has no login, and a browser lets any site's page connect to localhost.
    Refuse pages from other sites, and other Host names, which also stops DNS rebinding."""
    origin = request.headers.get("Origin")
    if request.url.host not in LOCAL_HOSTS or (
        origin is not None and urlsplit(origin).hostname not in LOCAL_HOSTS
    ):
        raise web.HTTPForbidden(text="Only reachable from localhost")
    return await handler(request)


class LocalServer(Server):
    async def _make_app(self) -> web.Application:
        app = await super()._make_app()
        app.middlewares.append(local_only)
        return app
