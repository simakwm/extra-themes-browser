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
import shutil
import subprocess
import sys
import tempfile
import time
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

    def test_concurrent_edits_keep_the_file_valid_and_the_entry_unique(self):
        self.write(self.shell_json, json.dumps({"version": 1, "idle": {"lock": 600}, "bar": {"layout": {"left": [], "center": [], "right": []}}}))
        sections = ["left", "center", "right", "hidden"] * 4
        with cf.ThreadPoolExecutor(8) as ex:
            list(ex.map(lambda s: self.run_cli("bar", s), sections))
        cfg = json.loads(self.read(self.shell_json))
        self.assertEqual(cfg["idle"], {"lock": 600})
        mentions = sum(1 for sec in cfg["bar"]["layout"].values() for e in sec if e.get("id") == ID)
        self.assertLessEqual(mentions, 1)
        self.assertEqual([e["id"] for e in cfg["plugins"]].count(ID), 1)

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


class UpdateNotifications(Sandbox):
    """check-updates against real local git repos, with a fake notification sender."""

    def setUp(self):
        super().setUp()
        os.symlink(shutil.which("git"), os.path.join(self.shims, "git"))
        self.log = os.path.join(self.tmp.name, "notifications.log")
        self.fail_flag = os.path.join(self.tmp.name, "sender_fails")
        self.shim("omarchy-notification-send",
                  f'[ -f "{self.fail_flag}" ] && exit 1\nfor a in "$@"; do printf "%s|" "$a" >> "{self.log}"; done\necho >> "{self.log}"')
        self.git_env = {"PATH": os.environ["PATH"], "HOME": self.tmp.name, "GIT_CONFIG_GLOBAL": "/dev/null",
                        "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}
        self.themes = f"{self.home}/.config/omarchy/themes"
        os.makedirs(self.themes)
        self.repos = {}

    def git(self, *args, cwd=None):
        subprocess.run(["git", *args], cwd=cwd, env=self.git_env, check=True, capture_output=True)

    def add_theme(self, slug):
        """An installed theme whose upstream we can advance with advance()."""
        seed = os.path.join(self.tmp.name, f"{slug}-seed")
        bare = os.path.join(self.tmp.name, f"{slug}.git")
        self.git("init", "-q", "-b", "main", seed)
        self.write(os.path.join(seed, "colors.toml"), "v1\n")
        self.git("add", "-A", cwd=seed)
        self.git("commit", "-q", "-m", "one", cwd=seed)
        self.git("clone", "-q", "--bare", seed, bare)
        self.git("clone", "-q", bare, os.path.join(self.themes, slug))
        self.repos[slug] = (seed, bare)

    def advance(self, slug, content):
        seed, bare = self.repos[slug]
        self.write(os.path.join(seed, "colors.toml"), content)
        self.git("commit", "-q", "-am", content.strip(), cwd=seed)
        self.git("push", "-q", bare, "main", cwd=seed)

    def notifications(self):
        return self.read(self.log).splitlines() if os.path.exists(self.log) else []

    def test_off_by_default_and_does_nothing(self):
        self.add_theme("foo")
        self.advance("foo", "v2\n")
        self.assertFalse(self.run_cli("settings")["notify"])
        self.assertEqual(self.run_cli("check-updates", "--force")["skipped"], "disabled")
        self.assertEqual(self.notifications(), [])

    def test_notifies_once_per_new_upstream_commit(self):
        self.add_theme("foo")
        self.assertTrue(self.run_cli("notify", "on")["ok"])
        self.assertTrue(self.run_cli("settings")["notify"])
        self.assertEqual(self.run_cli("check-updates", "--force")["notified"], [])      # nothing new yet
        self.advance("foo", "v2\n")
        self.assertEqual(self.run_cli("check-updates", "--force")["notified"], ["foo"])
        self.assertEqual(len(self.notifications()), 1)
        self.assertIn("Foo has an update", self.notifications()[0])
        self.assertIn("summon|" + ID, self.notifications()[0])               # click opens the popup
        self.assertEqual(self.run_cli("check-updates", "--force")["notified"], [])      # same commit: silent
        self.assertEqual(len(self.notifications()), 1)
        self.advance("foo", "v3\n")                                          # a newer commit notifies again
        self.assertEqual(self.run_cli("check-updates", "--force")["notified"], ["foo"])
        self.assertEqual(len(self.notifications()), 2)

    def test_updating_the_theme_resets_the_memory(self):
        self.add_theme("foo")
        self.run_cli("notify", "on")
        self.advance("foo", "v2\n")
        self.run_cli("check-updates", "--force")
        self.assertTrue(self.run_cli("update", "foo")["ok"])
        self.assertEqual(self.run_cli("check-updates", "--force")["outdated"], [])
        self.advance("foo", "v3\n")
        self.assertEqual(self.run_cli("check-updates", "--force")["notified"], ["foo"])

    def test_several_themes_make_one_notification(self):
        for slug in ("foo", "bar"):
            self.add_theme(slug)
            self.advance(slug, "v2\n")
        self.run_cli("notify", "on")
        self.assertEqual(self.run_cli("check-updates", "--force")["notified"], ["bar", "foo"])
        lines = self.notifications()
        self.assertEqual(len(lines), 1)
        self.assertIn("2 themes have updates", lines[0])

    def test_a_failed_send_is_retried_not_forgotten(self):
        self.add_theme("foo")
        self.advance("foo", "v2\n")
        self.run_cli("notify", "on")
        open(self.fail_flag, "w").close()
        self.assertFalse(self.run_cli("check-updates", "--force")["ok"])
        os.remove(self.fail_flag)
        self.assertEqual(self.run_cli("check-updates", "--force")["notified"], ["foo"])
        self.assertEqual(len(self.notifications()), 1)

    def test_turning_it_off_stops_notifications(self):
        self.add_theme("foo")
        self.run_cli("notify", "on")
        self.run_cli("notify", "off")
        self.advance("foo", "v2\n")
        self.assertEqual(self.run_cli("check-updates", "--force")["skipped"], "disabled")
        self.assertEqual(self.notifications(), [])

    def test_cleanup_forgets_the_preference(self):
        self.run_cli("notify", "on")
        self.assertTrue(self.run_cli("cleanup")["ok"])
        self.assertFalse(self.run_cli("settings")["notify"])

    # -- the once-a-day window --------------------------------------------------
    def last_check_file(self):
        return f"{self.home}/.local/state/extra-themes-browser/last-check.json"

    def test_checks_at_most_once_a_day(self):
        self.add_theme("foo")
        self.run_cli("notify", "on")
        first = self.run_cli("check-updates")
        self.assertNotIn("skipped", first)
        self.advance("foo", "v2\n")                                           # new update, but we just looked
        second = self.run_cli("check-updates")
        self.assertEqual(second["skipped"], "checked recently")
        self.assertEqual(self.notifications(), [])

    def test_checks_again_after_a_day(self):
        self.add_theme("foo")
        self.run_cli("notify", "on")
        self.run_cli("check-updates")
        self.advance("foo", "v2\n")
        self.write(self.last_check_file(), json.dumps({"at": __import__("time").time() - 25 * 3600}))
        self.assertEqual(self.run_cli("check-updates")["notified"], ["foo"])

    def test_turning_it_on_does_not_wait_out_an_old_check(self):
        self.add_theme("foo")
        self.run_cli("notify", "on")
        self.run_cli("check-updates")
        self.run_cli("notify", "off")
        self.run_cli("notify", "on")
        self.advance("foo", "v2\n")
        self.assertEqual(self.run_cli("check-updates")["notified"], ["foo"])

    def test_a_failed_send_does_not_start_the_day_window(self):
        self.add_theme("foo")
        self.advance("foo", "v2\n")
        self.run_cli("notify", "on")
        open(self.fail_flag, "w").close()
        self.assertFalse(self.run_cli("check-updates")["ok"])
        self.assertFalse(os.path.exists(self.last_check_file()))
        os.remove(self.fail_flag)
        self.assertEqual(self.run_cli("check-updates")["notified"], ["foo"])   # retried without --force

    def test_unreachable_upstream_neither_forgets_nor_uses_up_the_day(self):
        self.add_theme("foo")
        self.run_cli("notify", "on")
        self.advance("foo", "v2\n")
        self.assertEqual(self.run_cli("check-updates")["notified"], ["foo"])
        self.assertEqual(len(self.notifications()), 1)
        # Day passes, and the network is down: the fetch fails.
        self.write(self.last_check_file(), json.dumps({"at": __import__("time").time() - 25 * 3600}))
        seed, bare = self.repos["foo"]
        os.rename(bare, bare + ".offline")
        res = self.run_cli("check-updates")
        self.assertEqual(res["unreachable"], ["foo"])
        self.assertEqual(json.loads(self.read(self.last_check_file()))["at"] < __import__("time").time() - 24 * 3600, True)
        # Back online: the same commit must not be announced a second time.
        os.rename(bare + ".offline", bare)
        res = self.run_cli("check-updates")
        self.assertEqual(res["notified"], [])
        self.assertEqual(len(self.notifications()), 1)

    def test_a_corrupt_timestamp_is_ignored(self):
        self.add_theme("foo")
        self.run_cli("notify", "on")
        self.write(self.last_check_file(), "not json")
        self.assertNotIn("skipped", self.run_cli("check-updates"))


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



# ─────────────────────────────────────────────────────────────────────────────
# Pure-function tests — import the module directly; no subprocess overhead.
# ─────────────────────────────────────────────────────────────────────────────

def _load_backend():
    loader = importlib.machinery.SourceFileLoader("_be", BACKEND)
    spec = importlib.util.spec_from_loader("_be", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod

_BE = _load_backend()


class SlugOf(unittest.TestCase):
    """slug_of converts repo URLs to theme directory names (same rule as omarchy-theme-install)."""

    def s(self, url):
        return _BE.slug_of(url)

    def test_plain_repo(self):
        self.assertEqual(self.s("https://github.com/user/catppuccin"), "catppuccin")

    def test_strips_git_extension(self):
        self.assertEqual(self.s("https://github.com/user/foo.git"), "foo")

    def test_strips_omarchy_prefix(self):
        self.assertEqual(self.s("https://github.com/user/omarchy-nord"), "nord")

    def test_strips_theme_suffix(self):
        self.assertEqual(self.s("https://github.com/user/nord-theme"), "nord")

    def test_lowercases(self):
        self.assertEqual(self.s("https://github.com/user/CastleOnALake"), "castleonalake")

    def test_trailing_slash(self):
        self.assertEqual(self.s("https://github.com/user/foo/"), "foo")

    def test_both_prefix_and_suffix_stripped(self):
        self.assertEqual(self.s("https://github.com/user/omarchy-catppuccin-theme"), "catppuccin")


class ParseCombo(unittest.TestCase):
    """parse_combo validates and normalises shortcut combos."""

    def parse(self, s):
        return _BE.parse_combo(s)

    def test_basic(self):
        combo, _, key = self.parse("SUPER + CTRL + T")
        self.assertEqual(combo, "SUPER + CTRL + T")
        self.assertEqual(key, "T")

    def test_case_insensitive(self):
        combo, _, key = self.parse("super + ctrl + t")
        self.assertEqual(key, "T")
        self.assertIn("SUPER", combo)

    def test_windows_alias(self):
        combo, _, _ = self.parse("WIN + T")
        self.assertIn("SUPER", combo)

    def test_control_alias(self):
        combo, _, _ = self.parse("CONTROL + ALT + T")
        self.assertIn("CTRL", combo)

    def test_f_key_valid(self):
        _, _, key = self.parse("SUPER + F12")
        self.assertEqual(key, "F12")

    def test_f_key_out_of_range_rejected(self):
        with self.assertRaises(SystemExit):
            self.parse("SUPER + F25")

    def test_named_key_space(self):
        _, _, key = self.parse("SUPER + CTRL + SPACE")
        self.assertEqual(key, "SPACE")

    def test_named_key_return(self):
        _, _, key = self.parse("SUPER + ALT + RETURN")
        self.assertEqual(key, "RETURN")

    def test_mods_ordered_canonically_regardless_of_input(self):
        c1, _, _ = self.parse("ALT + SUPER + CTRL + T")
        c2, _, _ = self.parse("SUPER + CTRL + ALT + T")
        self.assertEqual(c1, c2)

    def test_shift_alone_as_modifier_rejected(self):
        with self.assertRaises(SystemExit):
            self.parse("SHIFT + T")

    def test_missing_key_rejected(self):
        with self.assertRaises(SystemExit):
            self.parse("SUPER + CTRL")

    def test_shell_injection_characters_rejected(self):
        with self.assertRaises(SystemExit):
            self.parse('SUPER + T"); os.execute("x')


# ─────────────────────────────────────────────────────────────────────────────
# catalog command
# ─────────────────────────────────────────────────────────────────────────────

class CatalogCommand(Sandbox):
    """catalog command with a pre-populated cache file (no network needed)."""

    CATALOG = [
        {"slug": "foo", "name": "Foo Theme", "repo": "https://github.com/alice/foo",
         "image": "https://omarchy.org/assets/themes/foo.png"},
        {"slug": "bar", "name": "Bar Theme", "repo": "https://github.com/bob/bar",
         "image": "https://omarchy.org/assets/themes/bar.png"},
    ]

    def seed(self):
        d = f"{self.home}/.cache/extra-themes-browser"
        os.makedirs(d)
        with open(f"{d}/catalog.json", "w") as f:
            json.dump(self.CATALOG, f)

    def test_returns_list_with_required_fields(self):
        self.seed()
        res = self.run_cli("catalog")
        self.assertIsInstance(res, list)
        self.assertEqual(len(res), 2)
        for t in res:
            for k in ("slug", "name", "repo", "image", "installed", "git", "active", "favorite", "author"):
                self.assertIn(k, t, f"field {k!r} missing from entry {t}")

    def test_installed_flag_set_for_existing_dir(self):
        self.seed()
        os.makedirs(f"{self.home}/.config/omarchy/themes/foo")
        res = {t["slug"]: t for t in self.run_cli("catalog")}
        self.assertTrue(res["foo"]["installed"])
        self.assertFalse(res["bar"]["installed"])

    def test_git_flag_requires_dot_git_subdir(self):
        self.seed()
        os.makedirs(f"{self.home}/.config/omarchy/themes/foo/.git")
        res = {t["slug"]: t for t in self.run_cli("catalog")}
        self.assertTrue(res["foo"]["git"])
        self.assertFalse(res["bar"]["git"])

    def test_symlink_dir_not_counted_as_git_theme(self):
        self.seed()
        real = f"{self.home}/.config/omarchy/themes/_target"
        os.makedirs(real)
        os.symlink(real, f"{self.home}/.config/omarchy/themes/foo")
        res = {t["slug"]: t for t in self.run_cli("catalog")}
        self.assertTrue(res["foo"]["installed"])
        self.assertFalse(res["foo"]["git"])

    def test_active_flag_matches_theme_name_file(self):
        self.seed()
        self.write(f"{self.home}/.local/state/omarchy/current/theme.name", "foo\n")
        res = {t["slug"]: t for t in self.run_cli("catalog")}
        self.assertTrue(res["foo"]["active"])
        self.assertFalse(res["bar"]["active"])

    def test_favorite_flag_reflects_toggle(self):
        self.seed()
        self.run_cli("favorite", "bar")
        res = {t["slug"]: t for t in self.run_cli("catalog")}
        self.assertFalse(res["foo"]["favorite"])
        self.assertTrue(res["bar"]["favorite"])

    def test_author_extracted_from_repo_url(self):
        self.seed()
        res = {t["slug"]: t for t in self.run_cli("catalog")}
        self.assertEqual(res["foo"]["author"], "alice")
        self.assertEqual(res["bar"]["author"], "bob")


# ─────────────────────────────────────────────────────────────────────────────
# install / uninstall / apply
# ─────────────────────────────────────────────────────────────────────────────

class InstallUninstall(Sandbox):

    REPO = "https://github.com/alice/my-theme"

    def seed_catalog(self):
        d = f"{self.home}/.cache/extra-themes-browser"
        os.makedirs(d)
        with open(f"{d}/catalog.json", "w") as f:
            json.dump([{"slug": "my-theme", "repo": self.REPO,
                        "name": "My Theme", "image": "x"}], f)

    def make_git_theme(self, slug):
        d = f"{self.home}/.config/omarchy/themes/{slug}"
        os.makedirs(f"{d}/.git")
        return d

    def test_install_known_url_ok(self):
        self.seed_catalog()
        self.assertTrue(self.run_cli("install", self.REPO)["ok"])

    def test_install_unknown_url_rejected(self):
        self.seed_catalog()
        self.assertFalse(self.run_cli("install", "https://github.com/evil/hacker")["ok"])

    def test_uninstall_non_git_dir_rejected(self):
        os.makedirs(f"{self.home}/.config/omarchy/themes/my-theme")
        res = self.run_cli("uninstall", "my-theme")
        self.assertFalse(res["ok"])
        self.assertTrue(os.path.isdir(f"{self.home}/.config/omarchy/themes/my-theme"))

    def test_uninstall_symlink_rejected(self):
        target = f"{self.home}/.config/omarchy/themes/_real"
        os.makedirs(target)
        os.symlink(target, f"{self.home}/.config/omarchy/themes/my-theme")
        self.assertFalse(self.run_cli("uninstall", "my-theme")["ok"])

    def test_uninstall_inactive_git_theme_ok_no_switch(self):
        self.make_git_theme("my-theme")
        self.write(f"{self.home}/.local/state/omarchy/current/theme.name", "other\n")
        res = self.run_cli("uninstall", "my-theme")
        self.assertTrue(res["ok"])
        self.assertNotIn("switched", res)

    def test_uninstall_active_theme_switches_to_default(self):
        self.make_git_theme("my-theme")
        self.write(f"{self.home}/.local/state/omarchy/current/theme.name", "my-theme\n")
        res = self.run_cli("uninstall", "my-theme")
        self.assertTrue(res["ok"])
        self.assertEqual(res.get("switched"), "Tokyo Night")

    def test_uninstall_bad_slug_rejected(self):
        self.assertFalse(self.run_cli("uninstall", "../evil")["ok"])


class Apply(Sandbox):

    def setUp(self):
        super().setUp()
        self.log = os.path.join(self.tmp.name, "omarchy.log")
        self.shim("omarchy", f'echo "$@" >> "{self.log}"\nexit 0')

    def test_apply_calls_omarchy_theme_set(self):
        res = self.run_cli("apply", "tokyo-night")
        self.assertTrue(res["ok"])
        self.assertIn("theme set tokyo-night", self.read(self.log))

    def test_apply_bad_slug_rejected(self):
        self.assertFalse(self.run_cli("apply", "../evil")["ok"])


# ─────────────────────────────────────────────────────────────────────────────
# bar-move
# ─────────────────────────────────────────────────────────────────────────────

class BarMove(Sandbox):

    def _layout(self, left=(), center=(), right=()):
        return json.dumps({"version": 1, "bar": {"layout": {
            "left":   [{"id": x} for x in left],
            "center": [{"id": x} for x in center],
            "right":  [{"id": x} for x in right],
        }}})

    def test_move_right_swaps_with_next_item(self):
        self.write(self.shell_json, self._layout(right=(ID, "other")))
        self.assertTrue(self.run_cli("bar-move", "1")["ok"])
        ids = [e["id"] for e in json.loads(self.read(self.shell_json))["bar"]["layout"]["right"]]
        self.assertEqual(ids, ["other", ID])

    def test_move_left_swaps_with_previous_item(self):
        self.write(self.shell_json, self._layout(right=("other", ID)))
        self.assertTrue(self.run_cli("bar-move", "-1")["ok"])
        ids = [e["id"] for e in json.loads(self.read(self.shell_json))["bar"]["layout"]["right"]]
        self.assertEqual(ids, [ID, "other"])

    def test_move_clamped_at_start(self):
        self.write(self.shell_json, self._layout(left=(ID, "other")))
        self.run_cli("bar-move", "-1")
        ids = [e["id"] for e in json.loads(self.read(self.shell_json))["bar"]["layout"]["left"]]
        self.assertEqual(ids, [ID, "other"])

    def test_move_when_hidden_fails(self):
        self.assertFalse(self.run_cli("bar-move", "1")["ok"])


# ─────────────────────────────────────────────────────────────────────────────
# stars command
# ─────────────────────────────────────────────────────────────────────────────

class Stars(Sandbox):

    CATALOG = [
        {"slug": "foo", "name": "Foo", "repo": "https://github.com/alice/foo", "image": "x"},
        {"slug": "bar", "name": "Bar", "repo": "https://github.com/bob/bar",   "image": "x"},
        {"slug": "no-gh", "name": "NoGH", "repo": "https://gitlab.com/user/no-gh", "image": "x"},
    ]

    def seed_catalog(self):
        d = f"{self.home}/.cache/extra-themes-browser"
        os.makedirs(d)
        with open(f"{d}/catalog.json", "w") as f:
            json.dump(self.CATALOG, f)

    def seed_stars(self, counts):
        d = f"{self.home}/.local/state/extra-themes-browser"
        os.makedirs(d, exist_ok=True)
        now = time.time()
        cache = {slug: {"stars": n, "ts": now} for slug, n in counts.items()}
        with open(f"{d}/stars.json", "w") as f:
            json.dump(cache, f)

    def test_non_github_only_catalog_returns_empty_stars(self):
        d = f"{self.home}/.cache/extra-themes-browser"
        os.makedirs(d)
        with open(f"{d}/catalog.json", "w") as f:
            json.dump([{"slug": "no-gh", "name": "No GH",
                        "repo": "https://gitlab.com/user/no-gh", "image": "x"}], f)
        res = self.run_cli("stars")
        self.assertTrue(res["ok"])
        self.assertEqual(res["stars"], {})

    def test_returns_cached_counts(self):
        self.seed_catalog()
        self.seed_stars({"foo": 42, "bar": 7})
        res = self.run_cli("stars")
        self.assertTrue(res["ok"])
        self.assertEqual(res["stars"]["foo"], 42)
        self.assertEqual(res["stars"]["bar"], 7)

    def test_non_github_repos_absent_when_not_cached(self):
        self.seed_catalog()
        self.seed_stars({"foo": 5, "bar": 3})
        res = self.run_cli("stars")
        self.assertTrue(res["ok"])
        self.assertNotIn("no-gh", res["stars"])

    def test_partial_cache_returns_cached_subset(self):
        self.seed_catalog()
        self.seed_stars({"foo": 100})
        res = self.run_cli("stars")
        self.assertTrue(res["ok"])
        self.assertEqual(res["stars"]["foo"], 100)
        self.assertNotIn("bar", res["stars"])  # not cached, network absent


# ─────────────────────────────────────────────────────────────────────────────
# status / update  (need real git)
# ─────────────────────────────────────────────────────────────────────────────

class GitSandbox(Sandbox):
    """Sandbox with git available and a local upstream/clone per theme."""

    def setUp(self):
        super().setUp()
        os.symlink(shutil.which("git"), os.path.join(self.shims, "git"))
        self.git_env = {
            "PATH": os.environ["PATH"], "HOME": self.tmp.name,
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
        }
        self.themes_dir = f"{self.home}/.config/omarchy/themes"
        os.makedirs(self.themes_dir)
        self._repos = {}

    def git(self, *args, cwd=None):
        subprocess.run(["git", *args], cwd=cwd, env=self.git_env,
                       check=True, capture_output=True)

    def make_repo(self, slug):
        seed = os.path.join(self.tmp.name, f"{slug}-seed")
        bare = os.path.join(self.tmp.name, f"{slug}.git")
        self.git("init", "-q", "-b", "main", seed)
        self.write(os.path.join(seed, "colors.toml"), "v1\n")
        self.git("add", "-A", cwd=seed)
        self.git("commit", "-q", "-m", "init", cwd=seed)
        self.git("clone", "-q", "--bare", seed, bare)
        self.git("clone", "-q", bare, os.path.join(self.themes_dir, slug))
        self._repos[slug] = (seed, bare)

    def advance(self, slug, content="v2\n"):
        seed, bare = self._repos[slug]
        self.write(os.path.join(seed, "colors.toml"), content)
        self.git("commit", "-q", "-am", content.strip(), cwd=seed)
        self.git("push", "-q", bare, "main", cwd=seed)


class Status(GitSandbox):

    def test_empty_when_up_to_date(self):
        self.make_repo("foo")
        res = self.run_cli("status")
        self.assertEqual(res["outdated"], [])
        self.assertEqual(res["failed"], [])

    def test_reports_outdated_theme(self):
        self.make_repo("foo")
        self.advance("foo")
        res = self.run_cli("status")
        self.assertIn("foo", res["outdated"])
        self.assertIn("foo", res["upstream"])

    def test_non_git_dirs_ignored(self):
        os.makedirs(f"{self.themes_dir}/not-git")
        res = self.run_cli("status")
        self.assertEqual(res["outdated"], [])
        self.assertNotIn("not-git", res.get("failed", []))

    def test_unreachable_upstream_reported_in_failed(self):
        self.make_repo("foo")
        seed, bare = self._repos["foo"]
        os.rename(bare, bare + ".offline")
        res = self.run_cli("status")
        self.assertIn("foo", res["failed"])
        os.rename(bare + ".offline", bare)


class Update(GitSandbox):

    def test_update_pulls_new_commit(self):
        self.make_repo("foo")
        self.advance("foo")
        self.assertTrue(self.run_cli("update", "foo")["ok"])

    def test_update_non_git_dir_fails(self):
        os.makedirs(f"{self.themes_dir}/not-git")
        self.assertFalse(self.run_cli("update", "not-git")["ok"])

    def test_update_bad_slug_fails(self):
        self.assertFalse(self.run_cli("update", "../evil")["ok"])


# ─────────────────────────────────────────────────────────────────────────────
# cleanup — full end-to-end: place everything, remove everything
# ─────────────────────────────────────────────────────────────────────────────

class CleanupAll(Sandbox):

    def test_cleanup_removes_bar_menu_shortcut_cache_and_state(self):
        self.run_cli("bar", "right")
        self.write(self.menu, "{\n}\n")
        self.run_cli("menu", "on")
        self.write(self.bindings, "-- mine\n")
        self.run_cli("shortcut-set", "SUPER + CTRL + T")
        self.run_cli("favorite", "foo")
        cache_dir = f"{self.home}/.cache/extra-themes-browser"
        os.makedirs(cache_dir, exist_ok=True)
        open(f"{cache_dir}/catalog.json", "w").close()

        res = self.run_cli("cleanup")
        self.assertTrue(res["ok"], res.get("error"))

        cfg = json.loads(self.read(self.shell_json))
        all_ids = [
            (e if isinstance(e, str) else e.get("id"))
            for sec in cfg["bar"]["layout"].values() for e in sec
        ] + [
            (e if isinstance(e, str) else e.get("id"))
            for e in cfg.get("plugins", [])
        ]
        self.assertNotIn(ID, all_ids)
        self.assertNotIn("extra-themes-browser-menu", self.read(self.menu))
        self.assertNotIn("extra-themes-browser-keybind", self.read(self.bindings))
        self.assertFalse(os.path.exists(f"{self.home}/.local/state/extra-themes-browser"))
        self.assertFalse(os.path.exists(cache_dir))

    def test_cleanup_is_idempotent(self):
        self.assertTrue(self.run_cli("cleanup")["ok"])
        self.assertTrue(self.run_cli("cleanup")["ok"])


class GithubRepo(unittest.TestCase):
    """Only canonical owner/repo URLs may turn into GitHub API requests."""

    def test_canonical_forms(self):
        for url in ("https://github.com/alice/foo", "https://github.com/alice/foo/",
                    "https://github.com/alice/foo.git", "https://github.com/a-b/omarchy-x.y_z-theme"):
            self.assertIsNotNone(_BE.github_repo(url), url)
        self.assertEqual(_BE.github_repo("https://github.com/alice/foo.git"), ("alice", "foo"))

    def test_rejects_extra_path_query_and_other_hosts(self):
        for url in ("https://github.com/alice/foo/tarball/main", "https://github.com/alice/foo/zipball",
                    "https://github.com/alice/foo?x=1", "https://github.com/alice/foo#x",
                    "https://github.com/alice", "https://github.com/alice/..",
                    "https://github.com/../foo", "https://github.com/alice/foo%2Fbar",
                    "http://github.com/alice/foo", "https://github.com.evil/alice/foo",
                    "https://gitlab.com/alice/foo"):
            self.assertIsNone(_BE.github_repo(url), url)


class CappedFetch(unittest.TestCase):
    """The stars request reads bounded bytes and never follows redirects."""

    @classmethod
    def setUpClass(cls):
        import http.server
        import threading

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_GET(self):
                if self.path == "/redirect":
                    self.send_response(302)
                    self.send_header("Location", "/big")
                    self.end_headers()
                    return
                body = b'{"stargazers_count": 7}' if self.path == "/ok" else b"x" * (_BE.STARS_MAX_BYTES + 10)
                self.send_response(200)
                if self.path != "/big-nolength":
                    self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        cls.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.srv.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.srv.server_close()

    def fetch(self, path, deadline=30):
        with _BE._api_opener.open(self.base + path, timeout=5) as r:
            return _BE.read_capped(r, _BE.STARS_MAX_BYTES, time.monotonic() + deadline)

    def test_small_response_is_read(self):
        self.assertEqual(json.loads(self.fetch("/ok")), {"stargazers_count": 7})

    def test_oversize_with_length_is_rejected(self):
        with self.assertRaises(ValueError):
            self.fetch("/big")

    def test_oversize_without_length_is_rejected(self):
        with self.assertRaises(ValueError):
            self.fetch("/big-nolength")

    def test_redirect_is_not_followed(self):
        import urllib.error
        with self.assertRaises(urllib.error.HTTPError) as cm:
            self.fetch("/redirect")
        self.assertEqual(cm.exception.code, 302)

    def test_deadline_is_enforced(self):
        with self.assertRaises(TimeoutError):
            self.fetch("/ok", deadline=-1)


if __name__ == "__main__":
    unittest.main()
