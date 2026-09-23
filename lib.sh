# shellcheck shell=sh
#
# Shared by connect.sh and repair.sh. Sourced, not run: the caller sets
# BT_DIR to the plugin directory first.

BT_DEVICE_NAME="Kobo Remote"  # fallback if device.conf is missing
# shellcheck source=device.conf
. "$BT_DIR/device.conf" 2>/dev/null || true

# A function rather than a command in a string: "$bltctl" quoted, which is the
# reflex fix for a word-splitting warning, would try to run a program called
# "timeout 5s bluetoothctl".
bltctl() {
    timeout 5s bluetoothctl "$@"
}

# Print the MAC of every known device named exactly $BT_DEVICE_NAME, one per
# line. `bluetoothctl devices` prints lines of the form
#   Device AA:BB:CC:DD:EE:FF Kobo Remote
# An unanchored grep for the name matched any device whose name merely
# contained it, and two matches turned the address into two MACs. Escape
# sequences and carriage returns are stripped first in case bluetoothctl
# decorates its output; the name comes in through the environment because
# awk -v would interpret backslashes in it.
device_macs() {
    bltctl devices 2>/dev/null | BT_NAME="$BT_DEVICE_NAME" awk '
        {
            gsub(/\033\[[0-9;]*[A-Za-z]/, "")
            gsub(/\r/, "")
            i = index($0, "Device ")
            if (i == 0) next
            rest = substr($0, i + 7)
            mac = substr(rest, 1, 17)
            if (mac !~ /^[0-9A-Fa-f][0-9A-Fa-f](:[0-9A-Fa-f][0-9A-Fa-f])+$/) next
            if (substr(rest, 18) == " " ENVIRON["BT_NAME"]) print mac
        }'
}


# Succeed once `bluetoothctl info` reports both Paired: yes and Connected: yes.
# Leaves the last info output in $bond_info so a caller can report the state
# it gave up on.
#
# Polls rather than sampling once. A connect returns as soon as the link is up,
# with encryption and GATT still in flight, so an immediate read reports
# "Paired: no" for a bond that is about to be perfectly fine. Reading it once
# had the unattended reconnect declaring the bond gone five seconds before the
# input device turned up -- and on the menu path that mistake is expensive,
# because it hands over to repair.sh, which removes a working bond to rebuild
# it.
wait_for_bond() {
    bond_info=
    attempt=0
    while [ "$attempt" -lt 5 ]; do
        bond_info=$(bltctl info "$1" 2>&1) || true
        if echo "$bond_info" | grep -q "Paired: yes" && echo "$bond_info" | grep -q "Connected: yes"; then
            return 0
        fi
        # Only the link-up-but-unbonded case is worth waiting on, because that
        # is the one that resolves on its own. If the link itself isn't up,
        # nothing is in flight and every retry just burns another 5s timeout
        # against a remote that isn't answering -- which is most of a minute
        # for an unreachable remote, and the unattended reconnect runs this
        # whenever it can't find one.
        if ! echo "$bond_info" | grep -q "Connected: yes"; then
            return 1
        fi
        attempt=$((attempt + 1))
        if [ "$attempt" -lt 5 ]; then
            sleep 1
        fi
    done
    return 1
}
