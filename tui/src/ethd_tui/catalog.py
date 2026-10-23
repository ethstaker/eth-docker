"""The stack model: catalog.toml loaded, a Stack read from and turned back into .env values."""

import re
import tomllib
from dataclasses import dataclass, field
from importlib.resources import files as package_files
from typing import Any

from . import envfile

# Same test as ethd's __check_double_vc, plus grandine.yml
_VC_FILE = re.compile(
    r"^(prysm|lighthouse|teku|nimbus|lodestar|grandine)\.yml$|-allin1\.yml$|-vc-only\.yml$"
)


@dataclass
class Component:
    """A client choice or an add-on."""

    id: str
    label: str
    files: list[str] = field(default_factory=list)
    vars: list[str] = field(default_factory=list)
    image: list[str] = field(default_factory=list)
    ports: list[str] = field(default_factory=list)
    requires: dict[str, list[str]] = field(default_factory=dict)
    forces: dict[str, str] = field(default_factory=dict)
    hide: list[str] = field(default_factory=list)
    provides: list[str] = field(default_factory=list)
    arch: list[str] = field(default_factory=list)
    networks: list[str] = field(default_factory=list)
    not_networks: list[str] = field(default_factory=list)
    note: str = ""


@dataclass
class Exposure:
    id: str
    label: str
    shared: str = ""
    traefik: str = ""
    vars: list[str] = field(default_factory=list)
    traefik_vars: list[str] = field(default_factory=list)
    only: list[str] = field(default_factory=list)
    skip: list[str] = field(default_factory=list)
    addon: str = ""


@dataclass
class Role:
    id: str
    label: str
    choices: list[Component] = field(default_factory=list)
    addons: list[Component] = field(default_factory=list)
    exposures: list[Exposure] = field(default_factory=list)
    essentials: list[str] = field(default_factory=list)
    advanced: list[str] = field(default_factory=list)
    none_vars: list[str] = field(default_factory=list)
    none_forces: dict[str, str] = field(default_factory=dict)
    ports: list[str] = field(default_factory=list)

    def choice(self, choice_id: str | None) -> Component | None:
        return next((c for c in self.choices if c.id == choice_id), None)


@dataclass
class Catalog:
    roles: list[Role]
    combined: list[dict[str, str]]
    legacy: list[str]
    derived: list[str]
    internal: list[str]
    enums: dict[str, list[str]]
    labels: dict[str, str]
    defaults: dict[str, str] = field(default_factory=dict)
    raw_defaults: dict[str, str] = field(default_factory=dict)
    help: dict[str, str] = field(default_factory=dict)

    def role(self, role_id: str) -> Role:
        return next(r for r in self.roles if r.id == role_id)

    def image_vars(self, component: Component) -> list[str]:
        return [
            name
            for prefix in component.image
            for name in self.defaults
            if re.fullmatch(rf"{prefix}_(DOCKERFILE|DOCKER_\w+|SRC_\w+|TAG|REPO)", name)
        ]

    def label(self, name: str) -> str:
        return self.labels.get(name, name)


def load(default_env: str) -> Catalog:
    data: dict[str, Any] = tomllib.loads(
        package_files(__package__).joinpath("catalog.toml").read_text()
    )
    roles = [
        Role(
            **{k: v for k, v in r.items() if k not in ("choice", "addon", "exposure")},
            choices=[Component(**c) for c in r.get("choice", [])],
            addons=[Component(**a) for a in r.get("addon", [])],
            exposures=[Exposure(**e) for e in r.get("exposure", [])],
        )
        for r in data["role"]
    ]
    return Catalog(
        roles=roles,
        combined=data["combined"],
        legacy=data["legacy"],
        derived=data["derived"],
        internal=data["internal"],
        enums=data["enums"],
        labels=data["labels"],
        defaults={k: envfile.unquote(v) for k, v in envfile.parse(default_env).items()},
        raw_defaults=envfile.parse(default_env),
        help=envfile.parse_help(default_env),
    )


def unavailable(component: Component, network: str, arch: str) -> str:
    """Why a component cannot run here, or "" when it can."""
    arch = {"arm64": "aarch64"}.get(arch, arch)
    if component.arch and arch not in component.arch:
        return f"not on {arch}"
    if (
        component.networks and network not in component.networks
    ) or network in component.not_networks:
        return f"not on {network}"
    return ""


@dataclass
class Stack:
    choice: dict[str, str | None]
    addons: set[str]
    exposure: dict[str, set[str]]  # exposure id: "shared" and/or "traefik"
    values: dict[str, str]  # unquoted
    unmanaged: list[str]  # CORE_FILES the catalog does not know, such as legacy allin1


def _split(files: str) -> list[str]:
    return [f for f in files.split(":") if f]


def from_env(cat: Catalog, env: dict[str, str]) -> Stack:
    """env holds the raw .env values. Known files in CUSTOM_FILES move to CORE_FILES on save."""
    values = cat.defaults | {k: envfile.unquote(v) for k, v in env.items()}
    stack = Stack({r.id: None for r in cat.roles}, set(), {}, values, [])
    stack.unmanaged = [
        f for f in _split(values.get("CORE_FILES", "")) if not _claim(cat, stack, f)
    ]
    values["CUSTOM_FILES"] = ":".join(
        f for f in _split(values.get("CUSTOM_FILES", "")) if not _claim(cat, stack, f)
    )
    # A choice without files, such as an external Web3signer, is recognized by what it forces
    for role in cat.roles:
        if stack.choice[role.id] is None:
            stack.choice[role.id] = next(
                (
                    c.id
                    for c in role.choices
                    if not c.files
                    and c.forces
                    and all(values.get(k) == v for k, v in c.forces.items())
                ),
                None,
            )
    return stack


def _claim(cat: Catalog, stack: Stack, f: str) -> bool:
    if f in cat.derived:
        return True
    for combo in cat.combined:
        if combo["file"] == f:
            stack.choice["cl"], stack.choice["vc"] = combo["cl"], combo["vc"]
            return True
    for role in cat.roles:
        for c in role.choices:
            if f in c.files:
                stack.choice[role.id] = c.id
                return True
        for a in role.addons:
            if f in a.files:
                stack.addons.add(a.id)
                return True
        for e in role.exposures:
            for kind in ("shared", "traefik"):
                if getattr(e, kind) == f:
                    stack.exposure.setdefault(e.id, set()).add(kind)
                    return True
    return False


def exposure_visible(stack: Stack, role: Role, e: Exposure) -> bool:
    if e.addon:
        return any(
            a.id == e.addon and a.id in stack.addons and addon_visible(stack, a)
            for a in role.addons
        )
    choice = stack.choice[role.id]
    return (
        choice is not None and (not e.only or choice in e.only) and choice not in e.skip
    )


def addon_visible(stack: Stack, a: Component) -> bool:
    """An add-on is offered, and saved, only while its requirements are met."""
    return all(
        (have := stack.choice.get(r)) is not None and ("*" in ids or have in ids)
        for r, ids in a.requires.items()
    )


def to_files(cat: Catalog, stack: Stack) -> list[str]:
    """CORE_FILES for this stack, in role order."""
    out: list[str] = []
    cl, vc = stack.choice.get("cl"), stack.choice.get("vc")
    combined = next(
        (c["file"] for c in cat.combined if c["cl"] == cl and c["vc"] == vc), None
    )
    for role in cat.roles:
        if role.id == "cl" and combined:
            out.append(combined)
        elif not (role.id == "vc" and combined) and (
            c := role.choice(stack.choice[role.id])
        ):
            out += c.files
        out += [
            f
            for a in role.addons
            if a.id in stack.addons and addon_visible(stack, a)
            for f in a.files
        ]
    for role in cat.roles:
        for e in role.exposures:
            if exposure_visible(stack, role, e):
                kinds = stack.exposure.get(e.id, set())
                out += [
                    getattr(e, k)
                    for k in ("shared", "traefik")
                    if k in kinds and getattr(e, k)
                ]
    if (
        stack.choice.get("monitoring") in ("grafana", "grafana-rootless")
        and vc
        and not cl
    ):
        out.append("grafana-for-vc.yml")
    out += stack.unmanaged
    return list(dict.fromkeys(out))


def visible_vars(
    cat: Catalog, stack: Stack, role: Role
) -> tuple[list[str], list[str], list[str]]:
    """Essentials, advanced and image variables shown for a role right now."""
    choice = role.choice(stack.choice[role.id])
    hide = set(choice.hide) if choice else set()
    if choice:
        essentials = [v for v in role.essentials if v not in hide] + choice.vars
    else:
        essentials = list(role.none_vars if role.choices else role.essentials)
    advanced = (
        [v for v in role.advanced if v not in hide]
        if choice or not role.choices
        else []
    )
    for a in role.addons:
        if a.id in stack.addons:
            essentials += a.vars
    for e in role.exposures:
        if exposure_visible(stack, role, e):
            advanced += e.vars
            if "traefik" in stack.exposure.get(e.id, set()):
                advanced += e.traefik_vars
    image = cat.image_vars(choice) if choice else []
    image += [v for a in role.addons if a.id in stack.addons for v in cat.image_vars(a)]
    essentials = list(dict.fromkeys(essentials))
    advanced = [v for v in dict.fromkeys(advanced) if v not in essentials]
    return essentials, advanced, image


@dataclass
class Issue:
    error: bool  # errors block saving
    role: str
    text: str


def validate(cat: Catalog, stack: Stack, arch: str) -> list[Issue]:
    issues: list[Issue] = []
    network = stack.values.get("NETWORK", "")
    provided = {
        p for r in cat.roles if (c := r.choice(stack.choice[r.id])) for p in c.provides
    }
    active: list[tuple[Role, Component]] = []
    for role in cat.roles:
        if c := role.choice(stack.choice[role.id]):
            active.append((role, c))
        active += [
            (role, a)
            for a in role.addons
            if a.id in stack.addons and addon_visible(stack, a)
        ]

    for role, comp in active:
        for need, ids in comp.requires.items():
            have = stack.choice.get(need)
            if have is None or ("*" not in ids and have not in ids):
                need_role = cat.role(need)
                names = (
                    ", ".join(c.label for c in need_role.choices if c.id in ids)
                    or "any"
                )
                issues.append(
                    Issue(
                        True,
                        role.id,
                        f"{comp.label} requires {need_role.label}: {names}",
                    )
                )
        if reason := unavailable(comp, network, arch):
            issues.append(Issue(False, role.id, f"{comp.label} is {reason}"))
    for role_id in provided:
        if stack.choice.get(role_id):
            issues.append(
                Issue(
                    True,
                    role_id,
                    f"{cat.role(role_id).label} is already provided by the consensus client",
                )
            )

    vcs = [
        f
        for f in stack.unmanaged + _split(stack.values.get("CUSTOM_FILES", ""))
        if _VC_FILE.search(f)
    ] + ([stack.choice["vc"]] if stack.choice.get("vc") else [])
    if len(vcs) > 1:
        issues.append(
            Issue(
                True,
                "vc",
                f"Two validator clients would load the same keys: {', '.join(str(v) for v in vcs)}",
            )
        )
    for f in stack.unmanaged:
        if f in cat.legacy:
            issues.append(
                Issue(
                    False,
                    "stack",
                    f"{f} is legacy. Moving off it means moving keys, see the docs",
                )
            )

    if not stack.choice.get("traefik"):
        for role in cat.roles:
            for e in role.exposures:
                if exposure_visible(stack, role, e) and "traefik" in stack.exposure.get(
                    e.id, set()
                ):
                    issues.append(
                        Issue(
                            False,
                            role.id,
                            f"{e.label} is routed via traefik, but there is no web proxy",
                        )
                    )

    for role in cat.roles:
        for name in dict.fromkeys(
            n for group in visible_vars(cat, stack, role) for n in group
        ):
            value = stack.values.get(name, "")
            if (
                name.endswith("_PORT")
                and value
                and not (value.isdigit() and 1 <= int(value) <= 65535)
            ):
                issues.append(
                    Issue(True, role.id, f"{name} must be a port from 1 to 65535")
                )

    seen: dict[str, str] = {}
    for name in _host_ports(cat, stack):
        port = stack.values.get(name, "")
        if port and port in seen and seen[port] != name:
            issues.append(
                Issue(
                    True,
                    "stack",
                    f"Port {port} is used by both {seen[port]} and {name}",
                )
            )
        seen.setdefault(port, name)
    return issues


def _host_ports(cat: Catalog, stack: Stack) -> list[str]:
    """Variables of the ports published on the host."""
    names: list[str] = []
    for role in cat.roles:
        if choice := role.choice(stack.choice[role.id]):
            names += [p for p in role.ports if p not in choice.hide] + choice.ports
        names += [
            p
            for a in role.addons
            if a.id in stack.addons and addon_visible(stack, a)
            for p in a.ports
        ]
        for e in role.exposures:
            if exposure_visible(stack, role, e) and "shared" in stack.exposure.get(
                e.id, set()
            ):
                names += e.vars
    return list(dict.fromkeys(names))


def changes(cat: Catalog, stack: Stack, env: dict[str, str]) -> dict[str, str]:
    """The .env assignments to make, as raw (quoted where needed) values."""
    values = dict(stack.values)
    for role in cat.roles:
        c = role.choice(stack.choice[role.id])
        values |= c.forces if c else role.none_forces
    files = to_files(cat, stack)
    # The same files in another order is no change; overrides already follow their base files
    if set(files) != set(_split(envfile.unquote(env.get("CORE_FILES", "")))):
        values["CORE_FILES"] = ":".join(files)
    current = cat.defaults | {k: envfile.unquote(v) for k, v in env.items()}
    raw_like = cat.raw_defaults | env
    out: dict[str, str] = {}
    for name, value in values.items():
        if value != current.get(name):
            out[name] = envfile.quote(value, raw_like.get(name, ""))
    return out
