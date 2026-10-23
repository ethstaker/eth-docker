"""Eth Docker terminal UI. "./ethd config" opens the config screen directly, "./ethd tui" the menu."""

import argparse
import asyncio
import os
import platform
import shlex
import sys
import tempfile
from collections.abc import Iterator
from functools import partial
from pathlib import Path
from typing import ClassVar

from textual import events, on, work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.command import Hit, Hits, Provider
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.markup import escape
from textual.screen import ModalScreen, Screen
from textual.suggester import SuggestFromList
from textual.validation import Integer
from textual.widget import Widget
from textual.widgets import (
    Button,
    Checkbox,
    Collapsible,
    Footer,
    Header,
    Input,
    Label,
    ListItem,
    ListView,
    OptionList,
    RadioButton,
    RadioSet,
    RichLog,
    Select,
    Static,
    TextArea,
)

from . import catalog, envfile
from .catalog import Role, Stack

MODES = {"internal": "Internal", "shared": "Host", "traefik": "Traefik", "both": "Both"}
SECRET_WORDS = ("PASSWORD", "TOKEN", "SECRET")
SIDEBAR_TEXT = 24  # sidebar width less padding, see app.tcss
# Enums that also take free text, such as a custom network URL
OPEN_ENUMS = {"NETWORK"}


def _secret(name: str) -> bool:
    return any(w in name for w in SECRET_WORDS)


class Choices(RadioSet):
    """A RadioSet whose cursor starts on the pressed button rather than the first one."""

    def on_mount(self) -> None:
        if self.pressed_index >= 0:
            self._selected = self.pressed_index


class SettingsSearch(Provider):
    """Command palette entries for every setting, to jump straight to it."""

    def _entries(self) -> Iterator[tuple[str, str, str]]:
        screen = self.screen
        assert isinstance(screen, ConfigScreen)
        for role in screen.cat.roles:
            names = role.essentials + role.advanced + role.none_vars
            for comp in role.choices + role.addons:
                names += comp.vars + screen.cat.image_vars(comp)
            for e in role.exposures:
                names += e.vars + e.traefik_vars
            for name in dict.fromkeys(names):
                yield role.id, name, f"{role.label}: {screen.cat.label(name)}  {name}"

    async def search(self, query: str) -> Hits:
        matcher = self.matcher(query)
        screen = self.screen
        assert isinstance(screen, ConfigScreen)
        for role_id, name, text in self._entries():
            if (score := matcher.match(text)) > 0:
                yield Hit(
                    score,
                    matcher.highlight(text),
                    partial(screen.jump, role_id, name),
                    help=screen.cat.help.get(name, ""),
                )


class ReviewScreen(ModalScreen[bool]):
    """What saving would change, and the issues that block it."""

    BINDINGS: ClassVar = [Binding("escape", "dismiss(False)", "Back")]

    def __init__(
        self,
        issues: list[catalog.Issue],
        changes: dict[str, str],
        current: dict[str, str],
    ) -> None:
        super().__init__()
        self.issues = issues
        self.changes = changes
        self.current = current

    def compose(self) -> ComposeResult:
        errors = any(i.error for i in self.issues)
        with Vertical(id="review"):
            yield Label("Review changes", classes="title")
            with VerticalScroll():
                for i in self.issues:
                    yield Static(
                        f"{'✖' if i.error else '⚠'} {i.text}",
                        classes="error" if i.error else "warning",
                    )
                if not self.changes:
                    yield Static("Nothing to change.")
                for name, value in self.changes.items():
                    old, new = (
                        escape(self.current.get(name, "")),
                        escape(envfile.unquote(value)),
                    )
                    if _secret(name):
                        old, new = "•" * min(len(old), 8), "•" * min(len(new), 8)
                    yield Static(
                        f"[b]{name}[/b]\n  [red]- {old}[/red]\n  [green]+ {new}[/green]",
                        markup=True,
                    )
                yield RichLog(id="output", wrap=True, markup=False)
            with Horizontal(classes="buttons"):
                yield Button(
                    "Save",
                    id="save",
                    variant="primary",
                    disabled=errors or not self.changes,
                )
                yield Button("Back", id="back")

    @on(Button.Pressed, "#back")
    def back(self) -> None:
        self.dismiss(False)

    @on(Button.Pressed, "#save")
    def save(self) -> None:
        self.query_one("#save", Button).disabled = True
        self.apply()

    @work(exclusive=True)
    async def apply(self) -> None:
        """Hand the changes to ethd, which writes .env the same way the wizard does."""
        app = self.app
        assert isinstance(app, EthdApp)
        log = self.query_one("#output", RichLog)
        with tempfile.NamedTemporaryFile("wb", prefix="ethd-tui-", delete=False) as f:
            for name, value in self.changes.items():
                f.write(name.encode() + b"\0" + value.encode() + b"\0")
        try:
            proc = await asyncio.create_subprocess_exec(
                *app.ethd,
                "apply-config",
                f.name,
                stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
            )
            assert proc.stdout
            async for line in proc.stdout:
                log.write(line.decode(errors="replace").rstrip())
            ok = await proc.wait() == 0
        finally:
            os.unlink(f.name)
        if ok:
            self.notify("Configuration saved")
            self.dismiss(True)
        else:
            log.write(
                "Saving stopped, see above. Some values may already be written;"
                " open Review again to compare."
            )
            self.query_one("#save", Button).disabled = False


class ConfigScreen(Screen[None]):
    """Master-detail: roles on the left, the selected role's settings on the right."""

    COMMANDS: ClassVar = {SettingsSearch}
    BINDINGS: ClassVar = [
        Binding("ctrl+s", "review", "Review & save"),
        Binding("a", "toggle_advanced", "Advanced"),
        Binding("escape", "focus_roles", "Roles", show=False),
        Binding("q", "quit_config", "Quit"),
    ]

    def __init__(self, env_file: Path, default_env: Path, arch: str) -> None:
        super().__init__()
        self.env_file = env_file
        self.arch = arch
        self.cat = catalog.load(default_env.read_text())
        self.env = envfile.load(env_file)
        self.stack: Stack = catalog.from_env(self.cat, self.env)
        self.issues: list[catalog.Issue] = []
        self.role_id = "stack"
        self.open_sections: set[str] = set()
        self.quit_armed = False
        self.building = asyncio.Lock()

    def compose(self) -> ComposeResult:
        yield Header()
        with Horizontal():
            with Vertical(id="sidebar"):
                yield ListView(
                    *[
                        ListItem(
                            Label(r.label, id=f"rolelabel-{r.id}"), id=f"role-{r.id}"
                        )
                        for r in self.cat.roles
                    ],
                    id="roles",
                )
                yield Static(id="issues")
                yield Button("Review & save", id="review-button", compact=True)
            yield VerticalScroll(id="detail")
        yield Static(id="help")
        yield Footer()

    def on_mount(self) -> None:
        self.title = "Eth Docker"
        self.sub_title = f"Config · {self.env_file.name} · {self.arch}"
        self.refresh_status()
        self.query_one("#roles", ListView).focus()
        self.call_later(self.build_detail)

    # ---- building the detail pane

    @on(ListView.Highlighted, "#roles")
    async def role_highlighted(self, event: ListView.Highlighted) -> None:
        if (
            event.item
            and event.item.id
            and event.item.id.removeprefix("role-") != self.role_id
        ):
            self.role_id = event.item.id.removeprefix("role-")
            await self.build_detail()

    async def build_detail(self) -> None:
        # Highlighting a role and jumping to a setting can both rebuild at once
        async with self.building:
            detail = self.query_one("#detail", VerticalScroll)
            await detail.remove_children()
            await detail.mount_all(list(self.role_widgets(self.cat.role(self.role_id))))

    def role_widgets(self, role: Role) -> Iterator[Widget]:
        stack, cat = self.stack, self.cat
        network = stack.values.get("NETWORK", "")
        choice = role.choice(stack.choice[role.id])
        yield Label(role.label, classes="title")
        if role.choices:
            none_label = "None, external service" if role.none_vars else "None"
            buttons = [
                RadioButton(
                    none_label, value=choice is None, id=f"choice-{role.id}--none"
                )
            ]
            for c in role.choices:
                reason = catalog.unavailable(c, network, self.arch)
                buttons.append(
                    RadioButton(
                        c.label + (f"  ({reason})" if reason else ""),
                        value=choice is c,
                        disabled=bool(reason) and choice is not c,
                        id=f"choice-{role.id}--{c.id}",
                    )
                )
            yield Choices(*buttons, id=f"choices-{role.id}", compact=True)
        if choice and choice.note:
            yield Static(choice.note, classes="note")
        for issue in self.issues:
            if issue.role == role.id:
                yield Static(
                    f"{'✖' if issue.error else '⚠'} {issue.text}",
                    classes="error" if issue.error else "warning",
                )

        essentials, advanced, image = catalog.visible_vars(cat, stack, role)
        yield from (self.field(n) for n in essentials)
        for a in role.addons:
            if catalog.addon_visible(stack, a):
                yield Checkbox(
                    a.label, a.id in stack.addons, id=f"addon-{a.id}", compact=True
                )
        for e in role.exposures:
            if catalog.exposure_visible(stack, role, e):
                yield self.exposure(e)
        if role.id == "stack" and stack.unmanaged:
            yield Static(
                "Kept in CORE_FILES as-is: " + ", ".join(stack.unmanaged),
                classes="note",
            )
        for section, names in (("Advanced", advanced), ("Image & build", image)):
            if names:
                key = f"{role.id}:{section}"
                yield Collapsible(
                    *[self.field(n) for n in names],
                    title=section,
                    collapsed=key not in self.open_sections,
                    id=f"section-{role.id}-{section[0]}",
                )

    def field(self, name: str) -> Widget:
        value = self.stack.values.get(name, "")
        label = self.cat.label(name)
        wid = f"var-{name}"
        widget: Widget
        if self.cat.defaults.get(name) in ("true", "false"):
            return Checkbox(
                label, value == "true", id=wid, compact=True, classes="field-bool"
            )
        if name in self.cat.enums and name not in OPEN_ENUMS:
            options = list(dict.fromkeys(self.cat.enums[name] + [value]))
            widget = Select(
                [(o, o) for o in options],
                value=value,
                allow_blank=False,
                id=wid,
                compact=True,
            )
        elif "\n" in value:
            widget = TextArea(value.strip("\n"), id=wid, classes="multiline")
        elif name.endswith("_PORT"):
            widget = Input(
                value,
                id=wid,
                type="integer",
                validators=[Integer(1, 65535)],
                compact=True,
            )
        else:
            suggester = (
                SuggestFromList(self.cat.enums[name], case_sensitive=False)
                if name in self.cat.enums
                else None
            )
            widget = Input(
                value, id=wid, password=_secret(name), suggester=suggester, compact=True
            )
        widget.tooltip = self.cat.help.get(name) or None
        return Horizontal(Label(label, classes="field-label"), widget, classes="field")

    def exposure(self, e: catalog.Exposure) -> Widget:
        kinds = self.stack.exposure.get(e.id, set())
        current = "both" if len(kinds) == 2 else next(iter(kinds), "internal")
        modes = (
            ["internal"]
            + [k for k in ("shared", "traefik") if getattr(e, k)]
            + (["both"] if e.shared and e.traefik else [])
        )
        # A dropdown, as four radio buttons do not fit next to the label at 80 columns
        select = Select(
            [(MODES[m], m) for m in modes],
            value=current,
            allow_blank=False,
            id=f"exposure-{e.id}",
            compact=True,
        )
        return Horizontal(
            Label(e.label, classes="field-label"), select, classes="field"
        )

    # ---- reacting to edits

    @on(RadioSet.Changed)
    async def radio_changed(self, event: RadioSet.Changed) -> None:
        set_id, pressed = event.radio_set.id or "", event.pressed.id or ""
        _, _, value = pressed.partition("--")
        if set_id.startswith("choices-"):
            role_id = set_id.removeprefix("choices-")
            new = None if value == "none" else value
            if self.stack.choice[role_id] == new:
                return
            self.stack.choice[role_id] = new
        else:
            return
        await self.rebuild(event.radio_set.id)

    @on(Checkbox.Changed)
    async def checkbox_changed(self, event: Checkbox.Changed) -> None:
        wid = event.checkbox.id or ""
        if wid.startswith("addon-"):
            addon = wid.removeprefix("addon-")
            if (addon in self.stack.addons) != event.value:
                self.stack.addons ^= {addon}
                await self.rebuild(wid)
        elif wid.startswith("var-"):
            self.set_value(wid.removeprefix("var-"), "true" if event.value else "false")

    @on(Input.Changed)
    @on(Select.Changed)
    async def input_changed(self, event: Input.Changed | Select.Changed) -> None:
        wid = event.control.id or ""
        if not isinstance(event.value, str):
            return
        if wid.startswith("var-"):
            self.set_value(wid.removeprefix("var-"), event.value)
        elif wid.startswith("exposure-"):
            exposure = wid.removeprefix("exposure-")
            kinds = {"internal": set(), "both": {"shared", "traefik"}}.get(
                event.value, {event.value}
            )
            if self.stack.exposure.get(exposure, set()) != kinds:
                self.stack.exposure[exposure] = kinds
                await self.rebuild(wid)

    @on(TextArea.Changed)
    def text_changed(self, event: TextArea.Changed) -> None:
        wid = event.text_area.id or ""
        if wid.startswith("var-"):
            # Keep the leading and trailing newline that multi-line values such as MEV_RELAYS have
            self.set_value(
                wid.removeprefix("var-"), "\n" + event.text_area.text.strip("\n") + "\n"
            )

    @on(Collapsible.Toggled)
    def section_toggled(self, event: Collapsible.Toggled) -> None:
        key = f"{self.role_id}:{event.collapsible.title}"
        self.open_sections ^= (
            {key}
            if (key in self.open_sections) == event.collapsible.collapsed
            else set()
        )

    @on(Button.Pressed, "#review-button")
    def review_pressed(self) -> None:
        self.action_review()

    def set_value(self, name: str, value: str) -> None:
        if self.stack.values.get(name) != value:
            self.stack.values[name] = value
            self.refresh_status()

    async def rebuild(self, focus_id: str | None) -> None:
        self.refresh_status()
        await self.build_detail()
        if focus_id:
            for w in self.query(f"#{focus_id}"):
                w.focus()

    def refresh_status(self) -> None:
        self.issues = issues = catalog.validate(self.cat, self.stack, self.arch)
        for r in self.cat.roles:
            mark = (
                "✖ "
                if any(i.error and i.role == r.id for i in issues)
                else "⚠ "
                if any(i.role == r.id for i in issues)
                else ""
            )
            if r.choices:
                c = r.choice(self.stack.choice[r.id])
                summary = c.label.split(" (")[0].split(",")[0] if c else "–"
            else:
                summary = str(sum(a.id in self.stack.addons for a in r.addons) or "")
            room = SIDEBAR_TEXT - len(mark) - len(r.label) - 2
            summary = (
                summary if len(summary) <= room else summary[: max(room - 1, 0)] + "…"
            )
            self.query_one(f"#rolelabel-{r.id}", Label).update(
                f"{mark}{r.label}  [dim]{summary}[/dim]"
            )
        errors = sum(i.error for i in issues)
        self.query_one("#issues", Static).update(
            f"[red]✖ {errors} error(s)[/red] " * bool(errors)
            + f"[yellow]⚠ {len(issues) - errors}[/yellow]" * bool(len(issues) - errors)
        )

    def on_descendant_focus(self, event: events.DescendantFocus) -> None:
        wid = self.focused.id if self.focused else None
        text = ""
        if wid and wid.startswith("var-"):
            name = wid.removeprefix("var-")
            text = f"[b]{name}[/b]  {self.cat.help.get(name, '').replace(chr(10), ' ')}"
        self.query_one("#help", Static).update(text)

    # ---- actions

    async def jump(self, role_id: str, name: str) -> None:
        """Open the role a setting is in, unfold its section and focus it."""
        self.role_id = (
            role_id  # before moving the highlight, so that does not rebuild as well
        )
        self.query_one("#roles", ListView).index = [r.id for r in self.cat.roles].index(
            role_id
        )
        self.open_sections |= {f"{role_id}:Advanced", f"{role_id}:Image & build"}
        await self.build_detail()
        if fields := self.query(f"#var-{name}"):
            fields.first().focus()
            fields.first().scroll_visible()
        else:
            self.notify(
                f"{name} is not used by the current choice for {self.cat.role(role_id).label}"
            )

    async def action_toggle_advanced(self) -> None:
        key = f"{self.role_id}:Advanced"
        self.open_sections ^= {key}
        await self.build_detail()

    def action_focus_roles(self) -> None:
        self.query_one("#roles", ListView).focus()

    def action_review(self) -> None:
        issues = catalog.validate(self.cat, self.stack, self.arch)
        changes = catalog.changes(self.cat, self.stack, self.env)
        current = self.cat.defaults | {
            k: envfile.unquote(v) for k, v in self.env.items()
        }
        self.app.push_screen(ReviewScreen(issues, changes, current), self.saved)

    async def saved(self, ok: bool | None) -> None:
        if ok:
            # Start over from what ethd wrote, which can include values it generated
            self.env = envfile.load(self.env_file)
            self.stack = catalog.from_env(self.cat, self.env)
            self.refresh_status()
            await self.build_detail()

    def action_quit_config(self) -> None:
        if catalog.changes(self.cat, self.stack, self.env) and not self.quit_armed:
            self.quit_armed = True
            self.notify(
                "There are unsaved changes. Press q again to quit without saving."
            )
            return
        self.app.exit()


class MenuScreen(Screen[None]):
    """The "./ethd tui" start screen. Administrative functions will join the config screen here."""

    BINDINGS: ClassVar = [Binding("q", "app.quit", "Quit")]

    def compose(self) -> ComposeResult:
        yield Header()
        yield OptionList("Configure stack", id="menu")
        yield Footer()

    def on_mount(self) -> None:
        self.title = "Eth Docker"

    @on(OptionList.OptionSelected)
    def selected(self) -> None:
        app = self.app
        assert isinstance(app, EthdApp)
        app.push_screen(app.config_screen())


class EthdApp(App[None]):
    CSS_PATH = "app.tcss"
    HORIZONTAL_BREAKPOINTS = [(0, "-narrow"), (80, "-wide")]  # noqa: RUF012  # typed by App

    def __init__(self, args: argparse.Namespace) -> None:
        super().__init__()
        self.args = args
        self.ethd = shlex.split(args.ethd)

    def config_screen(self) -> ConfigScreen:
        return ConfigScreen(
            Path(self.args.env_file), Path(self.args.default_env), platform.machine()
        )

    def on_mount(self) -> None:
        self.push_screen(
            self.config_screen() if self.args.screen == "config" else MenuScreen()
        )


def main() -> None:
    parser = argparse.ArgumentParser(prog="ethd-tui")
    parser.add_argument("--screen", choices=["menu", "config"], default="menu")
    parser.add_argument("--env-file", default=".env")
    parser.add_argument("--default-env", default="default.env")
    parser.add_argument(
        "--ethd",
        default="./ethd",
        help="command that applies changes, run with apply-config FILE",
    )
    parser.add_argument(
        "--web",
        action="store_true",
        help="serve in a browser on localhost, reach it via an SSH tunnel",
    )
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()
    if args.web:
        from .web import LocalServer

        command = [
            sys.argv[0],
            "--screen",
            args.screen,
            "--env-file",
            args.env_file,
            "--default-env",
            args.default_env,
            "--ethd",
            args.ethd,
        ]
        LocalServer(
            shlex.join(command), host="127.0.0.1", port=args.port, title="Eth Docker"
        ).serve()
        return
    EthdApp(args).run()
