# Bluetooth Page Turner Support for the Kobo Sage

A KOReader plugin that brings up Bluetooth on a **Kobo Sage** and connects a
page-turner remote: the **official Kobo Remote** or a **Hanlinyue Free3**.

This is working on my own Sage. Bluetooth comes up by itself when KOReader
starts, the preferred remote is connected in the background, and it turns pages
from there. Both remotes can be paired, and either one works.

## Lineage

This repo is a fork of [CarloDePieri/bluetooth.koplugin](https://github.com/CarloDePieri/bluetooth.koplugin),
itself a fork of [onatbas/bluetooth.koplugin](https://github.com/onatbas/bluetooth.koplugin).
Read the original readme to understand the overall design — this fork only
changes what the Sage needed.

Both parent repos target Kobos with a **Broadcom** Bluetooth chip and a
**classic Bluetooth HID** controller. The Sage has neither, which is what this
fork is about.

Full credits, prior art consulted, and who did what are in
[`CREDITS.md`](CREDITS.md).

## What's different here

1. **Realtek RTL8821CS bring-up.** The Sage's radio is a Realtek part attached
   over UART on `/dev/ttyS1` speaking H5, not a Broadcom one. The upstream
   `hciattach ... bcm43xx` always ends in `Initialization timed out` and `hci0`
   is never created. `on.sh` uses `rtk_hciattach` instead, power-cycles the
   chip through rfkill first, waits for each step rather than sleeping, and
   retries once if `hci0` doesn't come up.

2. **Input translation.** Both remotes emit **only** `EV_MSC`/`MSC_SCAN`. The
   kernel never synthesises a matching `EV_KEY`, so KOReader's keymap sees
   nothing, and the usual fix — a udev hwdb rule — isn't available on this
   firmware. `main.lua` registers an event-adjust hook, recognises the
   remotes' codes, and turns the page itself.

3. **One page per press.** Each press sends its code twice — the Free3 both at
   press, the Kobo Remote at press and again at release — so the plugin acts on
   the first and swallows the second. Holding a button turns one page; a quick
   double-tap turns two.

4. **Two remotes.** The official Kobo Remote (BLE) and the Hanlinyue Free3
   (classic Bluetooth), listed in `device.conf` in order of preference and
   matched by exact name. Either one turns pages, and the Free3 is preferred
   when both are around.

5. **It looks after itself.** Bluetooth comes up when KOReader starts, goes
   off when the Kobo sleeps and comes back when it wakes — left on, the link
   to the chip died in suspend. A watcher reopens a remote's input device
   whenever it reappears, and dials a missing remote in the background, since
   neither remote reconnects by itself. A dead controller is restarted. None of
   this re-pairs unattended.

6. **Nothing freezes the reader.** Scripts run off the UI thread through
   KOReader's Trapper, with their output collected and delivered at exit.

## Tested on

| | |
|---|---|
| Device | Kobo Sage |
| Bluetooth/WiFi chip | Realtek RTL8821CS, UART on `/dev/ttyS1`, H5 |
| BlueZ | 5.63, `bluetoothd` at `/libexec/bluetooth/bluetoothd` |
| Remote | Official Kobo Remote — BLE HID-over-GATT (UUID `00001812-…`) |
| Remote | Hanlinyue Free3 in P mode — classic Bluetooth HID (UUID `00001124-…`) |
| KOReader | v2026.03 |
| `uhid` | Built into the kernel (`CONFIG_UHID=y`), no module needed |

Nothing here is likely to work unmodified on another model. Other Realtek Kobos
are a plausible starting point; Broadcom and MTK devices should use one of the
parent repos instead.

## Install

Download **`bluetooth.koplugin.zip`** from the
[latest release](https://github.com/Tharavol/bluetooth.koplugin/releases/latest)
and unzip it into KOReader's `plugins` folder, usually:

```
/mnt/onboard/.adds/koreader/plugins/
```

That gives `plugins/bluetooth.koplugin/`, which is all KOReader needs. Restart
KOReader. Any other KOReader `plugins` folder works too — the plugin finds its
own files wherever it is.

The zip holds only what runs on the device, plus `LICENSE`, `DISCLAIMER` and
this readme. Use it rather than GitHub's green **Code → Download ZIP**, which
unpacks to `bluetooth.koplugin-main`: KOReader only loads folders named
`*.koplugin`, so that one silently never loads — no error, and nothing in
`crash.log`.

**Upgrading:** unzip over the old folder. If you edited `device.conf`, keep a
copy first, since the zip replaces it. Installs from before v1.6.0 may still
have `uhid/` and `device.lua.patch` in the folder; neither was ever used on the
Sage, and both can be deleted.

**From a clone:** copy the `*.lua` and `*.sh` files and `device.conf` into a
folder named exactly `bluetooth.koplugin`. The `.sh` files need LF line
endings; `.gitattributes` forces LF on checkout, so a clone made on Windows
stays usable.

Root is required; the scripts write to `/sys` and start daemons.

## Using it

By default there is nothing to do. **Bluetooth turns on by itself** a few
seconds after KOReader starts, and the plugin connects whichever paired remote
answers, trying them in `device.conf` order. It then watches for a remote
dropping out and dials it again in the background: every 10 s for two minutes
after Bluetooth comes up, then about once a minute. It never re-pairs on its
own.

The first time, pair each remote once with **RePair** (below).

Everything else lives under **Bluetooth** on the settings tab, directly below
**Network**:

- **Toggle Bluetooth** — runs `on.sh`, then connects to the first paired remote
  that answers. It takes several seconds and always tears the stack down first,
  so it drops any existing connection. Wi-Fi has to be on for this entry (#42).
- **Reconnect to Device** — `connect.sh`. Tries each paired remote in order and
  verifies the bond. A remote whose link came up without a bond is handed over
  to a re-pair automatically.
- **RePair & Reconnect to Device (long!)** — a submenu with one entry per
  remote. `repair.sh` removes that remote's bond, rescans, pairs, trusts and
  connects, retrying for up to 90 s. The remote has to be advertising while it
  scans: see [Remotes](#remotes). A remote that is already connected and
  working is left alone.
- **Refresh Device Input** — closes and reopens the remotes' input devices. The
  watcher does this by itself; this is the manual override.
- **Invert page-turn buttons** — swaps forward and back, for any remote.
- **Turn on Bluetooth at startup** — on by default. Untick it to bring Bluetooth
  up only from the menu.
- **Bluetooth info** — the device, whether Bluetooth is on, the controller
  (manufacturer, Bluetooth version, bus, address), the chip as named by the
  Wi-Fi driver, and the BlueZ version. Handy for bug reports. The controller
  details need Bluetooth on, and the chip name needs Wi-Fi on.
- **Third button (Free3): …** — KOReader's own action picker, the one gestures
  use. Whatever is chosen runs when the Free3's third button is pressed.

Messages are kept short. The full `bluetoothctl` output goes to `crash.log`,
with each line tagged `[bluetooth]`.

## Remotes

`device.conf` lists the remotes the plugin reads, in order of preference:

```sh
BT_DEVICE_NAMES="Free3-P|Kobo Remote"
```

Every listed remote that is connected turns pages. While a remote earlier in
the list is missing, the plugin keeps dialling it about once a minute, even if
a later one is connected. Edit the list and restart KOReader to change it.

**Official Kobo Remote.** To pair it, run **RePair → Kobo Remote** and press
one of its buttons while it scans, so it advertises. It forgets its bond
whenever it loses power (see [Known issues](#known-issues)), so it needs
re-pairing after a battery change.

**Hanlinyue Free3.** Set the switch on the side to **P**. Press the side On key
until the light over the **↑↓** icon is lit: *Up and Down Mode*. In that mode
the top key turns back and the middle key turns forward, sending exactly the
codes the Kobo Remote sends. The bottom key runs whatever **Third button** is
set to. Pair it once with **RePair → Free3-P** while its blue light is flashing.
It keeps its bond through power-offs, so after that it only needs switching on,
and the plugin picks it up within a minute — within 10 s just after Bluetooth
comes up. RePair leaves a connected Free3 alone; to pair it again anyway,
switch it off, wait 20 seconds, choose RePair, then switch it on. Volume mode, the other one likely
to be selected by accident, sends volume keys, which turn no pages.

**Another remote** may work if it sends the same keyboard Up/Down Arrow codes:
add its exact Bluetooth name to the list. `evtest` on its input device shows
what it sends. The Kobo Remote and the Free3 send `MSC_SCAN` values `70051`
(forward) and `70052` (back).

## Known issues

- **The remote forgets its bond when it loses power.** This is the cause of the
  `Connected: yes` / `Paired: no` state, and it isn't BlueZ's fault. Pull the
  battery and the remote discards its bond; it then re-advertises as unbonded,
  BlueZ connects and offers the stored LTK, the remote rejects a key it no
  longer has, and the bonding attempt fails with HCI status `0x05`
  (authentication failure). BlueZ clears `Paired` but the LE link stays up — so
  the remote looks connected while the HID characteristics, which need
  encryption, stay unreachable and no input device is ever created. Only a
  fresh bond recovers it, which is what *Reconnect to Device* now does on its
  own. Confirmed on the Sage from `bluetoothd` debug logs.
- **The link doesn't come back by itself**, for either remote. When the Kobo
  Remote drops, BlueZ will not re-dial it, so it stays gone until something
  asks for a connection. The Free3 doesn't reconnect by itself either: every
  return seen on the Sage was the plugin dialling it.
  `[Policy] ReconnectUUIDs` is **not** the answer and adding HOGP (`1812`) to
  it does nothing: the policy plugin reconnects by calling a profile's
  `connect` method, LE profiles like HoG don't have one, and the attempt fails
  with `Operation not supported`. That's why the stock list holds only BR/EDR
  profiles. The plugin therefore dials the remotes itself, in the background.
  It deliberately won't re-pair unattended, so a bond the remote has
  *forgotten* still needs a menu tap.
- **Re-pairing a connected Free3 takes about a minute.** Dropped by the
  re-pair, it ignores the Kobo for ~45 s before it will pair again. RePair
  waits it out, which is also why it leaves a working Free3 alone.
- **Bluetooth needs somewhere to write.** The rootfs is ~282 MB and ships
  nearly full; BlueZ stores bonds under `/var/db/bluetooth`, and when the disk
  is full it fails to persist them with no symptom other than pairings that
  never quite stick. Worth a `df -h /` before blaming anything else. Note that
  attaching VS Code's Remote-SSH to a Kobo installs ~30 MB into `/` and will
  fill it. Beware editing config files on a full rootfs: `sed -i` writes a
  temp file and renames it over the original, so it will happily replace
  `/etc/bluetooth/main.conf` with an empty one and report nothing.
- **An open SSH session blocks USB share.** KOReader's SSH server
  (`dropbear`) runs from `/mnt/onboard`, so USB mass storage reports the
  filesystem busy while it is up. Turn SSH off first. Bluetooth itself no longer
  gets in the way.
- **One page per press relies on each press sending its code twice.** Both
  remotes do, as measured: the Free3 twice at press, the Kobo Remote at press
  and again at release. The plugin acts on the first and ignores the second, so
  holding a button turns one page, and a quick double-tap turns two. Another
  remote that sends a single code per press would turn a page only on every
  other press.

## Digging deeper

[`docs/HANDOFF.md`](docs/HANDOFF.md) is the technical record of the current
design: the hardware facts and how each was established, how every script and
the plugin work and why, open issues, and useful debugging commands.
[`docs/HISTORY.md`](docs/HISTORY.md) covers how it got there: a table of dead
ends not worth retrying, and the bugs worth remembering.

One gotcha worth repeating here: KOReader's SSH server is itself a plugin, so
quitting KOReader kills your own shell session.

## License

MIT — see [`LICENSE`](LICENSE), inherited unchanged from
[onatbas/bluetooth.koplugin](https://github.com/onatbas/bluetooth.koplugin).
Changes in this fork are offered under the same terms; see
[`CREDITS.md`](CREDITS.md). [`DISCLAIMER`](DISCLAIMER) is worth reading before
you point this at a device you care about.

## Community

I found nothing documenting a Realtek-chip Sage driving the official BLE remote
through any of these plugins. If you get there too, the
[MobileRead thread](https://www.mobileread.com/forums/showthread.php?t=362986)
and [CarloDePieri's issues](https://github.com/CarloDePieri/bluetooth.koplugin/issues)
are the places to say so.
