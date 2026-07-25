#!/bin/bash

set -e

BT_DEVICE_NAME="Kobo Remote"  # fallback if device.conf is missing
# shellcheck source=device.conf
. "$(dirname "$0")/device.conf" 2>/dev/null || true

timeout 5s bluetoothctl power on

# Quote the pattern: unquoted, grep reads "Remote" as a filename and dies.
device=$(timeout 5s bluetoothctl devices | grep "$BT_DEVICE_NAME") || true
if [ -z "$device" ]; then
    echo "Device not found."
    exit 1
fi

bluetooth_address=$(echo "$device" | grep -oE '[0-9A-Fa-f]{2}([-:][0-9A-Fa-f]{2}){5}')

# Try the quick path first: reconnect to the bond we already have. Capture the
# output rather than printing it, so a "Connection successful" from this
# attempt can't be mistaken for overall success if the bond turns out to be
# incomplete and we fall through to a re-pair below.
connect_output=$(timeout 5s bluetoothctl connect "$bluetooth_address" 2>&1) || true

# A reconnect can land in "Connected: yes / Paired: no": the remote comes back
# without re-bonding, BlueZ resolves GAP/GATT but the HID characteristics stay
# inaccessible, and no input device is ever created. The connect itself reports
# success, so the bond has to be checked separately.
info=$(timeout 5s bluetoothctl info "$bluetooth_address" 2>&1) || true

if echo "$info" | grep -q "Paired: yes" && echo "$info" | grep -q "Connected: yes"; then
    # Report on the verified state, not on the connect call. main.lua keys off
    # this exact string, and the connect's own output is not a trustworthy
    # source for it -- a reconnect can fail while the bond is perfectly fine.
    # (BlueZ 5.63 on the Sage returns plain success when the remote is already
    # connected, so this is defensive rather than a bug seen in the wild.)
    # Relay the connect output for diagnostics; let the state have the word.
    echo "$connect_output"
    echo "Connection successful"
    exit 0
fi

# Bond is incomplete. Only a full remove/scan/pair/trust/connect recovers it,
# which is what repair.sh does -- hand over so its output is what gets reported.
echo "Connected without a valid bond; re-pairing."
exec /bin/sh "$(dirname "$0")/repair.sh"
