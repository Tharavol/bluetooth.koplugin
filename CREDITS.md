# Credits and attribution

This plugin is the third link in a chain, and most of its shape came from the
two before it.

## Upstream

**[onatbas/bluetooth.koplugin](https://github.com/onatbas/bluetooth.koplugin)**
— the original. The structure is still recognisably theirs: the Bluetooth menu,
the shell-script model (`on.sh`, `off.sh`, `repair.sh`, `connect.sh`) driven
from `main.lua`, and the `BT*` actions registered through KOReader's Dispatcher.

**[CarloDePieri/bluetooth.koplugin](https://github.com/CarloDePieri/bluetooth.koplugin)**
— the direct parent, and the commit this fork started from.

Both target Kobos with a Broadcom Bluetooth chip and a classic Bluetooth HID
remote. The Sage has neither, so nearly every line of the scripts has since
changed — but the design they laid down is why this was a port rather than a
rewrite.

## Prior art consulted

Surveyed while working out whether the Sage was solvable at all. None of it is
an ancestor of this code:

- [tsowell/kobo-btpt](https://github.com/tsowell/kobo-btpt) — Libra 2 only
- [sublipri/kobo-wifi-remote](https://github.com/sublipri/kobo-wifi-remote) —
  tested on a Sage, but works over WiFi rather than direct BLE
- OGKevin's plugin — MTK Kobos, D-Bus based
- The [MobileRead thread](https://www.mobileread.com/forums/showthread.php?t=362986)
  — the nearest thing to documentation that exists for any of this

## KOReader

Built on [KOReader](https://github.com/koreader/koreader), and leans on rather
more of its internals than a plugin usually does: `Device.input:open/close`,
`registerEventAdjustHook`, `UIManager:scheduleIn`, and `Trapper` for running
the scripts off the UI thread.

## License

MIT, inherited from
[onatbas/bluetooth.koplugin](https://github.com/onatbas/bluetooth.koplugin) —
see [`LICENSE`](LICENSE), which is byte-identical to theirs. The copyright line
reads *Bluetooth Page Turner Contributors*; changes made in this fork are
offered under those same terms, as part of that same collective, with no
separate claim made over them.

The notice had gone missing somewhere down the chain. MIT grants the right to
modify and redistribute on the condition that the copyright and permission
notice travel with the code, so restoring it isn't courtesy — it is the
condition the grant runs on.

[`DISCLAIMER`](DISCLAIMER) comes from the same place, and is worth keeping: this
plugin power-cycles a radio through rfkill and opens kernel input devices.

[CarloDePieri/bluetooth.koplugin](https://github.com/CarloDePieri/bluetooth.koplugin),
the fork this one descends from, carries no license file. Whatever it inherited
from onatbas remains MIT; its author's own additions are not explicitly
licensed either way.

## This fork

**Tharavol** — owns the Sage, ran the device testing, decided what to build.

**Claude (Opus 5), via [Claude Code](https://claude.com/claude-code)** — wrote
most of the code and docs, working from that testing. No access to the device
itself, so every hardware fact in [`docs/HANDOFF.md`](docs/HANDOFF.md) was
confirmed on the Sage rather than assumed. Commits carry a
`Co-Authored-By: Claude Opus 5` trailer.
