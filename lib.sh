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

