# `modules.json` field reference

Based on how `synotoolbox_api.sh`, `run_boot_modules.sh`, and `main.js` actually read each field today — not aspirational, this is what's wired up.

## `control`

Picks which renderer fires in `main.js`'s `renderControls` switch: `toggle-display`, `toggle-run`, `toggle-schedule`, `toggle-config-backup`, `toggle-filepicker`, `toggle-volume-numeric`, `toggle-selector`. It also decides (along with `check_args`/`live`) whether the output-text row gets rendered at all.

## `trigger`

Read only by `run_boot_modules.sh`, which runs on package start:

- `"boot"` or `"scheduled"` — if the module is enabled, `run_args` fires automatically every time the package starts (boot, manual restart, etc).
- `"on_save"` — never runs automatically at start. Only fires via Save's enable-diff (see below), so it only runs when someone actively flips the toggle and saves.

Note: `"boot"` and `"scheduled"` are currently **identical** in behavior — `"scheduled"` is a placeholder for real recurring-schedule support via `task_setup.sh`, which isn't wired up yet. Right now it just gets the same boot-time pass as `"boot"`.

## `live`

Read only by `save`'s enable/disable diff loop and by `main.js`'s load/toggle wiring:

- `save` **skips this module entirely** when `live: true` — it'll still write the toggle state to conf, but will never call `run_args` or `disable_args` for it. This is why setting `live: true` on Toggle Reset Button broke it: Save stopped actually running `enable`/`disable`.
- In `main.js`, a `live` module (that has no `check_args`) runs `run_args` when the page loads *if currently checked*, and re-runs on toggle-on / clears its text on toggle-off — client-driven, bypasses Save.

Use `live` only for modules with **no real system effect** — pure read-only display refreshes. Anything that actually changes NAS state should be `live: false` and rely on `check_args` instead if you want a live-looking status readout.

## `check_args`

Read by the `check` action (separate from `run`). If non-null, `main.js` always calls `check` on page load and shows the result — **regardless of the toggle's on/off state**. This is the "show real current state" mechanism; it doesn't touch or care about the enabled/disabled toggle at all.

## `schedule.default_repeat_hour` / `schedule.default_repeat_week`, `numeric.{default,min,label}`, `selector.{options,secondary_toggle}`, `filepicker.label`

All pure UI defaults/labels consumed only by their matching renderer in `main.js`. None of them affect backend execution.

`toggle-schedule` (e.g. `schedule_ups_connected`) uses `default_repeat_hour` with `renderHourSelect` (1-12 hours), saved as `<id>_hour`.

`toggle-config-backup` (`config_backup`) instead uses `default_repeat_week` with the separate `renderWeekSelect` (1-4 weeks), saved as `<id>_week`. This is a distinct field/unit from `default_repeat_hour` - not a conversion of it - since only `config_backup` currently needs a weekly-granularity picker. `config_backup_hour` is no longer written by the UI; the backend (`synotoolbox_api.sh` / `synology_config_backup.sh`) needs to be updated to read `config_backup_week` instead, since that key wasn't provided/verified in this session.

## `volume_source`

Currently **dead** — I added it as a documentation note on `seq_io` but nothing actually reads it. `main.js`'s volume picker always calls `listvolumes` regardless of this field. Safe to ignore or remove.

## `disabled`

Optional bool. Only an explicit `true` counts - absent and `false` behave identically (module active as normal). When `true`, the module is treated as if it weren't in the manifest at all:

- `getstate` (in `synotoolbox_api.sh`) leaves it out of its result, so `main.js` never renders a row for it and Save never submits its fields.
- `run_module_script` refuses to run it, which covers the `run` and `check` actions, `runboot`, and Save's enable-diff.
- `run_boot_modules.sh` (DSM 6 start path) skips it.
- `sync_scheduled_task` never creates a Task Scheduler entry for it.
- If a Task Scheduler entry for it already exists from before it was disabled (listed in `schedules_set`), `getstate` removes the task, drops it from `schedules_set`, and resets `<id>_enabled` to `no`.
- It stays in the manifest, so `remove_all_schedules` (uninstall) can still find and clean up after it.

Different from `hidden_row`, which only keeps the module out of `renderList` - a `hidden_row` module still runs, is still returned by `getstate`, and can still be scheduled (`pkg_updates`, `cpu_usage` and `disable_ssh_root` all rely on that). Use `disabled` to ship a module that's still in development: remove the key or set it to `false` to bring it back.

## `requires`

Optional object. Declares what a module needs from the NAS. If any key present isn't satisfied, the module is **unsupported** on this NAS: its row is still shown (so users know it exists), but its toggle is greyed out and it can't be enabled or run. Evaluated by `tb_requirements_unmet` in `conf_lib.sh`, which `getstate`, `run_module_script`, `runboot` and `run_boot_modules.sh` all share. Keys (all optional, all must pass):

- `min_dsm_major` (integer): `/etc.defaults/VERSION` `majorversion` must be >= this. e.g. `7` excludes DSM 6.
- `min_build` (integer): `/etc.defaults/VERSION` `buildnumber` must be >= this. `86009` is DSM 7.3.2 (the same cutoff `restore_rs3621_fan_speed.sh` uses).
- `models` (array of strings): the NAS model must equal one of them - exact match, case-insensitive, no substring matching. Model comes from `upnpmodelname` in `/etc.defaults/synoinfo.conf`, falling back to `/proc/sys/kernel/syno_hw_version`.
- `exists` (array of paths): every path must exist, e.g. `/dev/synoboot`, `/proc/mtd`.

If a value needed for a check can't be read (model unknown, VERSION unreadable), the requirement counts as **unmet**.

What "unsupported" does at runtime:

- `getstate` still returns the module, adds `"unsupported": true`, and reports `current_enabled` as `"no"` even if `toolbox.conf` still says `yes` (e.g. left over from another DSM version).
- `main.js` renders the toggle `disabled` with a greyed slider and a tooltip.
- `run_args` is refused (`run` action, `runboot`, Save's enable-diff, `run_boot_modules.sh`). `disable_args` and `check_args` are **not** blocked - `check_args` is what shows the user why the module isn't available, so an unsupported module's script should print a clear reason when called with its check args. No reason text lives in the manifest.

Different from `disabled`: `disabled` removes the module from the UI and from `getstate` entirely (development/unreleased); `requires` keeps it visible but inert on hardware or DSM versions that can't use it.

## `note`

Pure documentation. Never read by any script.

---

## `run_args` / `disable_args` / `check_args`: `null` vs `[]` vs `["arg", ...]`

All three go through the same `run_module_script()` resolver, which does `.field // []` — so **`null` and `[]` both mean "call the script with zero arguments"** at the args level. They are not the same thing everywhere, though, because two of the three fields have an extra gate *before* that resolver ever runs:

| Field | `null` | `[]` | `["arg", ...]` |
|---|---|---|---|
| `run_args` | Script runs with **no args**. (No skip-gate exists — enabling always runs *something*.) | Same as `null` — runs with no args. | Runs with those args (after `{placeholder}` substitution). |
| `disable_args` | **Skipped entirely** — Save's `yes→no` branch checks for `null` and does nothing at all. No undo happens. | Save **does** call the script, with **zero args**. | Save calls the script with those args. |
| `check_args` | **Skipped entirely** — `main.js` never renders the status row or calls `check` for this module. | `main.js` **does** show the status row and calls `check` with **zero args**. | Calls `check` with those args. |

So the practical rule: **`null` = "this feature doesn't exist for this module, don't call anything."** **`[]` = "this feature exists, call the script with no flags."** Only matters for `disable_args` and `check_args`, since those are optional per-module (not every module can be undone or has a status check). `run_args` is mandatory by design — there's no way to opt a module out of having *something* happen when it's enabled — so `null` and `[]` are functionally the same there.
