# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

An Omarchy shell plugin (Quickshell/QML + a Python backend): a popup to browse, install, update, favorite and preview the extra themes listed on omarchy.org. `README.md` has the user-facing feature and shortcut tables; keep it in sync when behaviour changes.

## Commands

```bash
# Tests (stdlib unittest, no dependencies). Always unset the XDG vars: the backend honours
# them, so inside a sandboxed HOME they would still point at the REAL cache/state dirs.
env -u XDG_CACHE_HOME -u XDG_STATE_HOME python3 -m unittest discover tests
env -u XDG_CACHE_HOME -u XDG_STATE_HOME python3 -m unittest tests.test_backend.ShellJson.test_invalid_file_is_left_alone   # one test

omarchy plugin validate .      # manifest check (also run by the marketplace)
./install.sh                   # rsync this checkout into ~/.config/omarchy/plugins/<id>/
omarchy restart shell          # required after any QML/manifest change (see below)
bin/extra-themes <command>     # run the backend by hand; prints one JSON object (commands: see its docstring)
```

Python changes need no restart: the backend is a fresh process per call. QML changes do: the overlay is `keepLoaded` and the shell caches compiled QML, so edits (even re-installs) can keep showing the old code or a stale compile error until `omarchy restart shell`.

## Architecture

Four pieces, wired by `manifest.json` (`kinds`: overlay, bar-widget, service):

- `ExtraThemes.qml`: the whole popup (one `PanelWindow`). Three views share one key handler: browse, fullscreen preview, settings. All state lives on the root `Item`. Uses three local helpers: `ActionButton.qml` (labelled chip with hover), `Badge.qml` (pill label), `Spinner.qml` (rotating arc canvas).
- `BarWidget.qml`: the top-bar icon (drawn from theme colours); click runs `omarchy-shell shell toggle <id>`.
- `Service.qml`: headless; wakes hourly and runs `bin/extra-themes check-updates`.
- `bin/extra-themes`: Python stdlib CLI that owns all logic and every side effect. One process per call, one JSON object on stdout, failures as `{"ok": false, "error": ...}` (never a traceback). The QML only calls it through `call()` (a `Process` + `StdioCollector`) and never touches files itself.

Things that are not obvious from any single file:

- **Two names.** Plugin id is `io.github.simakwm.extra-themes` (manifest, `PLUGIN_ID`, shortcut command, folder name under `plugins/`). The project/repo is `extra-themes-browser` (cache/state dirs, config-block markers). Don't merge them.
- **Install as a real directory, never a symlink**: the shell rejects bar widgets that load through one ("File name case mismatch"). `omarchy plugin add` clones into the folder named by the manifest id; the installed copy is a git clone, so `git -C <it> checkout -- .` before `omarchy plugin update` if you synced it with `install.sh`.
- **Shell hides the popup by calling `close()`** on the plugin (`shell hide`, second press of the shortcut/icon = `toggle`). `close()` must exist and must not call `shell.hide` (that is `dismiss()`).
- **Bar placement edits `shell.json` directly** (`place()`), not via `omarchy bar put`/`plugin enable`, which do nothing when an entry already exists. For a bar-widget plugin `omarchy plugin list` "enabled" only means "on the bar"; the popup stays usable when the icon is hidden because `plugins[]` keeps an entry (`keep_plugin_enabled`). A missing/empty `shell.json` is started from `$OMARCHY_PATH/config/omarchy/shell.json`; an unparsable one is never overwritten (`load_shell_json(strict=True)`).
- **User config is edited through marked blocks** and nothing else: menu `// [extra-themes-browser-menu]` in `extensions/omarchy-menu.jsonc` (the menu parser only understands whole-line comments and trailing commas, so inline `//` is rejected), and `-- [extra-themes-browser-keybind]` in `hypr/bindings.lua`. Shortcut writes are strictly validated (the text is written into Lua), checked against `hyprctl binds -j`, and rolled back if `hyprctl` fails or reports new errors. Commands in `WRITES_CONFIG` are serialised by `config_lock` because the popup spawns one process per key press. `cleanup` must stay the exact inverse of everything the plugin writes.
- **Theme source is scraped** from the HTML of omarchy.org/themes (regex `ENTRY`); there is no JSON feed, and the default Python User-Agent gets a 403. Installed state is the folder name under `~/.config/omarchy/themes`, derived from the repo name like `omarchy theme install` does. The active theme is read from `~/.local/state/omarchy/current/theme.name` (the folder name; `omarchy theme current` only prettifies it). Uninstalling the active theme switches to `DEFAULT_THEME` ("Tokyo Night"); only git-cloned themes can be removed.
- **Update notifications**: the service wakes hourly, the backend throttles to once per 24 h (`last-check.json`; `--force` bypasses) and remembers announced commits (`notified.json`). `upstream_sha` returns `None` for "could not tell" (offline): that must neither forget past notifications nor start the 24 h window.
- **Async in the popup**: every action reloads the catalog, so responses can arrive out of order (`catalogSeq`/`statusSeq`/`settingsSeq` guards), and settings changes are applied optimistically (`patchSettings`) so key repeat starts from the right value.

## Testing notes

`tests/test_backend.py` runs the CLI as a subprocess in a temp `HOME` whose `PATH` is only a shim directory (fake `omarchy`, `omarchy-shell`, `hyprctl`, `omarchy-notification-send`; `git` is symlinked in for the update tests, and the `hyprctl` shim may only use shell builtins). There are no QML tests; verify UI changes live: `omarchy-shell shell summon|hide|toggle <id>`, `hyprctl layers -j` to see whether the popup is open, `grim` for screenshots. Check the popup is open before sending keys with `wtype`, otherwise the keys land in the focused terminal. `wtype` cannot trigger Hyprland keybinds, so a registered shortcut can only be verified by its bind entry and by running its command.

Live tests touch the user's real desktop (themes, `shell.json`, `bindings.lua`, menu file): record the baseline first and restore it, including the active theme.

## Publishing

Pushes to `main` of `github.com/simakwm/extra-themes-browser` are public; the marketplace submission (omacom/omarchy-plugin-marketplace #9563) validates the repository's current commit. Commit with the repo-local noreply identity already configured, and retry a push once if GitHub answers with a generic "remote rejected".
