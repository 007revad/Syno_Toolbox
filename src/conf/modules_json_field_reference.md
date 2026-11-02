# Syno_Toolbox module guide

How `modules.json` drives Syno_Toolbox, what every field does, and what a new module has to follow. Everything here describes what `synotoolbox_api.sh`, `api.cgi`, `synotoolbox-helper.c`, `run_boot_modules.sh` and `main.js` actually do today.

If you are adding a module, read **Security rules** first. Every module script runs as root.

---

## How a request flows

```
main.js (browser)
  -> api.cgi                       checks the caller is a logged-in DSM administrator
  -> synotoolbox-helper (setuid)   fixed argv whitelist, clears the environment
  -> synotoolbox_api.sh <action>   reads modules.json + toolbox.conf, runs the module script as root
```

- `modules.json` is the manifest: one entry per module. Scripts live in `bin/modules/`.
- `toolbox.conf` holds every saved value. It is root-owned. Keys are `<module_id>_<field>`, for example `seq_io_kb`, `send_wol_mac`, `snapshot_check_excluded`.
- `getstate` returns the manifest merged with the conf: each module gets `current_enabled` (`yes`/`no`) and `current_fields` (every conf key that starts with `<module_id>_`, with that prefix removed).
- `save` writes only the keys it is sent, then runs each module whose `<id>_enabled` flipped (see `live` below).
- `run <module_id>` runs `run_args`. `check <module_id>` runs `check_args`. Both return the script's stdout and stderr merged into one string.

The setuid helper only accepts these (subcommand, argument count) pairs, so a new feature cannot add a new action without a change to `synotoolbox-helper.c`:

| Arguments | Subcommands |
|---|---|
| none | `getstate listvolumes listwoldevices discoverwol wolscanstatus listshares discovernas discovertoolboxnas selfheal runboot` |
| one | `run check save listfolder` |
| two | `receive_backup` |

New UI features normally need no new action. They reuse `run <module_id>` with a hidden module (see **Patterns**).

---

## Security rules for module scripts

Module scripts run as root, started by an administrator's click in DSM. Treat every module as privileged code.

1. **Never build a command from untrusted text.** That includes values read from `toolbox.conf` (they were typed into the UI), usernames, share names, file names and anything read from a log. Validate against a strict pattern (`^[A-Za-z0-9_@.][A-Za-z0-9_@.-]*$` for names, `^[0-9]+$` for numbers) or match against a fixed whitelist. Never `eval`.
2. **Arguments are passed as separate argv elements, never through a shell.** A `{field}` placeholder is substituted inside a single argument and is never word-split. The script still has to validate what it receives.
3. **Reject names starting with `-`** before passing them to another command.
4. **Only use commands you have verified on real DSM 6/7 output.** Do not guess a Synology CLI's subcommands or output format. Copy real output into the PR.
5. **Never write a secret to `toolbox.conf`.** Passwords use `secret_input` (below), which pipes the value over stdin for one run and stores nothing.
6. **Scripts must behave with the exact arguments in the manifest** and print something useful on every path, including errors. Exit 0 for "ran, here is the answer", non-zero only for a real failure. The `run` action reports `success: false` for a non-zero exit, and the UI shows the output as the error message.
7. **Package files must be `root:<package-name>`**, never `root:root`, in package scripts. DSM 7 rejects `root:root`.
8. **Every module is reviewed line by line before it is merged.** A module that looks harmless can still be a root-level problem once its inputs are attacker-controlled.

`api.cgi` requires a logged-in DSM administrator for every action except `init`, `pingtoolbox`, `pkgupdateshtml` and `cpuusagehtml` (the last two load in iframes, which cannot send the X-SYNO-TOKEN header) and `receive_backup` (protected by its own shared secret). Do not add a new open action unless it genuinely cannot work any other way, and never from one that exposes NAS data.

---

## Adding a module: checklist

1. Write `bin/modules/<name>.sh`. Make it executable. Validate all inputs (rules above).
2. Add an entry to `modules.json`. Required fields: `id`, `category`, `name`, `control`, `script`, `trigger`, `live`, `run_args`, `disable_args`, `check_args`.
3. Pick the pattern that fits (see **Patterns**). Most read-only status rows are `live: true` with `check_args: []`.
4. Test on DSM 6 and DSM 7 if you can, otherwise set `requires` honestly (`min_dsm_major`).
5. Hard-refresh the browser (the UI file is renamed on each build to bust the cache) and check the row, Save, Refresh and a reboot or package restart.

---

## Field reference

### Identity and placement

| Field | Meaning |
|---|---|
| `id` | Unique module id. Used in conf keys (`<id>_enabled`, `<id>_<field>`), in `data-module-id` in the UI, and in the `run`/`check` actions. Lowercase letters, digits and `_`. |
| `category` | `info` and `tools` render as rows on the Info and Tools tabs. Other categories (`packages`, `cpu_usage`, `snapshots`) belong to tabs whose content `main.js` builds itself, so their modules are normally `hidden_row`. |
| `name` | Row label. Also used to name the DSM Task Scheduler entry for scheduled modules: `Syno_Toolbox <name>`. Renaming a scheduled module orphans its old task. |
| `script` | Path under the package, for example `bin/modules/hardware_info.sh`. Several modules may share one script and differ only by arguments (`failed_logins`, `failed_logins_list`, `failed_logins_count`). |
| `note` | Documentation only. Never read by any script or by the UI. |
| `hidden_row` | `true` keeps the module out of the Info/Tools lists. It is still returned by `getstate`, can still run and can still be scheduled. Used for modules that `main.js` drives itself. |

### `control`

Selects the renderer in `main.js`'s `renderControls`. It also decides, together with `check_args` and `live`, whether the row gets a result line.

| `control` | What the row shows | Fields it reads |
|---|---|---|
| `toggle-display` | Toggle + result text | none |
| `toggle-run` | Toggle + result text | none |
| `toggle-schedule` | Toggle + hour select | `schedule.default_repeat_hour`, saved as `<id>_hour` |
| `toggle-config-backup` | Frequency select, destination path, Settings | `schedule.default_frequency`, saved as `<id>_frequency`, `<id>_target_dir`, `<id>_shared_secret` and remote-destination keys |
| `toggle-filepicker` | Path box, Browse, Settings | `filepicker.label`, saved as `<id>_path` |
| `toggle-volume-numeric` | Volume checkboxes (from `listvolumes`) + number box | `numeric.{label,default,min}`, saved as `<id>_volumes` (comma-separated) and `<id>_kb` |
| `toggle-selector` | Drop-down + optional second checkbox | `selector.options[]` (`label`, `value`), `selector.secondary_toggle` (`label`, `value`), saved as `<id>_mode` and `<id>_raidf1` |
| `toggle-wol-selector` | Device list, Send WOL, Settings | none; stores `<id>_mac` and `<id>_hidden_macs` |
| `toggle-password-prompt` | Password box + Enable (+ Disable if `companion_id`) | `secret_input`, `companion_id` |
| `toggle-failed-logins` | View and Settings buttons | drives hidden modules `failed_logins_list` and `failed_logins_count` |
| `hidden-companion` | Never rendered | used as the target of another module's `companion_id` |

The toggle itself is hidden (not just disabled) for `toggle-wol-selector`, `toggle-password-prompt`, and any row that is both `live: true` and has `check_args`. Those rows have no real on/off state.

### `trigger`

Read by `runboot` (DSM 7) and `run_boot_modules.sh` (DSM 6 start path), which run when the package starts:

- `"boot"` and `"scheduled"`: if the module is enabled, `run_args` runs automatically every time the package starts.
- `"on_save"`: never runs automatically at start. It only runs through Save's enable-diff, when someone flips the toggle and saves.

`"scheduled"` is **not** what creates a Task Scheduler entry. That is driven by the presence of a `schedule` object (see below). Boot-time behaviour of `"boot"` and `"scheduled"` is identical.

### `live`

Read by `save`'s diff loop and by `main.js`'s load and toggle wiring:

- `save` **skips this module entirely** when `live: true`. The toggle state is still written to conf, but `run_args` and `disable_args` are never called. A module that really enables something (a service, a setting) must be `live: false`.
- In `main.js`, a `live` module that has no `check_args` runs its `run_args` when the page loads (if its toggle is on), runs again when the toggle is switched on, and has its result cleared when it is switched off. Save → refresh also re-runs it. This is driven by the browser and bypasses Save.

Use `live: true` only for modules with no system effect: pure read-only displays.

### `run_args`, `disable_args`, `check_args`

All three go through the same resolver, which treats a missing field as `[]`, so **`null` and `[]` both mean "run the script with zero arguments"**. They differ because two of them have an extra gate before the resolver:

| Field | `null` | `[]` | `["arg", ...]` |
|---|---|---|---|
| `run_args` | Runs with no args. There is no skip: enabling always runs something. | Same as `null`. | Runs with those args after placeholder substitution. |
| `disable_args` | **Skipped.** Save's yes→no step does nothing. No undo happens. | Save calls the script with no args. | Save calls the script with those args. |
| `check_args` | **Skipped.** The UI never shows a status row or calls `check`. | The UI shows the status row and calls `check` with no args. | Calls `check` with those args. |

So: `null` means "this feature does not exist for this module". `[]` means "it exists, call the script with no flags".

`check` always runs, **regardless of the toggle**. It is the "show the real current state" mechanism.

### Placeholders

Any `{field}` inside an arg (lowercase letters and `_` only) is replaced with the conf value of `<module_id>_<field>`, for example `"--kb={kb}"` reads `seq_io_kb`. An unset key becomes an empty string, so the script must cope with an empty value and must default safely. A placeholder never splits into several arguments.

The module id used is that of the module being run, not of the module that owns the UI. A hidden companion module that needs a setting reads its own `<companion_id>_<field>` key, for example `failed_logins_list_max_rows`.

Conf keys come from the UI's `save` call, so treat every value as untrusted input.

### `schedule`

An object with exactly one of these keys. Its presence makes Save keep a real DSM Task Scheduler entry in step with the toggle:

| Key | Meaning |
|---|---|
| `default_repeat_minute` | Repeat every N minutes. Saved as `<id>_minute`. |
| `default_repeat_hour` | Repeat every N hours. Saved as `<id>_hour`. |
| `default_frequency` | `week` or `month`. Saved as `<id>_frequency`. |

The task is named `Syno_Toolbox <name>` and runs the module's **`script` with no arguments**, so a scheduled module's script must do the right thing when called bare. The ids of modules that have a task are kept in `toolbox.conf`'s `schedules_set` so uninstall can remove them. If the task fails to create, `<id>_enabled` is reset to `no`. `getstate` also resets `<id>_enabled` to `no` if the module's Task Scheduler entry no longer exists.

### `requires`

Optional object. If any listed key is not satisfied the module is **unsupported** on this NAS: its row is still shown, its toggle is greyed out with a tooltip, and `run_args` is refused. `disable_args` and `check_args` are not blocked, because `check_args` is how the module tells the user why it is unavailable, so an unsupported module's script should print a clear reason when called with its check args. All keys are optional and all must pass:

| Key | Meaning |
|---|---|
| `min_dsm_major` | `/etc.defaults/VERSION` `majorversion` must be at least this. `7` excludes DSM 6. |
| `min_build` | `buildnumber` must be at least this. `86009` is DSM 7.3.2. |
| `models` | Array of model names. Exact, case-insensitive match against `upnpmodelname` in `/etc.defaults/synoinfo.conf`, falling back to `/proc/sys/kernel/syno_hw_version`. |
| `exists` | Array of paths that must all exist, such as `/dev/synoboot`. |

If a value needed for a check cannot be read, the requirement counts as unmet. `getstate` reports `unsupported: true` and forces `current_enabled` to `no`.

(Evaluated by `tb_requirements_unmet` in `conf_lib.sh`.)

### `disabled`

Optional. Only an explicit `true` counts. A disabled module is treated as if it were not in the manifest: `getstate` omits it, `run_module_script` refuses to run it, no Task Scheduler entry is created, and an existing one is removed. It stays in `modules.json` so uninstall can still clean up. Use it to ship a module that is still in development. `hidden_row` is different: a hidden module still runs.

### `rerun_on_change`

`true` makes Save re-run `run_args` when the module stays enabled but one of its own `<id>_*` fields (other than `_enabled`) changed. `seq_io` uses it so a new volume or KB value takes effect. The UI mirrors this in `computeChangedModuleIds`.

### `result_style`

`"monospace"` renders the result text in a monospace font (hardware info, UPS status, telnet password).

### `secret_input` and `companion_id`

For modules that need a password (`enable_ssh_root`):

- `secret_input: true` makes `run` pipe the password from `api.cgi`'s stdin to the script as `--pwd`. The password never goes into `toolbox.conf`, `run_args` or placeholders.
- `companion_id` names a second module (control `hidden-companion`, `hidden_row: true`) that the row's second button calls. In the example, Enable runs `enable_ssh_root` and Disable runs `disable_ssh_root`, which share one script.

### `volume_source`

Not read by anything. `main.js` always populates the volume list from the `listvolumes` action. Safe to ignore or remove.

---

## Patterns

### 1. Read-only status row

```json
{ "id": "hardware_info", "category": "info", "name": "Hardware Information",
  "control": "toggle-display", "script": "bin/modules/hardware_info.sh",
  "trigger": "boot", "live": true,
  "run_args": [], "disable_args": null, "check_args": [],
  "result_style": "monospace" }
```

`check_args: []` means the UI calls `check` on load and always shows the current output. Because it is `live` with `check_args`, the toggle is hidden.

### 2. Real on/off action

`live: false`, `run_args` does the enable, `disable_args` undoes it (or `null` if it cannot be undone), and `check_args` reports the real current state so the row is correct even if the setting was changed outside Syno_Toolbox.

### 3. Hidden module driven by the UI

When a feature needs data in a modal or a whole tab (the Snapshots tab, the Failed Logins View table), `main.js` calls the ordinary `run` action on a **hidden** module and renders the output itself:

- Set `"hidden_row": true`, `"trigger": "on_save"` and `"live": true` (or `false`). On-save keeps boot from ever running it, and `live: true` keeps Save from ever running it.
- Have the script print exactly what the UI expects: a bare integer (`failed_logins_count`), a JSON document (`failed_logins_list`), or a full HTML page (`snapshot_check`, shown in a sandboxed iframe via `srcdoc`).
- Prefer this over a new `api.cgi` action. `run` is authenticated and covered by the helper's existing whitelist.
- If the UI decides something from the output, do not match its text. Output wording will be translated. Print a number or JSON and branch on that.

### 4. Per-module settings stored in conf

Settings windows save one conf key per setting, using `save` with only that key:

```js
SYNO.SDS.Syno_Toolbox.apiCall("save", { form_json: Ext.encode({ failed_logins_list_max_rows: "200" }) }, "POST", callback);
```

The hidden module reads it back as a placeholder (`"run_args": ["list", "{max_rows}"]`). `getstate` returns it in `current_fields.max_rows` for the owning module id. Defaults must live in the script, since an unset key arrives as an empty string. `save` only writes keys it is given, so a Settings window never disturbs other modules.

If a list setting (like Snapshots' excluded shares) has to be stored in one key, use a delimiter that the values cannot contain, and make "new item" mean "included by default" so nothing new is silently skipped.

---

## Gotchas

- **Id prefixes.** `current_fields` collects every conf key starting with `<id>_`. A module whose id is a prefix of another (`failed_logins` and `failed_logins_list`) also receives the longer module's keys, with names like `list_enabled`. This is harmless if you do not read them, but do not use a field name that could collide.
- **Doubled "Running…".** A live module is run once when its toggle is switched on and again after Save → refresh. It is cosmetic. `main.js` skips the second run for Failed Logins only, so other live modules can still show it.
- **Browser caching.** `main.js` is renamed on each build. After deploying a changed UI, do a hard refresh (Ctrl+Shift+R) before concluding a fix did not work.
- **Output is merged.** `run` and `check` capture stdout and stderr together. A script that writes warnings to stderr will show them in the UI. Redirect or discard stderr of commands whose noise you do not want (`2>/dev/null`).
- **Empty output.** Print something on every path. An empty result is shown as "(no output)" in the UI.
- **DSM 6.** Its `bash` is older: some versions throw "unbound variable" for an empty array under `set -u`. Check `${#arr[@]}` before expanding an array that may be empty.
- **Task Scheduler names.** A scheduled module's task is found by name (`Syno_Toolbox <name>`). Changing `name` leaves the old task behind.
