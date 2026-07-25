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

### The remote itself

- Name `Kobo Remote`, MAC `AA:BB:CC:DD:EE:FF`, public address.
- **BLE (HID-over-GATT / HOGP)**, not classic Bluetooth HID — advertises UUID
  `00001812-0000-1000-8000-00805f9b34fb`.
- Presents as a media-key style keyboard. Its evdev modalias advertises key
  capabilities including `A3`,`A4` (163/164 = `NextSong`/`PlayPause`).
- Lands on `/dev/input/eventN` via `uhid` once connected **and bonded**.
  `N` is **not stable** across reconnects (seen as event3, event4, …).
- Auto-repeats while a button is held, roughly every 135–200 ms.

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

Only change needed: replace the author's device-name grep.

```sh
sed -i 's/Q36 for Android/Kobo Remote/g' repair.sh
sed -i 's/Q36/Kobo Remote/g' connect.sh
```

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

## 6. Open issues / possible next work

1. **Hardcoded `input_device_path = "/dev/input/event3"`.** The event number
   changes across reconnects. When it's wrong, "Refresh Device Input" throws
   `Error opening input device </dev/input/event3>: No such file or directory`.
   Fix: resolve at runtime by scanning `/proc/bus/input/devices` for the
   `N: Name="Kobo Remote"` block and reading its `H: Handlers=` line.
2. **Connection doesn't survive idle.** The remote drops its BLE link when
   idle; the `uhid` device disappears with it. BlueZ's `[Policy]`
   `ReconnectUUIDs` in `main.conf` lists classic HID (`1124`) but **not** HOGP
   (`1812`) — adding it may enable auto-reconnect. Untested.
3. **Bond state is fragile.** Have repeatedly seen `Connected: yes` with
   `Paired: no` — the remote auto-reconnects without re-bonding. In that state
   BlueZ resolves GAP/GATT/Device-Info but the HID report characteristics stay
   inaccessible, so **no input device is created**. Reliable recovery is the
   full `remove` → `scan on` → (press button) → `scan off` → `pair` → `trust` →
   `connect` cycle. Watch for the literal `Pairing successful` line; it is
   sometimes silently skipped.
4. **`refreshPairing()` never closes the old fd** — the `Device.input:close(...)`
   line is commented out upstream. Repeated calls across changing event numbers
   may accumulate open handles.
5. **Debounce gap is a guess.** `BT_REPEAT_GAP = 0.5` works; not tuned.

---

## 7. Useful commands

```sh
# stack health, top to bottom
hciconfig hci0                       # want: UP RUNNING
ps aux | grep -i rtk_hciattach
ps aux | grep -i bluetoothd
bluetoothctl show                    # want: Powered: yes
bluetoothctl info AA:BB:CC:DD:EE:FF  # want: Paired: yes AND Connected: yes
cat /proc/bus/input/devices          # find the Kobo Remote's eventN

# full manual recovery when hci0 is wedged
killall rtk_hciattach; hciconfig hci0 down
echo 0 > /sys/devices/platform/bt/rfkill/rfkill0/state; sleep 1
echo 1 > /sys/devices/platform/bt/rfkill/rfkill0/state
/sbin/rtk_hciattach -n -s 115200 /dev/ttyS1 rtk_h5 &
sleep 2; hciconfig hci0 up

# raw button codes as the kernel sees them
evtest /dev/input/eventN

# bluetoothd with debug logging
killall bluetoothd
setsid /libexec/bluetooth/bluetoothd -n -d > /tmp/btdebug.log 2>&1 &

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

## 8. Community

Nothing found documenting a Realtek-chip Sage working with the official BLE
remote through any of these plugins. Worth reporting to:

- MobileRead thread: <https://www.mobileread.com/forums/showthread.php?t=362986>
- <https://github.com/CarloDePieri/bluetooth.koplugin/issues>

Neither `onatbas` nor `OGKevin`'s plugin lists the Sage as supported; both
target i.MX6 (`bluetoothctl`/`hciattach`) or MTK (D-Bus) Kobos.
`tsowell/kobo-btpt` is Libra 2 only. `sublipri/kobo-wifi-remote` *is* tested on
a Sage but works over WiFi rather than direct BLE.
