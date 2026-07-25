# Changelog

Changes made in this fork, newest first. Versions here are this fork's own and
don't line up with either parent. For anything before the fork point, see the
history of
[CarloDePieri/bluetooth.koplugin](https://github.com/CarloDePieri/bluetooth.koplugin)
and [onatbas/bluetooth.koplugin](https://github.com/onatbas/bluetooth.koplugin).

## Unreleased

### Changed

- The remote's `/dev/input/eventN` is resolved at runtime by reading it back
  from `/proc/bus/input/devices` by device name, instead of assuming `event3`.
  The number moves across reconnects, and when it moved, everything that opened
  the input device failed.
- The device name lives in `device.conf`, sourced by the shell scripts and
  parsed by `main.lua`. It was duplicated across three files, which is how the
  unquoted `grep` got in. Each consumer keeps the default as a fallback, so a
  missing `device.conf` doesn't break anything.

### Fixed

- **A reconnect onto the same event number left the remote dead.** Disconnecting
  destroys the uhid device and reconnecting can recreate it on the same number,
  so the fd being held pointed at a device that no longer existed — same path,
  different device, no events. The input device is now closed before reopening
  regardless of whether the path changed. This also closes the handle leak the
  old code had.
- **Opening the input device raced udev.** The kernel lists the device in
  `/proc/bus/input/devices` immediately, but `/dev` is a plain tmpfs here and
  `udevd` creates the node a moment later, so opening as soon as the entry
  appeared failed with `No such file or directory`. It now polls for a node that
  actually opens. The fixed `sleep 3` this replaced had been covering the lag by
  accident; the poll is both correct and quicker in the normal case.
- A device that's listed but whose node never appears now reports that, instead
  of surfacing a raw `input.lua` traceback.

## v1.0.0 — 2026-07-25 — Kobo Sage + official Kobo Remote

First working configuration on a Kobo Sage (Realtek RTL8821CS) driving the
official Kobo Remote over BLE. Running on my own device.

### Added

- `docs/HANDOFF.md` — full technical record: established hardware facts and how
  each was confirmed, the working scripts line by line with the reasoning,
  a table of dead ends not worth retrying, the double-page-advance diagnosis,
  open issues, and debugging commands.
- `.gitattributes` forcing LF, so the shell scripts survive a clone made on
  Windows.
- Unconditional rfkill power-cycle in `on.sh`. `hci0` regularly ends up
  attached-but-DOWN, where `hciconfig hci0 up` fails with `Connection timed out
  (110)`; only a full 0→1 cycle plus a fresh attach recovers it. Detecting the
  bad state wasn't worth the complexity, so it now happens every time — at the
  cost of always dropping an existing connection on toggle.

### Changed

- **Bluetooth bring-up switched from Broadcom to Realtek.** `on.sh` /`off.sh`
  now use `/sbin/rtk_hciattach -n -s 115200 /dev/ttyS1 rtk_h5` in place of
  `hciattach ... bcm43xx 1500000 flow -t 20 -b bcm43xx_init`. The Broadcom
  handshake was being spoken to a Realtek part and always died with
  `Initialization timed out`, so `hci0` never existed and every downstream step
  failed with `no default controller`.
- `bluetoothd` is started with `setsid`. Backgrounded with a plain `&` from an
  interactive shell it dies with the session.
- `rtk_hciattach` output is redirected to `/var/log/rtk_hciattach.log`. It is a
  resident process (H5 needs the link serviced continuously), so on the inherited
  stdout it holds the plugin's `io.popen` pipe open forever and hangs KOReader's
  UI thread. Diagnosed from `/proc/<pid>/wchan` = `pipe_wait`.
- `connect.sh` and `repair.sh` match the device name `Kobo Remote` instead of
  CarloDePieri's `Q36` / `Q36 for Android`.
- `onBluetoothOn()` calls `onDeviceRepair()` on success rather than just showing
  a popup, so a single menu tap takes the remote all the way from powered-off to
  turning pages.
- The three long operations now paint a progress message before blocking. The
  scripts sleep for 15-20 s in total and `executeScript()` reads them to EOF on
  the UI thread, so the reader previously just appeared frozen. The work is
  still synchronous — only the silence is fixed.
- Rewrote `readme.md` for this fork: Sage hardware, install requirements,
  what each menu item does, and known issues.

### Fixed

- **Remote buttons did nothing.** The Kobo Remote is BLE HID-over-GATT and emits
  only `EV_MSC`/`MSC_SCAN`; the kernel never synthesises a matching `EV_KEY`
  despite the key codes appearing in the device's capability bitmap. The normal
  remedy, a udev hwdb rule, is unavailable — this firmware's `udevadm` has no
  `hwdb` subcommand and no `hwdb.d` directories exist. `main.lua` now translates
  the scancodes inside a `registerEventAdjustHook` and dispatches `GotoViewRel`
  directly.
- **Every button press turned two pages.** KOReader instantiates a plugin once
  per UI context (FileManager and ReaderUI), so `init()` ran twice in one
  process, and `registerEventAdjustHook` chains hooks rather than replacing them.
  Two live hooks, each debouncing against its own per-instance state, both fired.
  The registration guard and debounce table moved to module scope, where the
  `require` cache makes them genuinely shared.
- **`Reconnect to Device` never worked.** The `Q36` → `Kobo Remote` rename left
  `grep Kobo Remote` unquoted, so grep searched for `Kobo` in a file named
  `Remote`, failed, and `set -e` aborted `connect.sh` before it could connect.
  The pattern is now quoted, and a missing remote reports `Device not found.`
  instead of aborting with an empty popup.
- **`Refresh Device Input` crashed.** `refreshPairing()` called
  `Device.input.open(path)` with a dot, binding the path string as `self`;
  `self.input` was then nil and `input.lua:335` threw on `self.input.is_ffi`.
  Now `Device.input:open(path)`.
- **Success popups appeared after failures.** `refreshPairing()` reports its own
  error and then returned nothing, so all three callers went on to announce that
  the device was open or the connection succeeded — two contradictory dialogs,
  the reassuring one second. It now returns the `pcall` status and callers gate
  on it. This fired exactly in the common case: a moved event number.
- **`on.sh` reported success even when the controller didn't come up.** The
  final `echo "complete"` was unconditional, so a failed `hciconfig hci0 up`
  still sent the plugin into pairing against a controller that wasn't there.
  It now checks for `UP RUNNING` and reports the log path instead.
- **`isBluetoothOn()` only read rfkill**, which reports that the radio is
  unblocked — something that can be true at boot with nothing attached. The menu
  would then show Bluetooth as on and offer connect actions that could only
  fail. It now also requires `hci0` to exist in sysfs.
- **`io.popen` results are nil-checked** in `executeScript()` and
  `isWifiEnabled()`. A failed `popen` previously threw from inside the plugin
  with no `pcall` above it, taking KOReader down rather than showing a popup.
- CRLF line endings in `uhid/run.sh`, which would have failed on the device.
- shellcheck cleanups in `on.sh`, `off.sh` and `repair.sh`: unchecked `cd`,
  unquoted `$bluetooth_address` expansions, and `read` without `-r`.

### Known issues

Carried into this release, tracked in the readme and `docs/HANDOFF.md`:
`input_device_path` is hardcoded to `/dev/input/event3` though the
event number moves; the BLE link doesn't survive idle; bond state can reach
`Connected: yes` / `Paired: no` where no input device is created;
`refreshPairing()` never closes the previous fd; and the 0.5 s debounce gap is
an untuned guess.

## Before the fork

Everything up to and including `fcb5341` (2025-04-03) is CarloDePieri's work:
non-hardcoded MAC via `repair.sh` / `connect.sh`, the reworked plugin menu, and
his own Sage on/off scripts. Everything before that is onatbas's original
plugin.
