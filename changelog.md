# Changelog

Changes made in this fork, newest first. Versions here are this fork's own and
don't line up with either parent. For anything before the fork point, see the
history of
[CarloDePieri/bluetooth.koplugin](https://github.com/CarloDePieri/bluetooth.koplugin)
and [onatbas/bluetooth.koplugin](https://github.com/onatbas/bluetooth.koplugin).

## v1.4.0 — 2026-09-24 — Hanlinyue Free3 support

A second remote: the Hanlinyue Free3 in P mode works alongside the official
Kobo Remote. Either one turns pages, and the Free3 is preferred when both are
around. Bluetooth now comes up by itself when KOReader starts and connects in
the background. Its menu moves up beside Network and gains options to invert
the buttons, to assign the Free3's third button, and to turn startup off. All
confirmed on the Sage (KOReader v2026.03).

**Upgrading:** copy the whole folder. `device.conf` now lists remotes as
`BT_DEVICE_NAMES="Free3-P|Kobo Remote"`. An old one naming a single
`BT_DEVICE_NAME` still works. Pair the Free3 once with **RePair → Free3-P**.

### Added

- **Hanlinyue Free3 support.** Set the switch to P and the mode to Up and
  Down. It then sends exactly the Kobo Remote's codes, so the top key turns
  back and the middle key forward. It is classic Bluetooth, keeps its bond
  through power-offs, and needs no re-pair after being switched off. (#45)
- **Both remotes at once.** `device.conf` lists remotes in order of
  preference, and every listed remote that is connected turns pages. *Reconnect
  to Device* and the background reconnect try them in order. While a remote
  earlier in the list is missing, it is dialled about once a minute even if a
  later one is connected — so switching the Free3 on takes over from the Kobo
  Remote without a menu tap. (#45)
- **RePair is a submenu** with one entry per remote, since a re-pair removes
  that remote's bond first. Success messages name the remote.
- **Bluetooth at startup**, on by default. *Turn on Bluetooth at startup* runs
  `on.sh` quietly a few seconds after KOReader starts, unless Bluetooth is
  already up, and the watcher then connects the first remote that answers. It
  never re-pairs by itself.
- **Invert page-turn buttons**, for any remote. Takes effect immediately.
- **Third button (Free3)** opens KOReader's own action picker, the one
  gestures use. The chosen actions run when the Free3's bottom key is pressed.

### Changed

- **The Bluetooth menu sits on the settings tab directly below Network**,
  instead of inside it.
- **Toggle Bluetooth connects instead of re-pairing.** It used to remove and
  rebuild the bond every time; a remote whose bond is really gone is still
  handed to a re-pair.
- **Messages are short.** The scripts print only outcomes. `bluetoothctl`'s own
  output goes to `crash.log`, tagged `[bluetooth]`. A failed re-pair used to
  fill the screen with scan results for every device in range. It now shows
  the first error and the bond state.

### Fixed

- **A late close could shut the other remote.** When a remote's input device
  vanished, KOReader closed its fd itself but kept the path → fd entry. The
  plugin's own close then hit whatever held that fd number by then, which on
  the Sage was the other remote: connected, and turning no pages until
  *Refresh Device Input*. The plugin now closes an fd only while it still
  refers to that device. (#48)
- **Background runs were cancelled by taps.** The unattended reconnect, and
  now the startup run, sat behind Trapper's invisible trap widget, which any
  tap dismisses. At startup both were cancelled together, and their scripts
  ran on unsupervised. They now cannot be dismissed, and taps go to the reader.
  This was the "one unexplained silent reconnect failure". (#30)
- **The watcher raced `on.sh`.** `hci0` appears partway through bringing the
  stack up, so the watcher started a reconnect while `bluetoothd` was still
  being restarted. It now waits for `on.sh`.
- **`device.conf` was read differently by `main.lua` and the scripts.** With an
  old name kept as a comment, the scripts paired one remote while `main.lua`
  opened the other. Both now skip comments and take the last assignment.

### Documented

- HANDOFF records the Free3's behaviour, confirmed on the device: its three
  names, classic HID, one input device, codes per mode, no auto-repeat, and no
  self-reconnect.
- HANDOFF also covers the Trapper and input-backend mechanisms behind #47, #48
  and #30. It corrects an old claim that `evtest` and KOReader report
  different scancodes: `70051` and `458833` are the same value in hex and
  decimal.

## v1.3.0 — 2026-09-23 — Scripts you can trust, USB share unblocked

The remote turns pages again after a fresh pairing, USB share works with
Bluetooth on, and toggling Bluetooth no longer leaves the screen stuck until
it is tapped. Underneath, the scripts now say "connected" only when the bond
really is there, pick the remote by its exact name, and are linted in CI. All
of it confirmed on the Sage.

**Upgrading:** copy the whole folder. `connect.sh` and `repair.sh` now source
a new `lib.sh` and fail without it.

### Fixed

- **Connected, but no page turns.** BlueZ creates two input devices named
  `Kobo Remote` on every fresh pairing, and only one of them delivers button
  presses. The plugin opened the first match, which on the Sage was the dead
  one, so the remote showed `Connection successful!` and did nothing. Every
  device with the remote's name is opened now; a dead one costs nothing to
  hold. The watcher reconciles them path by path, so a live device is not
  dropped when a sibling changes. Why BlueZ makes two is not established.
  (#46)
- **The screen stuck on toggle, off and on.** KOReader's `Trapper` treats a
  script as finished once output is waiting on the pipe, then reads the rest
  with a blocking read on the UI thread. `off.sh` prints nothing, so it never
  counted as finished and its message stayed up until tapped. `repair.sh`
  prints as it goes, so its first line counted as finished and the rest of
  the re-pair froze the reader. The shell now collects each script's output
  and hands it over in one piece at exit. (#47)
- **USB share refused to start** with `Filesystem is busy! Offending
  processes: rtk_hciattach, bluetoothd`. `on.sh` started both daemons from the
  plugin folder, so their working directory held `/mnt/onboard` busy. They
  start from `/` now. An open SSH session still blocks USB share, because
  KOReader's `dropbear` runs from `/mnt/onboard`. (#44)
- **`repair.sh` reported success on `bluetoothctl`'s word.** A connect says
  `Connection successful` in the `Connected: yes` / `Paired: no` state, and a
  failed pair or trust went unnoticed. On the path that has already removed
  the old bond, that was the least verified outcome of all. It now reports
  success only once `Paired: yes` and `Connected: yes` both hold, sharing
  `connect.sh`'s bond poll (now `wait_for_bond` in `lib.sh`). (#32)
- **The remote was picked by substring.** Any device whose name contained
  `Kobo Remote` matched, and two matches made a two-line address that
  `bluetoothctl` rejected with an unrelated-looking error. The scripts and
  `main.lua` now compare the whole name. (#35)
- `connect.sh` and `repair.sh` declared `#!/bin/bash`, which stock Kobo
  firmware lacks. They declare `/bin/sh`, which is what always ran them. (#37)

### Changed

- `bluetoothd` no longer runs with `-d`. Debug output wrapped `/var/log`, a
  16 KB tmpfs, within seconds, and cost wakeups for a log nobody could read.
  HANDOFF §8 has the command for a debug daemon logging somewhere with room.
  (#34)
- `repair.sh` uses a shell function instead of a command stored in a string,
  and a `for` loop instead of a piped `while read`. The `sleep 2` after its
  scan is gone: the scan was measured at the full 5 s, and discovery stops
  when `timeout` ends `bluetoothctl`, so the sleep ran with discovery already
  off. A re-pair is 2 s shorter. (#38)

### Added

- CI runs shellcheck (as `sh`, following sourced files) over the scripts and
  luacheck over `main.lua` on every push. (#40)

## v1.2.3 — 2026-07-25 — License restored

No behaviour change.

### Added

- [`LICENSE`](LICENSE) — MIT, byte-identical to
  [onatbas/bluetooth.koplugin](https://github.com/onatbas/bluetooth.koplugin)'s
  and carrying its original *Bluetooth Page Turner Contributors* copyright
  line. The notice had gone missing somewhere down the fork chain, and MIT
  grants the right to modify and redistribute on the condition that it travels
  with the code — so this was owed, not optional. No separate copyright claim
  is made over this fork's changes; they are offered under the same terms as
  part of the same collective.
- [`DISCLAIMER`](DISCLAIMER) — restored from upstream as well, and apt for
  something that power-cycles a radio through rfkill and opens kernel input
  devices.
- A *License* section in [`CREDITS.md`](CREDITS.md) and in the readme,
  including the fact that the intermediate fork carries no license file of its
  own: whatever it inherited stays MIT, its author's own additions are not
  explicitly licensed either way.

## v1.2.2 — 2026-07-25 — Credits

Documentation only; no behaviour change.

### Documented

- [`CREDITS.md`](CREDITS.md) records the fork chain and what each layer of it
  contributed, the prior art surveyed while working out whether the Sage was
  solvable at all, the KOReader internals this plugin leans on more heavily
  than most, and who did what on this fork.
- The readme's *Lineage* section points at it.

## v1.2.1 — 2026-07-25 — Handoff brought up to date

Documentation only; no behaviour change.

### Documented

- [`docs/HANDOFF.md`](docs/HANDOFF.md) now matches the code. The scripts and
  `main.lua` sections describe what they actually do — runtime device
  resolution, the watcher, the unattended reconnect, the Trapper conversion and
  its two-value return — rather than the state of things several releases ago.
- A new section explains the `Connected: yes` / `Paired: no` state end to end,
  from the remote discarding its bond through the authentication failure to the
  missing input device, and why automatic re-pair is the correct fix.
- Four entries added to the dead-ends table: HOGP in `ReconnectUUIDs` and why
  it cannot work for BLE, `sed -i` truncating files on a full rootfs, a mock
  left on `PATH` poisoning later diagnosis, and reading the bond state before
  encryption has settled.
- Open issues rewritten around what's actually left: suspend/resume is the
  untested gap, one unexplained silent reconnect failure, and the lost
  `[General]` block of `main.conf`.
- Platform facts gained BlueZ's real state directory, the size of the rootfs,
  the 16 KB `/var` tmpfs mounts that had been truncating our debug logs, and
  the Trapper API surface.

## v1.2.0 — 2026-07-25 — Recovers on its own, without freezing the reader

The remote comes back by itself now. When the link drops the plugin notices,
dials it again, and re-opens the input device wherever it has landed — no menu
tap, about seven seconds end to end. Nothing blocks the reader while that
happens: the scripts run off the UI thread, so a pair-and-connect is something
you can read straight through. Confirmed on the Sage, along with the cause of
the bond trouble that started all of this — the remote forgets its bond when it
loses power.

### Added

- The remote is picked up again without a menu tap. A 5 s timer compares
  `/proc/bus/input/devices` against the descriptor being held and reconciles
  the two: it opens the remote when it appears or its event number moves, and
  drops the handle when it goes away. Until now every recovery needed *Refresh
  Device Input* tapped by hand, because a reconnect gives the `uhid` device
  whatever event number happens to be free while KOReader carries on reading
  the old one. The timer is scheduled once per process and stays quiet — it
  logs rather than popping up messages, since an `InfoMessage` fired from a
  timer would interrupt reading.

- The remote reconnects on its own. BlueZ won't re-dial an LE peripheral, so
  when the watcher finds no input device it runs `connect.sh --no-repair`,
  at most once a minute, in the background — no message on screen, and a tap
  cancels it rather than being swallowed. Measured on the Sage at roughly seven
  seconds from a dropped link to a working remote, with nothing touched.
  `--no-repair` is a new branch that reports an incomplete bond instead of
  handing over to `repair.sh`: an unattended process must never run
  `bluetoothctl remove`, because a re-pair that then failed would leave the
  remote worse off than it started. Recovering a lost bond stays a menu tap.

### Fixed

- *Reconnect to Device* could destroy a perfectly good bond. The check for
  `Paired: yes` ran immediately after `bluetoothctl connect`, which returns as
  soon as the link is up with encryption still in flight — so a bond that was
  about to be fine read as incomplete, and the re-pair handover removed and
  rebuilt it for nothing. The bond is now polled until it settles. Only the
  link-up-but-unbonded case is waited on; when the link itself isn't up there
  is nothing in flight, and retrying just burns 5 s timeouts against a remote
  that isn't answering.

### Changed

- The scripts no longer block the reader. Every menu action runs its script
  through `Trapper:dismissablePopen()` inside a coroutine, so the 15-20 second
  pair-and-connect leaves KOReader usable instead of frozen — you can turn
  pages or open a book while it works, and the progress message can be
  dismissed. `showBusy()` and its forced repaint are gone; Trapper builds the
  widget itself. Dismissing is now a distinct outcome rather than a failure:
  the script keeps running and can't be called back, so reporting an error
  that hasn't happened would be worse than staying quiet.
- Each handler wraps itself rather than being wrapped at the menu callback, so
  actions bound to a gesture get the same treatment as a menu tap. Turning
  Bluetooth on still chains into a re-pair, and the two share one coroutine
  instead of nesting.

### Documented

- The `Connected: yes` / `Paired: no` state has a cause: **the remote discards
  its bond when it loses power.** It re-advertises unbonded, BlueZ offers the
  stored key, the remote rejects it, and bonding fails with HCI status `0x05`
  while the LE link stays up. The self-healing reconnect added in v1.1.0 is
  therefore the correct fix rather than a workaround — a bond the peripheral
  has thrown away cannot be recovered, only replaced.
- Adding HOGP to `[Policy] ReconnectUUIDs` **does not work** and has been
  abandoned. BlueZ's policy plugin reconnects by calling a profile's `connect`
  method; LE profiles like HoG don't have one, so the attempt fails with
  `Operation not supported`. Getting the link back automatically will have to
  come from this plugin, once the scripts no longer block the UI thread.

## v1.1.0 — 2026-07-25 — Reconnects that survive a moving event number

Everything that broke when the remote came back. The input device is resolved
at runtime instead of assumed, the old handle is closed before reopening so a
device recreated on the same event number can't leave the remote connected but
dead, and *Reconnect to Device* now re-pairs itself when the bond returns
incomplete. Confirmed on the Sage.

### Added

- *Reconnect to Device* is self-healing. A reconnect can land in
  `Connected: yes` / `Paired: no` — the remote comes back without re-bonding,
  BlueZ resolves GAP/GATT but the HID characteristics stay inaccessible, and no
  input device is ever created. The connect reports success either way, so
  `connect.sh` now checks the bond separately and hands over to `repair.sh` when
  it's incomplete. Recovering no longer depends on knowing which menu item to
  pick. The first connect's output is captured rather than printed, so its
  "Connection successful" can't be mistaken for overall success when the
  re-pair path is taken.

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
- `onBluetoothOff()` closes the input device before tearing down the stack. It
  was the one path that didn't go through `refreshPairing()`, so it left a
  handle open against a device that no longer existed until the next connect.

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
