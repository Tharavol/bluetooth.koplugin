# Kobo Sage + Kobo Remote / Hanlinyue Free3 + KOReader — technical handoff

How the plugin works today, the hardware facts it rests on, and what is still
open. How it got here — the fixes along the way, the dead ends and the bugs
worth remembering — is in [`HISTORY.md`](HISTORY.md).

Base: [CarloDePieri/bluetooth.koplugin](https://github.com/CarloDePieri/bluetooth.koplugin),
itself a fork of [onatbas/bluetooth.koplugin](https://github.com/onatbas/bluetooth.koplugin).

> Throughout, `AA:BB:CC:DD:EE:FF` stands in for your remote's Bluetooth
> address — get the real one from `bluetoothctl devices` while scanning.
> Bluetooth SIG UUIDs (`00001812-…` etc.) are universal constants and are
> quoted verbatim.

---

## 1. Hardware and platform facts

| Fact | How confirmed |
|---|---|
| BT/WiFi chip is **Realtek RTL8821CS** | `dmesg` shows `RTW:`/`rtl8821c_fillh2ccmd` lines; the Wi-Fi module is `8821cs`; `hciconfig hci0 version` reports `Manufacturer: Realtek Semiconductor Corporation (93)`, HCI/LMP 4.1, bus UART. `rtk_hciattach`'s log prints `IC: RTL8821CS` — but only once it exits: it buffers its output, so `/var/log/rtk_hciattach.log` is **empty while it runs** |
| BT is UART-attached on `/dev/ttyS1`, H5 (three-wire) protocol | Nickel runs `/sbin/rtk_hciattach -n -s 115200 /dev/ttyS1 rtk_h5` |
| WiFi driver module is `8821cs` | `/sys/module/8821cs/parameters/rtw_btcoex_enable` exists. KOReader unloads it with Wi-Fi |
| **Bluetooth needs Wi-Fi on** (#42) | KOReader's `disable-wifi.sh` runs `rmmod 8821cs`, then `ntx_io` ioctl 208 (`CM_WIFI_CTRL`) with 0, cutting the whole chip's power — the Sage has no `sdio_wifi_pwr` module. The Free3 dropped the moment Wi-Fi went off, while `hci0` still read `UP RUNNING` and its input device stayed listed: nothing on the Kobo side noticed (2026-09-25) |
| **Turning Wi-Fi on resets Bluetooth too** | `enable-wifi.sh` powers the chip (208, 1) and loads `8821cs`; the Free3 dropped 8 s after `Kobo Wi-Fi: enabling Wi-Fi` |
| Chip reset line exists in devicetree as node `bt` | `/sys/firmware/devicetree/base/bt/bt_rst_n` |
| Power/reset is gated through rfkill | `/sys/devices/platform/bt/rfkill/rfkill0/state` — write `1` to unblock, `0` to block |
| `uhid` is **built into the kernel**, not a module | `zcat /proc/config.gz \| grep CONFIG_UHID` → `CONFIG_UHID=y` (so `lsmod` shows nothing; this is expected, not a fault) |
| BlueZ version 5.63, config at `/etc/bluetooth/main.conf` | `bluetoothd -n -d` startup banner |
| `bluetoothd` binary lives at `/libexec/bluetooth/bluetoothd` (note: **not** `/usr/libexec/...`) | `find / -name bluetoothd` |
| BlueZ `input` and `hog` plugins are present and enabled | `bluetoothd -d` logs `add_plugin() Loading input plugin` / `Loading hog plugin` |
| KOReader runs as **two** luajit processes (parent + child) | Normal on this build — confirmed present on a clean reboot |
| BlueZ stores bonds under **`/var/db/bluetooth/<adapter>/<device>/`**, not `/var/lib/bluetooth` | `bluetoothd -d` logs `store_device_info_cb() Unable set contents for /var/db/bluetooth/…` |
| Rootfs is `/dev/mmcblk0p1`, **282 MB and ships nearly full** (~250 MB of it firmware under `/usr`) | `df -h /`, `du -skx /*` |
| `/var/lib`, `/var/log`, `/var/run` are **tiny tmpfs mounts** (16k, 16k, 128k) | `/proc/mounts` |
| The reconnect policy plugin **cannot drive an LE reconnect** | `policy.c:reconnect_timeout() Reconnecting services failed: Operation not supported (95)` |
| A silent link is dropped after **20 s** | A Free3 switched off stays `Connected: yes`, with its ACL link and input device, for 20 s, then all three go at once. Measured with a once-a-second `bluetoothctl info` / `hcitool con` / `/proc/bus/input/devices` loop, 2026-09-25 |
| `Trapper` is available, with `wrap`, `info`, `dismissablePopen`, `dismissableRunInSubprocess` | `grep "^function Trapper:" frontend/ui/trapper.lua` |
| KOReader on the Sage is **v2026.03** | `cat /mnt/onboard/.adds/koreader/git-rev` |
| A script's **stderr lands in `crash.log`** | KOReader's stdout/stderr go to `crash.log`, and `io.popen` children inherit stderr |
| `/bin/l2ping` and `hcitool` exist | `which`. Neither can test whether the Free3 is really there: see its entry below |

### The Kobo Remote

- Name `Kobo Remote`, public address.
- **BLE (HID-over-GATT / HOGP)**, not classic Bluetooth HID — advertises UUID
  `00001812-0000-1000-8000-00805f9b34fb`.
- Lands on `/dev/input/eventN` via `uhid` once connected **and bonded**.
  `N` is **not stable** across reconnects (seen as event3, event4, …).
- Creates **two** identically named uhid input devices on every fresh pairing,
  only one of which delivers events (§3.4).
- Sends `MSC_SCAN` `0x70051` (forward) and `0x70052` (back): the HID usages
  Keyboard Down Arrow and Up Arrow. No `EV_KEY`.
- Sends each button's code **twice per press: once at press, once at release**
  (4–200 ms later for a tap). While held it sends only empty reports (a bare
  `SYN_REPORT`) every ~37 ms — visible in `evtest`, but they never reach
  KOReader's event hook — then the second code when released, however long
  that takes. Measured with `evtest`, 2026-09-24.
- **Discards its bond when it loses power.** Pull the battery and it comes back
  advertising as unbonded while BlueZ still holds the key. See §4.
- Stays connectable for a while after a software `disconnect` — a plain
  `bluetoothctl connect` brings it straight back, no keypress needed. After a
  power cycle it has to be woken with a button press first.

### The Hanlinyue Free3

Confirmed on the Sage with `bluetoothctl info`, `/proc/bus/input/devices`,
`evtest` and `hcitool con`, 2026-09-23/25.

- A side switch selects one of three Bluetooth identities: `Free3-R`,
  `Free3-M`, `Free3-P`. The plugin uses **`Free3-P`**, which is why names are
  matched exactly — the three share a prefix.
- **Classic Bluetooth HID** (UUID `00001124-…`, `LegacyPairing: yes`), not BLE.
  The input device is created by the kernel's HIDP driver under `hci0`, not by
  uhid. **One** input device, named exactly `Free3-P`.
- **Keeps its bond through power-offs.** No re-pair is needed after switching
  it off and on.
- **Doesn't reconnect by itself** when switched on. Every return seen on the
  Sage was the plugin's `connect.sh` dialling it (§3.4).
- **Won't take a connection for about 45 s after being dropped.** When a
  re-pair drops a connected Free3, its light starts blinking about 14 s later
  and it shows up in a scan, but for the next ~30 s every page from the Kobo
  goes unanswered (`ConnectionAttemptFailed`; `hcitool con` shows the Kobo's
  outgoing link stuck connecting for 5 s at a time). Then it pages the Kobo
  itself, and from then on connects and bonds normally. A Free3 switched off
  first, then on while RePair was scanning, paired without trouble.
- **Answers neither `l2ping` nor `hcitool name`** over a working link, so
  neither can tell a live Free3 from one switched off within the last 20 s.
  `l2ping` also exits 0 at 100% loss.
- Sends **only `MSC_SCAN`**, no `EV_KEY`. Each press sends its code twice, both
  at press, 18–40 ms apart, and nothing at release or while held — no
  auto-repeat. A fast double-tap puts presses ~140 ms apart.
- Its modes (cycled with the side On key) send, top/middle/bottom key:

  | Mode | Codes |
  |---|---|
  | Up and Down | `70052` Up Arrow / `70051` Down Arrow / `7002c` Spacebar |
  | Volume | `c00e9` Volume Up / `c00ea` Volume Down / `7002c` Spacebar |

  Up and Down Mode sends exactly the Kobo Remote's codes, so no new mapping was
  needed. The bottom key's Spacebar is the "third button" (§3.4).

---

## 2. Why the upstream plugin does not work on the Sage

The upstream `on.sh` (and CarloDePieri's fork) assume a **Broadcom** chip:

```sh
/sbin/hciattach /dev/ttyS1 bcm43xx 1500000 flow -t 20 -b bcm43xx_init
```

On the Sage this always ends in `bcm43xx_init / Initialization timed out`,
because the Broadcom UART handshake is being spoken to a Realtek part. No
`hci0` is ever created, so every step after it fails (`no default controller`
in the plugin's UI). The parent's `connect.sh` / `repair.sh` also hardcoded a
`grep` for its author's `Q36` controller.

---

## 3. How it works

### 3.1 Install location

Folder **must** be named exactly `bluetooth.koplugin`. GitHub's "Download ZIP"
produces `bluetooth.koplugin-main`; KOReader's loader only scans `*.koplugin`,
so a mis-named folder means the plugin silently never loads — no error, nothing
in `crash.log`. The release zip, `bluetooth.koplugin.zip`, is built by the
`Package` workflow when a release is published: the `*.lua` and `*.sh` files,
`device.conf`, `LICENSE`, `DISCLAIMER` and `readme.md`, in a correctly named
folder (#43).

Usual path: `/mnt/onboard/.adds/koreader/plugins/bluetooth.koplugin/`. Any
KOReader plugins folder works: `main.lua` takes its own directory from where
the loader found it (`debug.getinfo`, made absolute against KOReader's working
directory when the loader used a relative path), and passes it, quoted, to
every script (#36).

`_meta.lua` gives the plugin manager a name and description, and is what the
loader runs in place of `main.lua` while the plugin is disabled. Its `name`,
and `main.lua`'s, must be the folder name without `.koplugin`: the manager
records a disabled plugin under `name`, and the loader looks it up under the
folder name (#41).

Copy the whole folder when upgrading: `connect.sh` and `repair.sh` source
`lib.sh`.

### 3.2 Bringing the stack up and down: `on.sh`, `off.sh`

`on.sh` runs `bring_up` — kill the old daemons, power-cycle the chip through
rfkill, attach it with `rtk_hciattach`, bring `hci0` up, start `bluetoothd` —
and, if `hci0` is not `UP RUNNING` at the end, runs it once more (#49). It
prints `complete` or `Error: hci0 did not come up - see crash.log`. Each
requirement below was learned on the device; the comments in `on.sh` say where.

1. **`rtk_hciattach`, not `hciattach bcm43xx`** (§2). It is a *resident*
   process: H5 needs something servicing the link continuously.
2. **Its output goes to a file.** Backgrounded with `&`, it still inherits the
   script's stdout, and the plugin reads that to EOF — so the pipe never
   closes and KOReader's UI thread hangs forever. Looked exactly like a crash.
3. **`setsid` for `bluetoothd`.** Started with a plain `&`, it dies with the
   session.
4. **`cd /` first.** Both daemons inherit the script's working directory; left
   on `/mnt/onboard`, they hold the user partition busy and USB mass storage
   refuses to start (#44).
5. **An rfkill power-cycle every time.** `hci0` regularly ends up
   attached-but-`DOWN`, and only a full rfkill 0→1 cycle plus a fresh
   `rtk_hciattach` recovers it. Detecting the bad state instead isn't worth it.
   The cost: turning Bluetooth on always drops any existing connection.
6. **Wait for the old daemons to exit.** `killall` only signals, and the old
   `rtk_hciattach` restores the serial line's discipline as it exits — which
   detaches a new one that has already attached.
7. **Hold the radio off 4 s if it was on**, 1 s if it was off. A chip that was
   running fails the H5 sync after 1 s off.
8. **Poll, don't sleep.** Up to 10 s for `hci0` to appear (the attach syncs at
   115200, downloads firmware and switches to 1.5 Mbaud), then up to 5 s after
   `bluetoothd` starts for it to be `UP RUNNING`. The check belongs after
   `bluetoothd`, which is what powers the controller.
9. **No `bluetoothd -d`.** `/var/log` is a 16 KB tmpfs (§5).

A failed attempt writes `hciconfig hci0` and the attach log to `crash.log`,
tagged `[bluetooth]`, stopping `rtk_hciattach` first since it only writes its
log on exit.

`off.sh` takes `hci0` down, kills both daemons, waits up to 3 s for them to
exit (it runs synchronously at suspend, so the wait is capped), blocks the
radio, and prints `off`.

### 3.3 The remote scripts: `device.conf`, `lib.sh`, `connect.sh`, `repair.sh`

**`device.conf`** lists the remotes, in order of preference:
`BT_DEVICE_NAMES="Free3-P|Kobo Remote"`. An older single `BT_DEVICE_NAME`
still works, and with no `device.conf` at all both remotes are used. `lib.sh`
sources it; `main.lua` parses it **the way sh reads it** — comment lines
skipped, last assignment wins — so the two can't disagree.

**`lib.sh`** holds the shared helpers:

- `bltctl` — `bluetoothctl` capped at 5 s; `bltctl_for SECONDS` for calls that
  need longer. `bluetoothctl` exits when its call completes, so a limit costs
  nothing when the call is quick. `scan on` is the exception: discovery belongs
  to that `bluetoothctl` process, so a scan lasts exactly as long as its limit.
- `diag` — sends `bluetoothctl`'s output to stderr, and so to `crash.log`,
  tagged `[bluetooth]`. **stdout is for outcomes only**: whatever a script
  prints there is what the user sees in a popup.
- `device_macs NAME` — every known device named **exactly** NAME, from
  `bluetoothctl devices`.
- `wait_powered yes|no`, `wait_for_bond ADDRESS [TRIES]` — poll instead of
  sleeping. `wait_for_bond` succeeds once `Paired: yes` **and**
  `Connected: yes` both hold. It polls because `connect` returns with
  encryption still in flight, so an immediate read says `Paired: no` for a
  bond that is about to be fine. It gives up early when the link isn't up,
  since nothing is in flight then.

**`connect.sh [--no-repair] [NAMES]`** is the quick path. It checks that
`hci0` is `UP RUNNING` first, and otherwise prints `The Bluetooth controller is
not responding. Toggle Bluetooth off and on.` — the one state only `on.sh` can
fix (§3.4, suspend). Then, for each listed remote in order (or just `NAMES`),
skipping any never paired:

1. `bluetoothctl connect`, output **captured, not printed**, so its own
   `Connection successful` can't pass for ours.
2. `wait_for_bond`. On success print `Remote: <name>` and
   `Connection successful`, and stop.
3. Link up but no bond — the Kobo Remote after a battery change (§4):
   remember it and carry on down the list. If nothing else connects,
   `exec repair.sh` for it.

With **`--no-repair`**, which the unattended reconnect always passes, step 3
reports instead of re-pairing: a background process must never run
`bluetoothctl remove`, because a re-pair that then failed would leave the
remote worse off.

**`repair.sh [NAME]`** re-pairs one remote: the one named, or the first
listed. It is destructive — `remove` throws the old bond away — which is why
the menu's RePair is a submenu with one entry per remote.

1. **A working remote is left alone.** If it is connected, bonded and its
   input device is listed, the script says so (`Already connected`) and
   removes nothing. Re-pairing a working Free3 costs ~45 s (§1). A remote
   switched off within the last 20 s still counts as connected (§1), so the
   popup says to wait 20 s before forcing a re-pair.
2. Cycle the controller's power, then `remove` every entry with the name.
3. **Find and pair, for up to 90 s.** Scan in 4 s rounds until the remote is
   listed; pair (20 s limit — the Free3 takes more than 5); on failure, wait
   2 s and try again, scanning again first if BlueZ has dropped the device,
   which it does after a failed pair. A bond the remote formed from its own
   side in the meantime counts as success. No power cycles between attempts:
   they didn't help, and could miss the Free3's own page.
4. `trust`, `connect`, then `wait_for_bond` with 10 tries. Success prints
   `Remote: <name>` and `Connection successful`; failure prints the first
   `bluetoothctl` error (`first_error`) and the bond state.

`main.lua` keys off the literal strings `Connection successful`,
`Remote: <name>`, `Already connected`, `complete` and
`controller is not responding`, so anything touching the scripts has to
preserve them.

**`info.sh`** is read-only: the controller from `hciconfig hci0 version`
(needs Bluetooth on), the chip from the `8821cs` Wi-Fi module's name (needs
Wi-Fi on), and the BlueZ version.

### 3.4 The Lua side

`main.lua` holds the plugin class, its menu and its handlers. The rest is in
sibling modules, which the loader's `package.path` lets it `require` (#56):

| Module | Holds |
|---|---|
| `bluetooth_config` | the plugin directory, the remotes' names from `device.conf`, setting keys |
| `bluetooth_buttons` | the event-adjust hook and press pairing |
| `bluetooth_stack` | running the scripts (`Stack.run`), whether Bluetooth and Wi-Fi are up |
| `bluetooth_input` | finding, opening and closing the remotes' input devices |
| `bluetooth_watcher` | the watcher, the unattended reconnect, starting Bluetooth in the background |

The `bluetooth_` prefix is deliberate: `require` caches modules by name for the
whole process, across every plugin. A `require`d module is also loaded once per
process, which is what the state below wants — KOReader instantiates the plugin
once for FileManager and again for ReaderUI.

**Page turns: the event-adjust hook.** Both remotes emit **only**
`EV_MSC`/`MSC_SCAN`; the kernel never synthesises a matching `EV_KEY`, and the
usual fix, a udev hwdb rule, isn't available on this firmware. So
`bluetooth_buttons` registers one `Device.input:registerEventAdjustHook` and dispatches
`GotoViewRel ±1` itself for `0x70051`/`0x70052`, and the third button's
actions for `0x7002c`. It is registered **once per process**, behind a
flag: KOReader instantiates the plugin once for FileManager and
again for ReaderUI, and hooks chain rather than replace, so two registrations
meant two page turns per press. Its state is module-level for the same reason.

**Press pairing (#31).** Both remotes send each press's code exactly twice
(§1), so a press acts on its first code and swallows its second
(`pending` in `bluetooth_buttons`), however long the second takes — a held Kobo Remote button
sends it only on release. A 30 s backstop (`PAIR_GAP`) abandons a pair
whose second code never came, and the pairing resets whenever a remote's input
device opens or closes, since a dropped link is when a code goes missing.
Getting out of step would make every later press act on release. The hook
also honours **Invert page-turn buttons**, read on every press.

**Input devices.** `Input.find()` reads every `N: Name="…"` block for a
listed remote out of `/proc/bus/input/devices` and takes its `H: Handlers=`
event node, and reports which remotes are present. Four traps:

- **There can be more than one.** The Kobo Remote shows up as two identically
  named uhid devices, only one of which delivers events. Every match is
  opened; a silent one costs nothing.
- **`/proc` and `/dev/input` are not in sync.** The kernel lists the device
  before `udevd` creates the node. `Input.waitFor()` polls, yielding
  between tries, until every listed node opens (#33).
- **The same path can be a different device.** A reconnect can recreate the
  device on the same event number, so a descriptor held across it is dead.
  Close before opening, even when the path is unchanged.
- **Closing a vanished device can close a live one** (#48). KOReader's input
  backend closes a vanished device's fd itself but keeps the `path → fd` entry
  in `Input.opened_devices`; the number is then reused. `closePath`
  checks `readlink("/proc/self/fd/<fd>")` (declared through the FFI) against
  the path, and only clears the entry if it no longer matches.

`Input.openPaths()` is what is open.

**The watcher.** A `UIManager:scheduleIn` tick every 5 s, scheduled once per
process, reconciles `Input.find()` with what is open, path by path:
opens what is new, closes what has gone, leaves the rest alone. It logs rather
than pops up — a popup from a timer would interrupt reading.

**Unattended reconnect.** BlueZ will not re-dial an LE peripheral (the
`ReconnectUUIDs` row in [HISTORY's dead ends](HISTORY.md#dead-ends)), and the Free3 doesn't come back by itself, so the watcher runs
`connect.sh --no-repair` itself. It dials **the remotes listed ahead of the
best one present**: every remote when none is connected, the Free3 alone while
only the Kobo Remote is. Misses in that second case are debug-logged only.

- **Pace:** every 60 s, but every 10 s for the **two minutes after Bluetooth
  comes up** — startup, waking, a restart or a toggle — when a remote is most
  likely to be switched on.
- **No overlap.** An attempt against unreachable remotes can outlast 10 s, so
  a new one waits for the last (`reconnect_running_since`).
- **It stands aside** while `on.sh` runs (`START_GRACE`, 40 s at most),
  since `hci0` appears partway through and a connect then races the daemon
  restart; and while a menu **Reconnect** or **RePair** runs (`Watcher.beginManual`,
  180 s at most), which also waits for an attempt already under way. An
  unattended connect in the middle of a RePair left the Free3 unbonded.
- All three guards are **timestamps, not flags**, so a run that never reports
  back can't disable reconnection for the session.
- **A dead controller** (`controller is not responding`) triggers a background
  `on.sh`, at most once per 5 minutes.

**Nothing blocks the UI thread.** Scripts run through
`Trapper:dismissablePopen(cmd, message)`, which returns **`completed,
output`** — callers must take both; binding one variable gets the boolean, and
the error it causes vanishes inside `Trapper:wrap`'s `pcall`. Each handler
wraps itself (`if not Trapper:isWrapped() then return Trapper:wrap(…) end`),
which covers the Dispatcher entry points too. Outside a wrap, Trapper falls
back to a blocking `io.popen`, so a missed wrap shows up only as a freeze.

- **Background runs** pass Trapper **an unshown table** as the trap widget
  (`Stack.BACKGROUND()`): nothing can dismiss it, and taps go to the reader.
  Trapper's own invisible widget (`true` or `false`) is dismissed by any tap
  (#30).
- **Scripts write their output once, at exit** (#47). `dismissablePopen`
  treats a run as finished once `FIONREAD` reports bytes, then does a
  **blocking** `read("*all")` on the UI thread. So `Stack.run` runs every
  script as `out=$(/bin/sh <script>); printf '%s\n' "$out"`.

**Startup.** *Turn on Bluetooth at startup* (on unless unticked) runs `on.sh`
in the background 3 s after KOReader starts, once per process, unless
Bluetooth is already up. The watcher connects afterwards. It isn't gated on
Wi-Fi, unlike the Toggle entry.

**Wi-Fi (#42).** *Toggle Bluetooth* turning it on requires Wi-Fi to be on,
since Wi-Fi powers the chip (§1). "On" is KOReader's own test,
`NetworkMgr:isWifiOn()` — on a Kobo, whether the Wi-Fi interface exists. It
used to grep `iwconfig` for `ESSID`, which matches `ESSID:off/any` too.

**Suspend and resume (#29).** Left on across a suspend, the serial link to the
chip died: `hci0` DOWN, `retransmitting` in `dmesg`, `org.bluez.Error.Busy`
from every call. So `onSuspend` closes the inputs and runs `off.sh`
**synchronously** (the Kobo sleeps as soon as the handlers return), and
`onResume` brings Bluetooth back in the background a second later, which
starts the fast reconnect window. The way KOReader treats Wi-Fi. Confirmed
across a night's sleep.

**Third button.** The Free3's `0x7002c` runs a Dispatcher action list stored
in `G_reader_settings` (`bluetooth_button_actions.third`), edited through
`Dispatcher:addSubMenu` — the gestures picker — and flushed in
`onFlushSettings`. It runs on `UIManager:nextTick`, not inside the hook.

**Menu placement.** Bluetooth sits on the settings tab directly below Network.
A `sorting_hint` can only append, so the plugin inserts `"bluetooth"` after
`"network"` in `ui/elements/reader_menu_order` and `…/filemanager_menu_order`,
which `require` caches. Checked against v2026.03's `menusorter.lua`.

**Strings** go through `T(_("… %1"), x)` (`ffi/util`'s `template`), so
translators get whole sentences.

---

## 4. The `Connected: yes` / `Paired: no` state

The Kobo Remote reports connected, `bluetoothctl` looks healthy, and **no input
device is ever created**. The remote **discards its bond when it loses power**:

1. Battery pull — the remote throws away its bond.
2. It re-advertises as an unbonded device.
3. BlueZ still holds the LTK, connects, and offers it.
4. The remote rejects a key it no longer has.
5. Bonding fails — `bonding_attempt_complete() … status 0x5`, HCI
   **authentication failure** — so BlueZ clears `Paired`, **but the LE link
   stays up**.

The HID characteristics need an encrypted link, so HoG never reads the report
map and no uhid device appears. A bond the peripheral has thrown away can only
be replaced, which is why the menu's Reconnect hands this state to
`repair.sh`. Confirmed from `bluetoothd` debug logs.

A second cause of pairings that "never quite stick": if `/` is full, BlueZ
cannot persist bonds at all. Check `df -h /` first.

---

## 5. Open issues

1. **The Kobo Remote forgets its bond on power loss** (§4). Nothing to be done
   beyond re-pairing. Listed because it explains most "flaky" reports.
2. **Why the Kobo Remote gets two input devices** is not established.
3. **Press pairing assumes exactly two codes per press**, true of both remotes
   as measured. A remote sending one code per press would turn a page only on
   every other press.
4. **A forced RePair right after switching a Free3 off** finds it still
   connected for 20 s (§1). The popup says to wait; there is no live test
   that would tell sooner.
5. **What is open is per-process** (`Input.openPaths()`), so it is empty after a KOReader
   restart. Harmless, and a tell in logs: a `watcher opened` line for a path
   already open, with no `closing` in between, means KOReader restarted.
6. **`/var/log` is a 16 KB tmpfs**, so a conclusion drawn from something being
   *absent* there is unsafe. Start a debug daemon by hand, logging somewhere
   with room (§6).
7. **The four `[General]` lines of `main.conf` are gone**, destroyed by
   `sed -i` on a full disk. Everything has worked on BlueZ defaults since. If a
   pristine copy turns up in a firmware package, worth diffing.
8. **Turning Wi-Fi off or on drops the remote** (§1), and nothing on the Kobo
   side reports it, so the plugin doesn't react either. Turn Bluetooth off
   and on after changing Wi-Fi. Running Bluetooth with Wi-Fi off was tried and
   dropped: see [HISTORY](HISTORY.md#dead-ends).
9. The v1.7.0 milestone holds the tests in CI.

---

## 6. Tests and useful commands

`tests/run.sh` checks transcripts against `tests/expected/` (see the readme).
`tests/lua/env.lua` is a fake KOReader — clock and timers, sysfs and `/proc`,
input devices, Trapper, settings, the UI — and `tests/lua/scenarios.lua`
drives the plugin through it, including replays of the `evtest` captures in
`tests/fixtures/`. `tests/sh/stubs.sh` is a fake Kobo for the scripts:
`bluetoothctl`, `hciconfig`, the daemons and the clock as shell functions,
with the device's state in files. `tests/sh/scenarios.sh` runs test copies of
the scripts, changed only to point absolute paths into a fake root, to run
`on.sh`'s background launches in the foreground, and to hand over from
`connect.sh` to `repair.sh` in the same shell. The fakes encode what was
measured on the Sage — a 5 s page timeout, a killed `rtk_hciattach` taking
`hci0` with it, a buffered attach log — and are no better than that.


```sh
# stack health, top to bottom
hciconfig hci0                       # want: UP RUNNING
ps aux | grep -i rtk_hciattach
ps aux | grep -i bluetoothd
bluetoothctl show                    # want: Powered: yes
bluetoothctl info AA:BB:CC:DD:EE:FF  # want: Paired: yes AND Connected: yes
cat /proc/bus/input/devices          # find a remote's eventN
df -h /                              # BlueZ cannot persist bonds on a full /

# what the plugin is doing (INFO level, no debug flag needed), without the
# advertising chatter of every device in range
grep -E "Bluetooth:|\[bluetooth\]" /mnt/onboard/.adds/koreader/crash.log |
    grep -v "Device [0-9A-F:]* [0-9A-F-]*$" |
    grep -v "RSSI\|TxPower\|ManufacturerData\|ServiceData\|^\[bluetooth\]   " |
    tail -80

# the Kobo's Bluetooth links, once a second: < outgoing, > incoming;
# state 5 = still connecting, state 1 = connected
while true; do echo "$(date +%T) $(hcitool con | tail -n +2 | tr '\n' ' ')"; sleep 1; done

# which input devices KOReader holds open -- the remote's should come and go
pid=$(ps | grep '[r]eader.lua' | awk '{print $1}' | head -1)
ls -l /proc/$pid/fd | grep event

# run the connect path by hand, exactly as the plugin does.
# --no-repair can never reach repair.sh, so this is safe to poke at
time /bin/sh /mnt/onboard/.adds/koreader/plugins/bluetooth.koplugin/connect.sh --no-repair

# restart the stack by hand, with the output on screen
sh /mnt/onboard/.adds/koreader/plugins/bluetooth.koplugin/on.sh; echo "exit $?"

# raw button codes as the kernel sees them
evtest /dev/input/eventN

# bluetoothd with debug logging.
# NOT into /var/log -- that is a 16 KB tmpfs and debug output overruns it in
# seconds. Restarting bluetoothd alone picks up a main.conf change; the
# controller stays attached.
killall bluetoothd
setsid /libexec/bluetooth/bluetoothd -n -d > /mnt/onboard/bluetoothd.log 2>&1 &
sleep 2 && bluetoothctl power on     # a fresh daemon comes up powered down

# KOReader restart from SSH (wrapper respawns it)
ps aux | grep -i luajit
kill -9 <parent-pid>
```

Gotchas: KOReader's SSH server is a plugin, so exiting KOReader kills your own
shell. **"Developer options" only appears in the File Manager's Tools → More
tools menu**, not in the reader. And check `command -v bluetoothctl` when a
result is surprisingly empty — a mock left on `PATH` once poisoned three rounds
of diagnosis.

---

## 7. Community

Nothing found documenting a Realtek-chip Sage working with the official BLE
remote through any of these plugins. Worth reporting to:

- MobileRead thread: <https://www.mobileread.com/forums/showthread.php?t=362986>
- <https://github.com/CarloDePieri/bluetooth.koplugin/issues>

Neither `onatbas` nor `OGKevin`'s plugin lists the Sage as supported; both
target i.MX6 (`bluetoothctl`/`hciattach`) or MTK (D-Bus) Kobos.
`tsowell/kobo-btpt` is Libra 2 only. `sublipri/kobo-wifi-remote` *is* tested on
a Sage but works over WiFi rather than direct BLE.
