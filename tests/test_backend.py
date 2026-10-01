"""Regression tests for bin/extra-themes. Run: python3 -m unittest discover tests

Every test runs the backend as a subprocess against a throwaway HOME with fake
`omarchy`, `omarchy-shell` and (optionally) `hyprctl` commands, so nothing here
touches the real session.
"""
import concurrent.futures as cf
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

BACKEND = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "extra-themes")
ID = "io.github.simakwm.extra-themes"


class Sandbox(unittest.TestCase):
    hyprctl = True          # install a fake hyprctl

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = os.path.join(self.tmp.name, "home")
        self.shims = os.path.join(self.tmp.name, "shims")
        self.omarchy = os.path.join(self.tmp.name, "omarchy")
        for d in (self.home, self.shims, f"{self.omarchy}/config/omarchy", f"{self.home}/.config/omarchy",
                  f"{self.home}/.config/hypr"):
            os.makedirs(d, exist_ok=True)
        self.write(f"{self.omarchy}/config/omarchy/shell.json",
                   json.dumps({"version": 1, "bar": {"layout": {"left": [{"id": "omarchy.workspaces"}], "center": [], "right": []}}}))
        self.shim("omarchy-shell", "exit 0")
        self.shim("omarchy", "exit 0")
        if self.hyprctl:
            self.flag = os.path.join(self.tmp.name, "reloaded")
            # Only shell builtins: the shims directory is the whole PATH.
            self.shim("hyprctl", f'''case "$1" in
  binds) echo "[]" ;;
  reload) : > "{self.flag}" ;;
  configerrors) if [ -f "{self.flag}" ] && [ -f "{self.tmp.name}/hypr_error" ]; then read -r line < "{self.tmp.name}/hypr_error"; echo "$line"; fi ;;
esac''')
        self.shell_json = f"{self.home}/.config/omarchy/shell.json"
        self.menu = f"{self.home}/.config/omarchy/extensions/omarchy-menu.jsonc"
        self.bindings = f"{self.home}/.config/hypr/bindings.lua"

    def shim(self, name, body):
        path = os.path.join(self.shims, name)
        self.write(path, f"#!/bin/sh\n{body}\n")
        os.chmod(path, 0o755)

    def write(self, path, text):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(text)

    def read(self, path):
        with open(path) as f:
            return f.read()

    def env(self):
        return {"HOME": self.home, "PATH": self.shims, "OMARCHY_PATH": self.omarchy}

    def run_cli(self, *args):
        p = subprocess.run([sys.executable, BACKEND, *args], capture_output=True, text=True, env=self.env())
        return json.loads(p.stdout)


class ShellJson(Sandbox):
    def test_invalid_file_is_left_alone(self):
        original = '{\n  // my comment\n  "version": 1, "idle": {"lock": 600}\n}\n'
        self.write(self.shell_json, original)
        res = self.run_cli("bar", "left")
        self.assertFalse(res["ok"])
        self.assertIn("untouched", res["error"])
        self.assertEqual(self.read(self.shell_json), original)

    def test_cleanup_reports_but_does_not_clobber_invalid_file(self):
        original = "{ not json"
        self.write(self.shell_json, original)
        res = self.run_cli("cleanup")
        self.assertFalse(res["ok"])
        self.assertEqual(self.read(self.shell_json), original)

    def test_other_settings_survive(self):
        self.write(self.shell_json, json.dumps({"version": 1, "idle": {"lock": 600}, "bar": {"id": "x", "layout": {"left": [], "center": [], "right": []}}}))
        self.assertTrue(self.run_cli("bar", "right")["ok"])
        cfg = json.loads(self.read(self.shell_json))
        self.assertEqual(cfg["idle"], {"lock": 600})
        self.assertEqual(cfg["bar"]["id"], "x")
        self.assertEqual([e["id"] for e in cfg["bar"]["layout"]["right"]], [ID])

    def test_non_ascii_characters_are_not_escaped(self):
        self.write(self.shell_json, '{"version": 1, "bar": {"layout": {"left": [], "center": [{"id": "c", "verticalFormat": "HH\\n\u2014\\nmm"}], "right": []}}}')
        self.assertTrue(self.run_cli("bar", "right")["ok"])
        raw = self.read(self.shell_json)
        self.assertIn("\u2014", raw)
        self.assertNotIn("\\u2014", raw)

    def test_missing_file_starts_from_the_defaults(self):
        self.assertTrue(self.run_cli("bar", "right")["ok"])
        cfg = json.loads(self.read(self.shell_json))
        self.assertEqual([e["id"] for e in cfg["bar"]["layout"]["left"]], ["omarchy.workspaces"])
        self.assertEqual([e["id"] for e in cfg["bar"]["layout"]["right"]], [ID])

    def test_non_list_sections_are_repaired(self):
        self.write(self.shell_json, json.dumps({"bar": {"layout": {"left": None, "right": "x"}}, "plugins": None}))
        self.assertTrue(self.run_cli("bar", "center")["ok"])
        cfg = json.loads(self.read(self.shell_json))
        self.assertEqual(cfg["bar"]["layout"]["left"], [])
        self.assertEqual([e["id"] for e in cfg["bar"]["layout"]["center"]], [ID])
        self.assertEqual([e["id"] for e in cfg["plugins"]], [ID])

    def test_placement_round_trip(self):
        for section in ("left", "right", "center"):
            self.assertTrue(self.run_cli("bar", section)["ok"])
            self.assertEqual(self.run_cli("settings")["bar"]["section"], section)
        self.assertTrue(self.run_cli("bar", "hidden")["ok"])
        self.assertEqual(self.run_cli("settings")["bar"]["section"], "hidden")
        self.assertIn(ID, [e["id"] for e in json.loads(self.read(self.shell_json))["plugins"]])


class Favorites(Sandbox):
    def test_concurrent_toggles_all_land(self):
        slugs = [f"theme-{i}" for i in range(20)]
        with cf.ThreadPoolExecutor(10) as ex:
            list(ex.map(lambda s: self.run_cli("favorite", s), slugs))
        state = f"{self.home}/.local/state/omarchy-extra-themes"
        state = f"{self.home}/.local/state/extra-themes-browser"
        self.assertEqual(sorted(json.loads(self.read(f"{state}/favorites.json"))), sorted(slugs))

    def test_toggle_twice_removes(self):
        self.assertTrue(self.run_cli("favorite", "ash")["favorite"])
        self.assertFalse(self.run_cli("favorite", "ash")["favorite"])


class MenuEntry(Sandbox):
    def test_remove_without_block_does_not_create_or_touch_the_file(self):
        self.assertTrue(self.run_cli("menu", "off")["ok"])
        self.assertFalse(os.path.exists(self.menu))
        original = '{\n  "a.b": {"label":"x","action":"true"}, // inline\n}\n'
        self.write(self.menu, original)
        self.assertTrue(self.run_cli("menu", "off")["ok"])
        self.assertEqual(self.read(self.menu), original)

    def test_on_then_off_restores_the_file(self):
        original = '{\n  "a.b": {"label":"x","action":"true"}\n}\n'
        self.write(self.menu, original)
        self.assertTrue(self.run_cli("menu", "on")["ok"])
        self.assertTrue(self.run_cli("settings")["menu"])
        self.assertTrue(self.run_cli("menu", "on")["ok"])
        self.assertEqual(self.read(self.menu).count("[extra-themes-browser-menu]"), 1)
        self.assertTrue(self.run_cli("menu", "off")["ok"])
        self.assertEqual(self.read(self.menu).replace('},\n}', '}\n}'), original.replace('"true"}\n}', '"true"}\n}'))

    def test_inline_comment_gets_a_clear_error(self):
        original = '{\n  "a.b": {"label":"x","action":"true"} // note\n}\n'
        self.write(self.menu, original)
        res = self.run_cli("menu", "on")
        self.assertFalse(res["ok"])
        self.assertIn("inline", res["error"])
        self.assertEqual(self.read(self.menu), original)

    def test_removal_works_even_if_the_file_has_inline_comments(self):
        self.write(self.menu, '{\n  "a": {"label":"x","action":"y"}, // keep\n}\n')
        self.assertTrue(self.run_cli("menu", "on")["ok"] is False)
        self.write(self.menu, '{\n  "a": {"label":"x","action":"y"}, // keep\n  // [extra-themes-browser-menu]\n  "b": {},\n  // [/extra-themes-browser-menu]\n}\n')
        self.assertTrue(self.run_cli("menu", "off")["ok"])
        self.assertNotIn("extra-themes-browser-menu", self.read(self.menu))
        self.assertIn("// keep", self.read(self.menu))


class Shortcut(Sandbox):
    def test_set_and_clear(self):
        self.write(self.bindings, '-- mine\no.bind("SUPER + K", "x", "y")\n')
        self.assertTrue(self.run_cli("shortcut-set", "super ctrl t")["ok"])
        self.assertEqual(self.run_cli("settings")["shortcut"], "SUPER + CTRL + T")
        self.assertTrue(self.run_cli("shortcut-clear")["ok"])
        self.assertEqual(self.read(self.bindings), '-- mine\no.bind("SUPER + K", "x", "y")\n')

    def test_clear_without_shortcut_is_a_no_op(self):
        original = "-- mine\n\n\n"
        self.write(self.bindings, original)
        self.assertTrue(self.run_cli("shortcut-clear")["ok"])
        self.assertEqual(self.read(self.bindings), original)

    def test_hyprland_errors_roll_the_file_back(self):
        original = '-- mine\n'
        self.write(self.bindings, original)
        self.write(os.path.join(self.tmp.name, "hypr_error"), "line 3: bad bind")
        res = self.run_cli("shortcut-set", "SUPER + ALT + T")
        self.assertFalse(res["ok"])
        self.assertIn("rejected", res["error"])
        self.assertEqual(self.read(self.bindings), original)

    def test_rejects_unsafe_input(self):
        self.write(self.bindings, "-- mine\n")
        for bad in ('SUPER + CTRL + T"); os.execute("x', "T", "SUPER + F25", "SUPER + ;"):
            self.assertFalse(self.run_cli("shortcut-set", bad)["ok"], bad)
        self.assertEqual(self.read(self.bindings), "-- mine\n")


class NoHyprctl(Sandbox):
    hyprctl = False

    def test_missing_hyprctl_is_a_clean_error_and_leaves_bindings_alone(self):
        original = "-- mine\n"
        self.write(self.bindings, original)
        res = self.run_cli("shortcut-set", "SUPER + ALT + T")
        self.assertFalse(res["ok"])
        self.assertIn("hyprctl", res["error"])
        self.assertEqual(self.read(self.bindings), original)


class ActiveTheme(Sandbox):
    def test_reads_the_folder_name_from_omarchy_state(self):
        self.write(f"{self.home}/.local/state/omarchy/current/theme.name", "all-hallows-eve\n")
        os.environ["HOME"], saved = self.home, os.environ.get("HOME")
        try:
            for var in ("XDG_CACHE_HOME", "XDG_STATE_HOME"):
                os.environ.pop(var, None)
            loader = importlib.machinery.SourceFileLoader("backend_under_test", BACKEND)
            spec = importlib.util.spec_from_loader("backend_under_test", loader)
            mod = importlib.util.module_from_spec(spec)
            loader.exec_module(mod)
            self.assertEqual(mod.active_slug(), "all-hallows-eve")
            os.remove(f"{self.home}/.local/state/omarchy/current/theme.name")
            self.assertEqual(mod.active_slug(), "")
        finally:
            os.environ["HOME"] = saved


if __name__ == "__main__":
    unittest.main()
