"""Keeps catalog.toml in step with the compose files and default.env, and checks the stack model."""

import re
import unittest
from pathlib import Path

from ethd_tui import catalog, envfile

REPO = Path(__file__).resolve().parents[2]
# shortcut: yml files from a pending PR, remove once grandine.yml and grandine-vc-only.yml are on main
PENDING = {"grandine.yml", "grandine-vc-only.yml"}


def _cat() -> catalog.Catalog:
    return catalog.load((REPO / "default.env").read_text())


def _referenced(cat: catalog.Catalog) -> tuple[set[str], set[str]]:
    """Variables and yml files the catalog knows about."""
    names = set(cat.internal)
    files = set(cat.legacy) | set(cat.derived) | {c["file"] for c in cat.combined}
    for role in cat.roles:
        names |= {
            *role.essentials,
            *role.advanced,
            *role.none_vars,
            *role.ports,
            *role.none_forces,
        }
        for comp in role.choices + role.addons:
            names |= {*comp.vars, *comp.ports, *comp.forces, *cat.image_vars(comp)}
            files |= set(comp.files)
        for e in role.exposures:
            names |= {*e.vars, *e.traefik_vars}
            files |= {f for f in (e.shared, e.traefik) if f}
    return names, files


class CatalogCoverage(unittest.TestCase):
    def test_every_yml_variable_is_in_the_catalog(self) -> None:
        names, _ = _referenced(_cat())
        for yml in sorted(REPO.glob("*.yml")):
            used = set(re.findall(r"\$\{([A-Z0-9_]+)", yml.read_text()))
            with self.subTest(yml=yml.name):
                self.assertEqual(
                    used - names, set(), "add these to catalog.toml, or to internal"
                )

    def test_every_yml_file_is_in_the_catalog(self) -> None:
        _, files = _referenced(_cat())
        self.assertEqual({p.name for p in REPO.glob("*.yml")} - files, set())

    def test_catalog_files_exist(self) -> None:
        _, files = _referenced(_cat())
        self.assertEqual({f for f in files if not (REPO / f).exists()} - PENDING, set())

    def test_catalog_variables_exist(self) -> None:
        cat = _cat()
        names, _ = _referenced(cat)
        used = {
            v
            for yml in REPO.glob("*.yml")
            for v in re.findall(r"\$\{([A-Z0-9_]+)", yml.read_text())
        }
        self.assertEqual(
            names - used - set(cat.defaults), set(), "typo in catalog.toml?"
        )

    def test_legacy_files_are_never_offered(self) -> None:
        cat = _cat()
        offered = {f for r in cat.roles for c in r.choices + r.addons for f in c.files}
        self.assertEqual(offered & set(cat.legacy), set())


class StackModel(unittest.TestCase):
    def roundtrip(
        self, core: str, env: dict[str, str] | None = None
    ) -> tuple[list[str], catalog.Stack]:
        cat = _cat()
        stack = catalog.from_env(cat, {"CORE_FILES": core} | (env or {}))
        return catalog.to_files(cat, stack), stack

    def test_combined_and_split_clients(self) -> None:
        files, stack = self.roundtrip("teku.yml:besu.yml")
        self.assertEqual(files, ["besu.yml", "teku.yml"])
        files, stack = self.roundtrip(
            "lighthouse-cl-only.yml:teku-vc-only.yml:reth.yml"
        )
        self.assertEqual(
            (stack.choice["cl"], stack.choice["vc"]), ("lighthouse", "teku")
        )
        self.assertEqual(
            files, ["reth.yml", "lighthouse-cl-only.yml", "teku-vc-only.yml"]
        )

    def test_choosing_the_same_client_combines(self) -> None:
        cat = _cat()
        stack = catalog.from_env(
            cat, {"CORE_FILES": "lighthouse-cl-only.yml:teku-vc-only.yml"}
        )
        stack.choice["vc"] = "lighthouse"
        self.assertEqual(catalog.to_files(cat, stack), ["lighthouse.yml"])

    def test_external_choice_is_found_by_what_it_forces(self) -> None:
        _, stack = self.roundtrip("teku.yml", {"WEB3SIGNER": "true"})
        self.assertEqual(stack.choice["w3s"], "external")
        _, stack = self.roundtrip("teku.yml:web3signer.yml", {"WEB3SIGNER": "true"})
        self.assertEqual(stack.choice["w3s"], "local")

    def test_known_custom_files_move_to_core(self) -> None:
        files, stack = self.roundtrip(
            "teku.yml:besu.yml", {"CUSTOM_FILES": "el-shared.yml:my.yml"}
        )
        self.assertEqual(stack.values["CUSTOM_FILES"], "my.yml")
        self.assertIn("el-shared.yml", files)

    def test_addon_without_its_requirement_is_dropped(self) -> None:
        files, _ = self.roundtrip(
            "teku.yml:besu.yml:siren.yml"
        )  # Siren is Lighthouse's
        self.assertNotIn("siren.yml", files)
        files, _ = self.roundtrip("lighthouse.yml:besu.yml:siren.yml")
        self.assertIn("siren.yml", files)

    def test_exposure_of_a_dropped_addon_is_dropped(self) -> None:
        files, _ = self.roundtrip("teku.yml:besu.yml:siren.yml:siren-shared.yml")
        self.assertNotIn("siren-shared.yml", files)

    def test_exposure_of_an_absent_service_is_dropped(self) -> None:
        cat = _cat()
        stack = catalog.from_env(cat, {"CORE_FILES": "teku.yml:besu.yml:el-shared.yml"})
        stack.choice["el"] = None
        self.assertNotIn("el-shared.yml", catalog.to_files(cat, stack))

    def test_validation(self) -> None:
        cat = _cat()

        def errors(core: str, env: dict[str, str] | None = None) -> list[str]:
            stack = catalog.from_env(cat, {"CORE_FILES": core} | (env or {}))
            return [i.text for i in catalog.validate(cat, stack, "x86_64") if i.error]

        self.assertEqual(errors("teku.yml:besu.yml"), [])
        self.assertTrue(errors("teku-allin1.yml:lighthouse-vc-only.yml"))  # two VCs
        self.assertTrue(errors("caplin.yml:geth.yml"))  # Caplin is Erigon's
        self.assertTrue(errors("ethlambda-cl-only.yml:geth.yml"))  # needs a VC
        self.assertTrue(
            errors("nimbus-unified.yml:geth.yml")
        )  # unified brings its own EL
        self.assertTrue(
            errors("teku.yml:besu.yml", {"EL_P2P_PORT": "9000"})
        )  # port clash
        self.assertTrue(errors("teku.yml:besu.yml", {"EL_P2P_PORT": "70000"}))
        self.assertEqual(errors("teku.yml:besu.yml", {"MAX_BLOBS": "70000"}), [])

    def test_changes_only_holds_what_changed(self) -> None:
        cat = _cat()
        env = {"CORE_FILES": "teku.yml:besu.yml", "MEV_BOOST": "false"}
        stack = catalog.from_env(cat, env)
        self.assertEqual(catalog.changes(cat, stack, env), {})
        quoted = {"CORE_FILES": '"teku.yml:besu.yml"', "MEV_BOOST": "false"}
        self.assertEqual(
            catalog.changes(cat, catalog.from_env(cat, quoted), quoted), {}
        )
        stack.choice["mev"] = "mev-boost"
        stack.values["GRAFFITI"] = "hello world"
        got = catalog.changes(cat, stack, env)
        self.assertEqual(got["MEV_BOOST"], "true")
        self.assertEqual(got["GRAFFITI"], '"hello world"')
        self.assertIn("mev-boost.yml", got["CORE_FILES"])


class EnvFile(unittest.TestCase):
    def test_parse(self) -> None:
        text = 'A=1\n# B=2\nC="x\ny\n"\nD=\'q r\'  \nA=3\nE="one line"\n'
        self.assertEqual(
            envfile.parse(text),
            {"A": "1", "C": '"x\ny\n"', "D": "'q r'", "E": '"one line"'},
        )

    def test_multiline_default(self) -> None:
        raw = envfile.parse((REPO / "default.env").read_text())["MEV_RELAYS"]
        self.assertTrue(raw.startswith('"\nhttps://') and raw.endswith('"'))

    def test_quote(self) -> None:
        self.assertEqual(envfile.quote("abc", ""), "abc")
        self.assertEqual(envfile.quote("a b", ""), '"a b"')
        self.assertEqual(envfile.quote("$(git x)", "'$(y)'"), "'$(git x)'")
        self.assertEqual(envfile.quote('say "hi"', ""), "'say \"hi\"'")


if __name__ == "__main__":
    unittest.main()
