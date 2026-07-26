# Kobo Sage + official Kobo Remote + KOReader — technical handoff

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
cd "$(dirname "$0")"

killall rtk_hciattach 2>/dev/null
killall bluetoothd 2>/dev/null
hciconfig hci0 down 2>/dev/null

echo 0 > /sys/devices/platform/bt/rfkill/rfkill0/state
sleep 1
echo 1 > /sys/devices/platform/bt/rfkill/rfkill0/state

/sbin/rtk_hciattach -n -s 115200 /dev/ttyS1 rtk_h5 > /var/log/rtk_hciattach.log 2>&1 &
sleep 2
hciconfig hci0 up

setsid /libexec/bluetooth/bluetoothd -n -d > /var/log/bluetoothd.log 2>&1 &
sleep 2

echo "complete"
```

Three non-obvious requirements are encoded here:

1. **Output redirection is mandatory, not cosmetic.** `rtk_hciattach` is a
   *resident* process (H5 needs a process servicing the link continuously —
   unlike a fire-and-forget `hciattach`). Backgrounded with `&` it still
   inherits the script's stdout. The plugin invokes `on.sh` via `io.popen` and
   reads to EOF, so the pipe never closes and **KOReader's UI thread hangs
   forever**. Diagnosed via `/proc/<pid>/wchan` = `pipe_wait`. Looked exactly
   like a crash.
2. **`setsid` for bluetoothd.** Started with a plain `&` from an interactive
   shell it dies with the session. This wasted time repeatedly.
3. **Unconditional rfkill power-cycle.** `hci0` regularly ends up
   attached-but-`DOWN`, at which point `hciconfig hci0 up` fails with
   `Connection timed out (110)`. Only a full rfkill 0→1 cycle followed by a
   fresh `rtk_hciattach` recovers it. Doing this every time is cheap insurance;
   trying to detect the bad state was not worth it.

Trade-off: this always tears down, so a "Bluetooth On" toggle drops any
existing pairing/connection and takes a few seconds.

### 3.3 `off.sh`

```sh
#!/bin/sh
cd "$(dirname "$0")"
hciconfig hci0 down
killall rtk_hciattach
killall bluetoothd
echo 0 > /sys/devices/platform/bt/rfkill/rfkill0/state
```

### 3.4 `repair.sh` / `connect.sh`

The device name lives in `device.conf`, sourced by every script and parsed by
`main.lua`, with the default duplicated as a fallback in each. It used to be
hardcoded in three places, which is how an unquoted `grep "$BT_DEVICE_NAME"`
got in — unquoted, `grep` reads `Remote` as a filename and dies.

`repair.sh` is the full `power off/on` → `remove` → `scan` → `pair` → `trust`
→ `connect` cycle. It is the only thing that recovers a bond the remote has
forgotten, and it is destructive: `remove` throws away the existing bond
before rebuilding it.

`connect.sh` is the quick path, and verifies its own work:

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
4. On a bad bond, `exec repair.sh` so only the repair's output is reported.

**`connect.sh --no-repair`** stops at step 4 and reports instead. This is what
the unattended reconnect uses: a background process must never run
`bluetoothctl remove`, because a re-pair that then failed would leave the
remote worse off than it started.

`main.lua` keys off the literal string `Connection successful`, so anything
touching these scripts has to preserve it.

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

local BT_SCAN_FORWARD = 458833
local BT_SCAN_BACK    = 458834
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

**c. Auto-repair on Bluetooth On.** `onBluetoothOn()` now calls
`self:onDeviceRepair()` on success instead of just showing a popup, so one menu
tap brings the remote all the way up. (Watch the colon — `self.onDeviceRepair()`
silently misbehaves.)

**d. The input device is resolved at runtime.** `findInputDevice()` reads the
`N: Name="Kobo Remote"` block out of `/proc/bus/input/devices` and takes its
`H: Handlers=` line, rather than assuming `event3`.

Two traps here, both confirmed the hard way:

- `/proc/bus/input/devices` and `/dev/input/` are **not in sync**. The kernel
  lists the device immediately; the node is `udevd`'s job and lags. Opening as
  soon as the entry appeared failed with `No such file or directory`. The old
  fixed `sleep 3` had been covering this by accident. `waitForInputDevice()`
  now polls for a node that actually *opens*, and distinguishes "not there"
  from "listed but no node" so the popup names the real problem.
- **The same path can be a different device.** A disconnect destroys the uhid
  device and the reconnect can recreate it on the same event number, so a
  descriptor held across the cycle points at something that no longer exists —
  same path, different device, no events. Always close before opening, even
  when the path is unchanged.

`bt_open_path` (module-level) tracks what is actually open; `closeInputDevice()`
is the single place that releases it, called from `refreshPairing()`,
`onBluetoothOff()` and the watcher.

**e. The watcher.** A `UIManager:scheduleIn` tick every 5 s compares
`findInputDevice()` against `bt_open_path` and reconciles them: opens when the
remote appears or its event number moves, drops the handle when it goes away.
Scheduled **once per process**, guarded by a module-level flag for the same
reason as the adjust hook (§5) — `init()` runs for FileManager and again for
ReaderUI, and two timers would race onto the same device. It logs rather than
popping up: an `InfoMessage` fired from a timer would interrupt reading.

**f. Unattended reconnect.** BlueZ will not re-dial an LE peripheral (§4), so
when the watcher finds no input device it runs `connect.sh --no-repair` itself,
rate-limited to once a minute. Roughly seven seconds from a dropped link to a
working remote.

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
`onBluetoothOn` → `onDeviceRepair` inside one coroutine instead of nesting.
Passing `true` as the message gets an invisible trap widget, which is what the
background reconnect uses. Outside a wrap, Trapper logs
`unwrapped dismissablePopen()` and falls back to blocking `io.popen` — so a
missed wrap still *works*, and only shows up as a freeze.

---

## 4. Dead ends — do not re-try these

| Attempt | Result |
|---|---|
| `hciattach ... bcm43xx` (upstream default) | `Initialization timed out` — wrong vendor protocol |
| `setkeycodes` for the scancodes | Wrong tool; legacy AT/PS2 table, can't express `0x111a3`-scale HID values |
| udev hwdb rule (`KEYBOARD_KEY_*`) | `udevadm` on this firmware has no `hwdb` subcommand; no `hwdb.d` dirs exist |
| Mutating `ev.type`/`ev.code` in the adjust hook to synthesise `EV_KEY`, then mapping via `settings/event_map.lua` to `BTLeft`/`BTRight` | Never fired. Dispatch to `handleKeyBoardEv` vs `handleMiscEv` appears to be decided before the hook runs, so rewriting `ev.type` afterwards is too late |
| Remapping onto existing keycodes 103/108 (`Up`/`Down`) | Those are `Cursor` group keys with nothing useful bound in reader view |
| Trusting `evtest`'s scancode numbers | `evtest` printed `70051`/`70052`; KOReader's own pipeline sees `458833`/`458834` for the same buttons. **Always confirm values from inside the actual hook** (debug popup or `logger.info`) |
| Debouncing against time-of-last-*accepted*-action | Can't distinguish a held button from fast consecutive taps; reduced but never eliminated double-advance |
| `hcitool lescan` while `bluetoothd` is running | `Set scan parameters failed: Connection timed out` — fights bluetoothd for the raw HCI socket. Use `bluetoothctl` instead |
| Killing the child luajit process | Killed BT input while leaving touch working. Two processes is normal on this build; not the cause of anything |
| Range-based `sed -i '/start/,/end/c\...'` for multi-line edits | Misfired twice; once destroyed ~200 lines of `main.lua` because the closing pattern `^end)$` didn't match the actual indented `    end)`. **Edit the file locally and transfer it** |
| Adding HOGP (`00001812-…`) to `[Policy] ReconnectUUIDs` to get auto-reconnect | **Structurally impossible, don't retry.** The policy plugin does match the device and fire its ladder — `disconnect_cb() identified for auto-reconnection`, `reconnect_set_timer() attempt 1/10` — then dies with `Reconnecting services failed: Operation not supported (95)`. It reconnects by calling a profile's `connect` method and LE profiles like HoG have none; an LE link comes up via GATT, not per-profile. That is why the stock list holds only classic HID and A2DP sink. The plugin has to dial it itself (§3.5f) |
| `sed -i` on the rootfs when `/` is full | Writes a temp file and renames it over the target, so it silently replaced `/etc/bluetooth/main.conf` with a **0-byte file** and reported nothing. The `cp` backup taken first had already failed for the same reason. Check `df -h /` before editing anything on `/` |
| Leaving a mock `bluetoothctl` earlier in `PATH` after a test | Poisoned three rounds of diagnosis in the same shell. It exits 0 with no output for any subcommand it doesn't implement, so `disconnect` did nothing, `--version` printed nothing, and `info \| grep -i uuid` came back empty — which produced an entire wrong theory about BlueZ storage before the real output showed the UUIDs were there. `command -v bluetoothctl` when a result is surprisingly empty |
| Reading `bluetoothctl info` immediately after `connect` to check the bond | Races encryption; reports `Paired: no` for a bond about to be fine. On the menu path that meant `exec repair.sh`, destroying a working bond to rebuild it. Poll instead (§3.4) |

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
3. **One unexplained silent failure.** An unattended attempt produced no log
   line at all — no error, no `unwrapped dismissablePopen` warning, no outcome
   — while running fine by hand seconds later. Suspected the trap widget being
   dismissed (`true` resends the event, so a stray tap cancels the attempt),
   never confirmed, not reproducing. Every outcome is logged now: if
   `unattended reconnect was interrupted` appears, that confirms it and the fix
   is passing `false` for that parameter.
4. **`bt_open_path` is per-process**, so it is nil after a KOReader restart.
   Believed harmless — nothing is open at that point either — but it means the
   close only covers handles opened in the current session. It is also a useful
   tell when reading logs: two `watcher opened` lines with no `closing` between
   them means KOReader restarted.
5. **`bluetoothd -d` logs into a 16 KB tmpfs.** `on.sh` writes
   `/var/log/bluetoothd.log`, which fills in seconds, so any conclusion drawn
   from something being *absent* in that log is unsafe. Redirect somewhere with
   space when debugging (§8).
6. **The four `[General]` lines of `main.conf` are gone**, destroyed by `sed -i`
   on a full disk before a backup existed. Everything has worked on BlueZ
   defaults since. If a pristine copy ever turns up in a firmware package,
   worth diffing.
7. **Debounce gap is a guess.** `BT_REPEAT_GAP = 0.5` works; not tuned. There
   is no release event to work with — MSC_SCAN only — so time-based is the only
   option available.

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
grep -E "watcher|unattended|reconnected|bond is gone" \
     /mnt/onboard/.adds/koreader/crash.log | tail

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
