# Kobo Sage + Kobo Remote / Hanlinyue Free3 + KOReader — technical handoff

Context transfer document. Describes hardware findings, the working
configuration, every dead end tried (and why it failed), and open issues.

Base: [CarloDePieri/bluetooth.koplugin](https://github.com/CarloDePieri/bluetooth.koplugin),
itself a fork of [onatbas/bluetooth.koplugin](https://github.com/onatbas/bluetooth.koplugin).

> Throughout, `AA:BB:CC:DD:EE:FF` stands in for your remote's Bluetooth
> address — get the real one from `bluetoothctl devices` while scanning.
> Bluetooth SIG UUIDs (`00001812-…` etc.) are universal constants and are
> quoted verbatim.

---

## 1. Hardware / platform facts established

| Fact | How confirmed |
|---|---|
| BT/WiFi chip is **Realtek RTL8821CS** | `dmesg` shows `RTW:`/`rtl8821c_fillh2ccmd` lines; `rtk_hciattach` init log prints `IC: RTL8821CS` |
| BT is UART-attached on `/dev/ttyS1`, H5 (three-wire) protocol | Nickel runs `/sbin/rtk_hciattach -n -s 115200 /dev/ttyS1 rtk_h5` |
| WiFi driver module is `8821cs` | `/sys/module/8821cs/parameters/rtw_btcoex_enable` exists |
| Chip reset line exists in devicetree as node `bt` | `/sys/firmware/devicetree/base/bt/bt_rst_n` |
| Power/reset is gated through rfkill | `/sys/devices/platform/bt/rfkill/rfkill0/state` — write `1` to unblock, `0` to block |
| `uhid` is **built into the kernel**, not a module | `zcat /proc/config.gz \| grep CONFIG_UHID` → `CONFIG_UHID=y` (so `lsmod` shows nothing; this is expected, not a fault) |
| BlueZ version 5.63, config at `/etc/bluetooth/main.conf` | `bluetoothd -n -d` startup banner |
| `bluetoothd` binary lives at `/libexec/bluetooth/bluetoothd` (note: **not** `/usr/libexec/...`) | `find / -name bluetoothd` |
| BlueZ `input` and `hog` plugins are present and enabled | `bluetoothd -d` logs `add_plugin() Loading input plugin` / `Loading hog plugin` |
| KOReader runs as **two** luajit processes (parent + child) | Normal on this build — confirmed present on a clean reboot, not an artifact of our kills |
| BlueZ stores bonds under **`/var/db/bluetooth/<adapter>/<device>/`**, not `/var/lib/bluetooth` | `bluetoothd -d` logs `store_device_info_cb() Unable set contents for /var/db/bluetooth/…` |
| Rootfs is `/dev/mmcblk0p1`, **282 MB and ships nearly full** (~250 MB of it firmware under `/usr`) | `df -h /`, `du -skx /*` |
| `/var/lib`, `/var/log`, `/var/run` are **tiny tmpfs mounts** (16k, 16k, 128k) | `/proc/mounts` |
| The reconnect policy plugin **cannot drive an LE reconnect** | `policy.c:reconnect_timeout() Reconnecting services failed: Operation not supported (95)` |
| `Trapper` is available, with `wrap`, `info`, `dismissablePopen`, `dismissableRunInSubprocess` | `grep "^function Trapper:" frontend/ui/trapper.lua` |
| KOReader on the Sage is **v2026.03** | `cat /mnt/onboard/.adds/koreader/git-rev` |
| A script's **stderr lands in `crash.log`** | KOReader's stdout/stderr go to `crash.log`, and `io.popen` children inherit stderr; `iwconfig`'s `no wireless extensions` lines appear there |

### The remote itself

- Name `Kobo Remote`, MAC `AA:BB:CC:DD:EE:FF`, public address.
- **BLE (HID-over-GATT / HOGP)**, not classic Bluetooth HID — advertises UUID
  `00001812-0000-1000-8000-00805f9b34fb`.
- Presents as a media-key style keyboard. Its evdev modalias advertises key
  capabilities including `A3`,`A4` (163/164 = `NextSong`/`PlayPause`).
- Lands on `/dev/input/eventN` via `uhid` once connected **and bonded**.
  `N` is **not stable** across reconnects (seen as event3, event4, …).
- Auto-repeats while a button is held, roughly every 135–200 ms.
- **Discards its bond when it loses power.** Pull the battery and it comes back
  advertising as unbonded while BlueZ still holds the key. See §6.
- Stays connectable for a while after a software `disconnect` — a plain
  `bluetoothctl connect` brings it straight back, no keypress needed. After a
  power cycle it has to be woken with a button press first.
- Creates **two** identically named uhid input devices on every fresh pairing,
  only one of which delivers events (§3.5d).
- Sends `MSC_SCAN` `0x70051` (forward) and `0x70052` (back): the HID usages
  Keyboard Down Arrow and Up Arrow.

### The Hanlinyue Free3

Confirmed on the Sage with `bluetoothctl info`, `/proc/bus/input/devices` and
`evtest`, 2026-09-23/24.

- A side switch selects one of three Bluetooth identities: `Free3-R`,
  `Free3-M`, `Free3-P`. The plugin uses **`Free3-P`**, which is why names are
  matched exactly — the three share a prefix.
- **Classic Bluetooth HID** (UUID `00001124-…`, `LegacyPairing: yes`), not BLE.
  The input device is created by the kernel's HIDP driver under `hci0`, not by
  uhid. **One** input device, named exactly `Free3-P`.
- **Keeps its bond through power-offs.** No re-pair is needed after switching
  it off and on.
- **Doesn't reconnect by itself.** Every return seen on the Sage was the
  plugin's `connect.sh` dialling it, so it depends on the unattended reconnect
  (§3.5f) like the Kobo Remote does.
- Sends **only `MSC_SCAN`**, no `EV_KEY`, like the Kobo Remote. Each press sends
  its code twice, ~30 ms apart (press and release), and nothing more while
  held — no auto-repeat. The 0.5 s debounce makes that one page turn.
- Its modes (cycled with the side On key) send, top/middle/bottom key:

  | Mode | Codes |
  |---|---|
  | Up and Down | `70052` Up Arrow / `70051` Down Arrow / `7002c` Spacebar |
  | Volume | `c00e9` Volume Up / `c00ea` Volume Down / `7002c` Spacebar |

  Up and Down Mode sends exactly the Kobo Remote's codes, so no new mapping was
  needed. The bottom key's Spacebar is the "third button" (§3.5h).

---

## 2. Why the upstream plugin does not work on the Sage

The upstream `on.sh` (and CarloDePieri's fork) assume a **Broadcom** chip:

```sh
/sbin/hciattach /dev/ttyS1 bcm43xx 1500000 flow -t 20 -b bcm43xx_init
```

On the Sage this always ends in `bcm43xx_init / Initialization timed out`,
because the Broadcom UART handshake is being spoken to a Realtek part. No
`hci0` is ever created, so every downstream step fails:

- `dbus-send` to `org.bluez` returns an empty object tree (no adapter).
- `hciconfig hci0 up` → `Can't get device info: No such device`.
- The plugin UI reports `no default controller`.

The fork was hand-tailored to the author's own device — the readme explicitly
says it is unlikely to work as-is for anyone else. `connect.sh` / `repair.sh`
hardcode a `grep` for the author's `Q36` controller.

---

## 3. Working configuration

### 3.1 Install location

Folder **must** be named exactly `bluetooth.koplugin`. GitHub's "Download ZIP"
produces `bluetooth.koplugin-main`; KOReader's loader only scans `*.koplugin`,
so a mis-named folder means the plugin silently never loads — no error, nothing
in `crash.log`. This cost an hour at the start.

Path: `/mnt/onboard/.adds/koreader/plugins/bluetooth.koplugin/`

### 3.2 `on.sh`

```sh
#!/bin/sh
cd /

killall rtk_hciattach 2>/dev/null
killall bluetoothd 2>/dev/null
hciconfig hci0 down 2>/dev/null

echo 0 > /sys/devices/platform/bt/rfkill/rfkill0/state
sleep 1
echo 1 > /sys/devices/platform/bt/rfkill/rfkill0/state

/sbin/rtk_hciattach -n -s 115200 /dev/ttyS1 rtk_h5 > /var/log/rtk_hciattach.log 2>&1 &
sleep 2
hciconfig hci0 up

setsid /libexec/bluetooth/bluetoothd -n > /var/log/bluetoothd.log 2>&1 &
sleep 2

echo "complete"
```

Four non-obvious requirements are encoded here:

1. **Output redirection is mandatory, not cosmetic.** `rtk_hciattach` is a
   *resident* process (H5 needs a process servicing the link continuously —
   unlike a fire-and-forget `hciattach`). Backgrounded with `&` it still
   inherits the script's stdout. The plugin invokes `on.sh` via `io.popen` and
   reads to EOF, so the pipe never closes and **KOReader's UI thread hangs
   forever**. Diagnosed via `/proc/<pid>/wchan` = `pipe_wait`. Looked exactly
   like a crash.
2. **`setsid` for bluetoothd.** Started with a plain `&` from an interactive
   shell it dies with the session. This wasted time repeatedly.
3. **`cd /`, not into the plugin directory.** Both daemons are resident and
   inherit the script's working directory. Left on `/mnt/onboard`, they hold
   the user partition busy, and KOReader's USB mass storage refuses to start
   with `Filesystem is busy! Offending processes: rtk_hciattach, bluetoothd`
   (#44).
4. **Unconditional rfkill power-cycle.** `hci0` regularly ends up
   attached-but-`DOWN`, at which point `hciconfig hci0 up` fails with
   `Connection timed out (110)`. Only a full rfkill 0→1 cycle followed by a
   fresh `rtk_hciattach` recovers it. Doing this every time is cheap insurance;
   trying to detect the bad state was not worth it.

Trade-off: this always tears down, so a "Bluetooth On" toggle drops any
existing pairing/connection and takes a few seconds.

The shipped script wraps the kill → rfkill → attach → `hciconfig hci0 up`
sequence in `bring_up` and, if `hci0` is not `UP RUNNING` afterwards, runs it
**once more** before starting `bluetoothd` (#49). Each failed attempt copies
`/var/log/rtk_hciattach.log` into `crash.log`, tagged `[bluetooth]`, since the
tmpfs copy is overwritten by the next attempt.

### 3.3 `off.sh`

```sh
#!/bin/sh
cd /
hciconfig hci0 down
killall rtk_hciattach
killall bluetoothd
echo 0 > /sys/devices/platform/bt/rfkill/rfkill0/state
```

### 3.4 `repair.sh` / `connect.sh`

The remotes live in `device.conf` as `BT_DEVICE_NAMES="Free3-P|Kobo Remote"`,
in order of preference. `main.lua` parses it, and `lib.sh` sources it; both
scripts source `lib.sh` for their shared helpers. An older single
`BT_DEVICE_NAME` still works. It used to be hardcoded in three places, which is
how an unquoted `grep "$BT_DEVICE_NAME"` got in — unquoted, `grep` reads
`Remote` as a filename and dies.

`main.lua` parses the file **the way sh reads it**: comment lines skipped, last
assignment wins. It used to take the first `BT_DEVICE_NAME="…"` anywhere,
comments included. With the old name kept as a comment above the new one, the
scripts paired the Free3 while `main.lua` kept opening the Kobo Remote.

The name is matched **exactly**, in the scripts (`device_macs` in `lib.sh`,
against `Device <MAC> <name>` from `bluetoothctl devices`) and in `main.lua`
(against `N: Name="<name>"`). A substring match took any device whose name
merely contained the remote's, and two matches became a two-line address.
Where more than one entry has the exact name, the first is used.

`repair.sh [NAME]` is the full `power off/on` → `remove` → `scan` → `pair` →
`trust` → `connect` cycle, for **one** remote: the one named, or the first
listed. It is the only thing that recovers a bond the remote has forgotten,
and it is destructive: `remove` throws away that remote's bond before
rebuilding it. That is why the menu's RePair is a submenu with one entry per
remote. The scan is `timeout 5s bluetoothctl scan on`, measured at the full
5 s. Discovery belongs to that bluetoothctl process and stops when `timeout`
ends it. It therefore judges its outcome the same way
`connect.sh` does (step 2 below, `wait_for_bond` in `lib.sh`): it prints
`Connection successful` only once `Paired: yes` and `Connected: yes` both
hold. Before this it trusted the connect call, which reports success in the
`Paired: no` state.

`connect.sh [--no-repair] [NAMES]` is the quick path. It works through each
listed remote in order (or just `NAMES`, `|`-separated), skipping any that were
never paired, stops at the first with a working bond, and prints
`Remote: <name>` alongside the result. For each one it verifies its own work:

1. `bluetoothctl connect`, output **captured, not printed** — otherwise its
   `Connection successful` leaks through as false success when the re-pair
   path is taken below.
2. Poll `bluetoothctl info` until `Paired: yes` **and** `Connected: yes`, up to
   five tries a second apart. Polling matters: `connect` returns as soon as the
   link is up with encryption still in flight, so an immediate read says
   `Paired: no` for a bond that is about to be fine. The poll gives up early
   when the link itself isn't up, since nothing is in flight then and each
   retry just burns another 5 s timeout.
3. On a good bond, print `Connection successful` explicitly — report on the
   *verified state*, not on the connect call, which can fail while the bond is
   perfectly fine.
4. On a bad bond (link up, not paired), remember it and **carry on down the
   list** — another remote may be fine as it is. Only if none connects does it
   `exec repair.sh <that remote>`, so only the repair's output is reported.

**`connect.sh --no-repair`** stops at step 4 and reports instead. This is what
the unattended reconnect uses: a background process must never run
`bluetoothctl remove`, because a re-pair that then failed would leave the
remote worse off than it started.

`main.lua` keys off the literal string `Connection successful`, so anything
touching these scripts has to preserve it.

**stdout is for outcomes only.** Whatever a script prints on stdout is what
the user sees in a popup. `bluetoothctl`'s own output goes to stderr through
`diag` in `lib.sh`, tagged `[bluetooth]`, and so into `crash.log`. That output
includes scan results for every device in range, GATT dumps and colour codes.
A failed re-pair once filled the screen with it, with the reason scrolled off
the bottom. A failure prints the first `bluetoothctl` error (`first_error`)
and the bond state.

### 3.5 `main.lua` changes

**a. Colon-call fix (crash).** `refreshPairing()` had:

```lua
Device.input.open(self.input_device_path)   -- WRONG
```

`Input:open` is defined with a colon, so a dot-call binds the *path string* as
`self`; `self.input` is then nil and `self.input.is_ffi` throws
`frontend/device/input.lua:335: attempt to index field 'input' (a nil value)`.
Must be `Device.input:open(...)`.

**b. MSC_SCAN → action hook.** The remote emits **only** `EV_MSC`/`MSC_SCAN`;
the kernel never synthesises a matching `EV_KEY`, despite the key codes
appearing in the device's capability bitmap. Normal fix is a udev hwdb rule —
**unavailable**: this firmware's `udevadm` has no `hwdb` subcommand and no
`hwdb.d` directories exist. `setkeycodes` is also useless (legacy AT/PS2
scancode table only; these are wide HID-derived values).

Working approach — translate in a `registerEventAdjustHook` and dispatch the
UI event directly:

```lua
local bt_hook_registered = false
local bt_last_seen = {}

local BT_SCAN_FORWARD = 0x70051  -- Keyboard Down Arrow
local BT_SCAN_BACK    = 0x70052  -- Keyboard Up Arrow
local BT_REPEAT_GAP   = 0.5

-- inside Bluetooth:init()
if not bt_hook_registered then
    bt_hook_registered = true
    Device.input:registerEventAdjustHook(function(_, ev)
        if ev.type == 4 and ev.code == 4 then  -- EV_MSC, MSC_SCAN
            local now = ev.time.sec + ev.time.usec / 1000000
            local prev = bt_last_seen[ev.value] or 0
            bt_last_seen[ev.value] = now
            if now - prev < BT_REPEAT_GAP then
                return
            end
            if ev.value == BT_SCAN_FORWARD then
                UIManager:sendEvent(Event:new("GotoViewRel", 1))
            elseif ev.value == BT_SCAN_BACK then
                UIManager:sendEvent(Event:new("GotoViewRel", -1))
            end
        end
    end)
end
```

The hook as shipped also honours **Invert page-turn buttons** (a
`G_reader_settings` flag read on every press) and runs the Dispatcher actions
assigned to the Free3's third button (`0x7002c`, §3.5h).

**c. Connect on Bluetooth On.** `onBluetoothOn()` calls
`self:onConnectToDevice()` on success, so one menu tap brings a remote all the
way up. It used to call `onDeviceRepair()`, which threw away bonds that were
usually fine. `connect.sh` still hands a remote whose bond really is gone to
`repair.sh`. (Watch the colon — `self.onConnectToDevice()` silently
misbehaves.)

**d. The input device is resolved at runtime.** `findInputDevices()` reads
every `N: Name="…"` block for a listed remote out of `/proc/bus/input/devices`
and takes each one's `H: Handlers=` line, rather than assuming `event3`. It
also reports which remotes are present, for the preference check in f.

Four traps here, all confirmed the hard way:

- **There can be more than one.** The remote has shown up as two identically
  named uhid devices (`…0004` on `event3`, `…0005` on `event4`, same MAC),
  of which `evtest` showed only `event4` delivering `MSC_SCAN`. Taking the first
  match opened the dead one: connected, `Connection successful!`, no page
  turns. Every match is opened now — a device that never sends anything costs
  nothing to hold. Why BlueZ left two is not established.

- `/proc/bus/input/devices` and `/dev/input/` are **not in sync**. The kernel
  lists the device immediately; the node is `udevd`'s job and lags. Opening as
  soon as the entry appeared failed with `No such file or directory`. The old
  fixed `sleep 3` had been covering this by accident. `waitForInputDevices()`
  now polls until every listed node actually *opens*, and distinguishes "not
  there" from "listed but no node" so the popup names the real problem.
- **The same path can be a different device.** A disconnect destroys the uhid
  device and the reconnect can recreate it on the same event number, so a
  descriptor held across the cycle points at something that no longer exists —
  same path, different device, no events. Always close before opening, even
  when the path is unchanged.
- **Closing a vanished device can close a live one** (#48). When a device goes
  away, KOReader's input backend closes its fd by itself (`[ko-input] Closed
  input device … (matched by idx)`) but keeps the `path → fd` entry in
  `Input.opened_devices`. The fd number is then reused, so a later
  `Input:close(path)` closes whatever holds it now. On the Sage, that was the
  other remote (`… (matched by fd)` in the wrong slot), which left the reader
  connected and turning no pages. `closeInputPath` therefore checks
  `readlink("/proc/self/fd/<fd>")` against the path first. If it no longer
  matches, it only clears the entry. `readlink` is declared through the FFI;
  without it the close is unconditional, as before.

`bt_open_paths` (module-level) tracks what is actually open;
`closeInputDevices()` releases all of it, called from `refreshPairing()` and
`onBluetoothOff()`. The watcher closes individual paths as they disappear.

**e. The watcher.** A `UIManager:scheduleIn` tick every 5 s compares
`findInputDevices()` against `bt_open_paths` and reconciles them path by path:
opens what is newly listed, closes what is no longer listed, and leaves the
rest alone so a live device isn't dropped when a sibling changes.
Scheduled **once per process**, guarded by a module-level flag for the same
reason as the adjust hook (§5) — `init()` runs for FileManager and again for
ReaderUI, and two timers would race onto the same device. It logs rather than
popping up: an `InfoMessage` fired from a timer would interrupt reading.

**f. Unattended reconnect.** BlueZ will not re-dial an LE peripheral (§4), and
the Free3 doesn't come back by itself either. So the watcher runs
`connect.sh --no-repair` itself, rate-limited to once a minute. Roughly seven
seconds from a dropped link to a working remote.

It dials **the remotes listed ahead of the best one present**: every remote
when none is connected, the Free3 alone while only the Kobo Remote is. Without
the second case, a connected Kobo Remote kept the preferred Free3 out
indefinitely. Misses in that case are only debug-logged, because a Free3 left
switched off would otherwise add a line every minute.

Background runs pass Trapper **an unshown table** as the trap widget
(`BACKGROUND()`). Trapper treats a table as an already-shown widget, attaches
its `dismiss_callback` and never shows or closes it. So nothing can dismiss
the run, and taps go to the reader. Its own invisible widget (`true`) is
dismissed by any tap. `false` is too, and swallows the tap. On the Sage the
reconnect and the startup run were both logged as `interrupted` in the same
second, with their scripts left running unsupervised (#30).

The rate limit is a **timestamp, not an in-progress flag** — a flag left `true`
by an error would disable reconnection for the whole session, where a stale
timestamp costs at most one extra attempt.

**g. Nothing blocks the UI thread.** `executeScript` was `io.popen` read to EOF
on the UI thread, freezing the reader for the 15–20 s a pair-and-connect takes.
It now calls `Trapper:dismissablePopen(cmd, message)`, which returns
**`completed, output`** — two values. Callers must take both: binding it to one
variable gets the boolean, and the `result:match()` that follows throws into
`Trapper:wrap`'s `pcall` and *vanishes*, so the symptom is nothing happening
rather than a traceback.

Each handler wraps itself:

```lua
if not Trapper:isWrapped() then
    return Trapper:wrap(function() self:onConnectToDevice() end)
end
```

Wrapping here rather than at the menu callback covers the Dispatcher entry
point, so a gesture behaves like a menu tap; the guard keeps
`onBluetoothOn` → `onConnectToDevice` inside one coroutine instead of nesting.
Background runs use the unshown-table trick in f. Outside a wrap, Trapper logs
`unwrapped dismissablePopen()` and falls back to blocking `io.popen` — so a
missed wrap still *works*, and only shows up as a freeze.

**Scripts must write their output once, at exit** (#47). `dismissablePopen`
treats a run as finished once `FIONREAD` reports bytes on the pipe, then reads
the rest with a **blocking** `read("*all")` on the UI thread. A script that
printed nothing never finished, because EOF reads as 0 bytes available, so
`off.sh` left its message up until tapped. One that printed early finished at
its first line and froze the reader for the rest. `executeScript` therefore
wraps every script as `out=$(/bin/sh <script>); printf '%s\n' "$out"`.

**h. Startup, the third button and the menu.**

- **Bluetooth at startup.** *Turn on Bluetooth at startup* (on unless
  unticked) runs `on.sh` three seconds after KOReader starts, once per process,
  in the background. It is skipped when Bluetooth is already up, since `on.sh`
  tears the stack down. While `on.sh` runs, the watcher stands aside:
  `hci0` appears partway through, and a reconnect started then raced the
  daemon restart. It waits until `on.sh` reports back, or at most 20 s. Not
  gated on Wi-Fi, unlike the Toggle entry (#42).
- **Third button.** The Free3's `0x7002c` runs a Dispatcher action list stored
  in `G_reader_settings` (`bluetooth_button_actions.third`), edited through
  `Dispatcher:addSubMenu` — the gestures/hotkeys picker — and flushed in
  `onFlushSettings`. It runs on `UIManager:nextTick`, not inside the hook.
- **Menu placement.** Bluetooth sits on the settings tab directly below
  Network. A `sorting_hint` can only append to the end of a menu, so the plugin
  inserts `"bluetooth"` after `"network"` in `ui/elements/reader_menu_order`
  and `…/filemanager_menu_order`, which `require` caches. The hint,
  `"setting"`, is the fallback. Checked against v2026.03's `menusorter.lua`.

---

## 4. Dead ends — do not re-try these

| Attempt | Result |
|---|---|
| `hciattach ... bcm43xx` (upstream default) | `Initialization timed out` — wrong vendor protocol |
| `setkeycodes` for the scancodes | Wrong tool; legacy AT/PS2 table, can't express `0x111a3`-scale HID values |
| udev hwdb rule (`KEYBOARD_KEY_*`) | `udevadm` on this firmware has no `hwdb` subcommand; no `hwdb.d` dirs exist |
| Mutating `ev.type`/`ev.code` in the adjust hook to synthesise `EV_KEY`, then mapping via `settings/event_map.lua` to `BTLeft`/`BTRight` | Never fired. Dispatch to `handleKeyBoardEv` vs `handleMiscEv` appears to be decided before the hook runs, so rewriting `ev.type` afterwards is too late |
| Remapping onto existing keycodes 103/108 (`Up`/`Down`) | Those are `Cursor` group keys with nothing useful bound in reader view |
| Believing `evtest` and KOReader disagree on scancodes | They don't. `evtest` prints `70051`/`70052` in **hex**; `458833`/`458834` are the same values in decimal. This row used to call them different numbers. The constants are now written in hex |
| Debouncing against time-of-last-*accepted*-action | Can't distinguish a held button from fast consecutive taps; reduced but never eliminated double-advance |
| `hcitool lescan` while `bluetoothd` is running | `Set scan parameters failed: Connection timed out` — fights bluetoothd for the raw HCI socket. Use `bluetoothctl` instead |
| Killing the child luajit process | Killed BT input while leaving touch working. Two processes is normal on this build; not the cause of anything |
| Range-based `sed -i '/start/,/end/c\...'` for multi-line edits | Misfired twice; once destroyed ~200 lines of `main.lua` because the closing pattern `^end)$` didn't match the actual indented `    end)`. **Edit the file locally and transfer it** |
| Adding HOGP (`00001812-…`) to `[Policy] ReconnectUUIDs` to get auto-reconnect | **Structurally impossible, don't retry.** The policy plugin does match the device and fire its ladder — `disconnect_cb() identified for auto-reconnection`, `reconnect_set_timer() attempt 1/10` — then dies with `Reconnecting services failed: Operation not supported (95)`. It reconnects by calling a profile's `connect` method and LE profiles like HoG have none; an LE link comes up via GATT, not per-profile. That is why the stock list holds only classic HID and A2DP sink. The plugin has to dial it itself (§3.5f) |
| `sed -i` on the rootfs when `/` is full | Writes a temp file and renames it over the target, so it silently replaced `/etc/bluetooth/main.conf` with a **0-byte file** and reported nothing. The `cp` backup taken first had already failed for the same reason. Check `df -h /` before editing anything on `/` |
| Leaving a mock `bluetoothctl` earlier in `PATH` after a test | Poisoned three rounds of diagnosis in the same shell. It exits 0 with no output for any subcommand it doesn't implement, so `disconnect` did nothing, `--version` printed nothing, and `info \| grep -i uuid` came back empty — which produced an entire wrong theory about BlueZ storage before the real output showed the UUIDs were there. `command -v bluetoothctl` when a result is surprisingly empty |
| Reading `bluetoothctl info` immediately after `connect` to check the bond | Races encryption; reports `Paired: no` for a bond about to be fine. On the menu path that meant `exec repair.sh`, destroying a working bond to rebuild it. Poll instead (§3.4) |
| Trapper's invisible trap widget (`true`, or `false`) for background runs | Any tap dismisses it, and at startup both background runs were cancelled together (#30). Pass an unshown table instead (§3.5f) |
| `Input:close(path)` on a device that has gone away | KOReader already closed the fd, and the number may now belong to the other remote (#48). Check `/proc/self/fd/<fd>` first (§3.5d) |

---

## 5. The double-page-advance bug (solved)

Symptom: one button press advanced 2 pages.

Red herring: it looked like a timing/repeat problem, and the remote *does*
auto-repeat at ~135–200 ms while held, so widening the debounce window seemed
right. It never fully worked.

The tell: `logger.info` output showed pairs of lines with **byte-identical
timestamps and deltas**. That's not two events — it's one event handled twice.

Cause: KOReader instantiates a plugin once per UI context (FileManager and
ReaderUI), so `Bluetooth:init()` runs twice in the same process. And
`registerEventAdjustHook` **chains** hooks rather than replacing them. Result:
two live hooks, each closing over a different `self`, each debouncing against
its own `self.last_bt_seen_time` table, neither aware of the other. Both fire.

Fix: move debounce state to module-level locals (shared, because `require`
caches the module) and guard registration with a module-level boolean so the
hook is only ever added once. See §3.5b.

---

## 6. The `Connected: yes` / `Paired: no` state (explained)

Symptom, seen for months: the remote reports connected, `bluetoothctl` looks
healthy, and **no input device is ever created**, so nothing turns pages. Only
a full re-pair recovers it.

It was assumed to be BlueZ flakiness. It isn't. The remote **discards its bond
when it loses power**:

1. Battery pull — the remote throws away its bond.
2. It re-advertises as an unbonded device.
3. BlueZ still holds the LTK, connects, and offers it.
4. The remote rejects a key it no longer has.
5. Bonding fails — `bonding_attempt_complete() … status 0x5`,
   `device_bonding_failed() status 5`, HCI **authentication failure** — so
   BlueZ clears `Paired`, **but the LE link stays up**.

The HID characteristics need an encrypted link, so HoG can never read the
report map and no uhid device appears. Connected, and dead.

Verified live: while in that state there was no input device at all, and one
tap of *Reconnect to Device* flipped `Paired: no` → `yes` and brought it back.
That flag can only move via a full re-pair, so it proves the fall-through in
§3.4 fired.

**Consequence for the design:** automatic re-pair is the *correct* fix, not a
workaround. A bond the peripheral has thrown away cannot be recovered, only
replaced.

A second, independent cause of pairings that "never quite stick": if `/` is
full, BlueZ cannot persist bond updates at all — see §1 and §4. Symptomless
apart from the failure itself. Check `df -h /` first.

---

## 7. Open issues / possible next work

1. **The remote forgets its bond on power loss** (§6). Nothing to be done about
   it in software beyond re-pairing, which *Reconnect to Device* now does by
   itself. Listed because it explains most reports of "flaky" behaviour.
2. **Automatic recovery is untested across suspend/resume.** Everything was
   verified with forced disconnects over SSH. `UIManager` timers do not fire
   while the Kobo is asleep, so the watcher and the unattended reconnect have
   never been exercised across a real overnight idle or a wake from sleep.
   Most likely remaining gap.
3. **`hci0` sometimes stays down after `on.sh`.** Seen once at startup
   (`hci0 did not come up`), with the next start fine. `on.sh` now retries the
   whole bring-up once (#49); whether that recovers it has not been observed
   yet. If it recurs, `crash.log` has the attach log from each attempt.
4. **`bt_open_paths` is per-process**, so it is empty after a KOReader restart.
   Believed harmless — nothing is open at that point either — but it means the
   close only covers handles opened in the current session. It is also a useful
   tell when reading logs: a `watcher opened` line for a path already opened,
   with no `closing` for it in between, means KOReader restarted.
5. **`/var/log` is a 16 KB tmpfs.** `on.sh` used to start `bluetoothd -d`
   into it, which wrapped within seconds. It no longer passes `-d` (#34), but
   the log is still small and short-lived, so any conclusion drawn from
   something being *absent* in it is unsafe. For debug output, start a debug
   daemon by hand pointed somewhere with room (§8).
6. **The four `[General]` lines of `main.conf` are gone**, destroyed by `sed -i`
   on a full disk before a backup existed. Everything has worked on BlueZ
   defaults since. If a pristine copy ever turns up in a firmware package,
   worth diffing.
7. **Debounce gap is a guess.** `BT_REPEAT_GAP = 0.5` works; not tuned. There
   is no `EV_KEY` to work with — MSC_SCAN only — so time-based is the only
   option available. The Free3 sends press and release 30 ms apart and doesn't
   repeat while held; the Kobo Remote auto-repeats.
8. **Why the Kobo Remote gets two input devices** is not established (§3.5d).

---

## 8. Useful commands

```sh
# stack health, top to bottom
hciconfig hci0                       # want: UP RUNNING
ps aux | grep -i rtk_hciattach
ps aux | grep -i bluetoothd
bluetoothctl show                    # want: Powered: yes
bluetoothctl info AA:BB:CC:DD:EE:FF  # want: Paired: yes AND Connected: yes
cat /proc/bus/input/devices          # find the Kobo Remote's eventN
df -h /                              # BlueZ cannot persist bonds on a full /

# what the plugin is actually doing (INFO level, no debug flag needed)
grep -E "Bluetooth:|\[bluetooth\]|ko-input" \
     /mnt/onboard/.adds/koreader/crash.log | tail -30

# which input devices KOReader holds open -- the remote's should come and go
pid=$(ps | grep '[r]eader.lua' | awk '{print $1}' | head -1)
ls -l /proc/$pid/fd | grep event

# run the connect path by hand, exactly as the plugin does.
# --no-repair can never reach repair.sh, so this is safe to poke at
time /bin/sh /mnt/onboard/.adds/koreader/plugins/bluetooth.koplugin/connect.sh --no-repair

# full manual recovery when hci0 is wedged
killall rtk_hciattach; hciconfig hci0 down
echo 0 > /sys/devices/platform/bt/rfkill/rfkill0/state; sleep 1
echo 1 > /sys/devices/platform/bt/rfkill/rfkill0/state
/sbin/rtk_hciattach -n -s 115200 /dev/ttyS1 rtk_h5 &
sleep 2; hciconfig hci0 up

# raw button codes as the kernel sees them
evtest /dev/input/eventN

# bluetoothd with debug logging.
# NOT into /var/log -- that is a 16 KB tmpfs and debug output overruns it in
# seconds, which silently truncated our diagnostics for most of a day. Send it
# somewhere with room. Restarting bluetoothd alone is enough to pick up a
# main.conf change; the controller stays attached.
killall bluetoothd
setsid /libexec/bluetooth/bluetoothd -n -d > /mnt/onboard/bluetoothd.log 2>&1 &
sleep 2 && bluetoothctl power on     # a fresh daemon comes up powered down

# did a config change actually take? compare the daemon's start time
ls -l /etc/bluetooth/main.conf
ls -ld /proc/$(pidof bluetoothd)

# KOReader restart from SSH (wrapper respawns it)
ps aux | grep -i luajit
kill -9 <parent-pid>
```

Gotcha: KOReader's SSH server is a plugin, so exiting KOReader kills your own
shell access. Also, **"Developer options" only appears in the File Manager's
Tools → More tools menu**, not in the reader view with a book open — this is
how to turn verbose logging back off. Failing that, edit `debug` /
`debug_verbose` in `settings.reader.lua` over USB mass storage with KOReader
closed.

---

## 9. Community

Nothing found documenting a Realtek-chip Sage working with the official BLE
remote through any of these plugins. Worth reporting to:

- MobileRead thread: <https://www.mobileread.com/forums/showthread.php?t=362986>
- <https://github.com/CarloDePieri/bluetooth.koplugin/issues>

Neither `onatbas` nor `OGKevin`'s plugin lists the Sage as supported; both
target i.MX6 (`bluetoothctl`/`hciattach`) or MTK (D-Bus) Kobos.
`tsowell/kobo-btpt` is Libra 2 only. `sublipri/kobo-wifi-remote` *is* tested on
a Sage but works over WiFi rather than direct BLE.
