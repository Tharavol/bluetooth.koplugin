#!/bin/sh

set -e

BT_DIR=$(dirname "$0")
# shellcheck source=lib.sh
. "$BT_DIR/lib.sh"

bltctl power on

# First exact match only. More than one would otherwise become a multi-line
# address that bluetoothctl rejects with an error that reads nothing like the
# actual problem.
bluetooth_address=$(device_macs | head -n 1)
if [ -z "$bluetooth_address" ]; then
    echo "Device not found."
    exit 1
fi

# Try the quick path first: reconnect to the bond we already have. Capture the
# output rather than printing it, so a "Connection successful" from this
# attempt can't be mistaken for overall success if the bond turns out to be
# incomplete and we fall through to a re-pair below.
connect_output=$(bltctl connect "$bluetooth_address" 2>&1) || true

# A reconnect can land in "Connected: yes / Paired: no": the remote comes back
# without re-bonding, BlueZ resolves GAP/GATT but the HID characteristics stay
# inaccessible, and no input device is ever created. The connect itself reports
# success, so the bond has to be checked separately -- and polled, since it
# takes a moment to settle (see wait_for_bond in lib.sh).
if wait_for_bond "$bluetooth_address"; then
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
#
# Unless --no-repair was passed, which is how the unattended reconnect calls
# this. repair.sh removes the bond before rebuilding it, and doing that with
# nobody watching risks leaving the remote worse off than it started if the
# pairing doesn't take. Report the state instead and let the user decide.
if [ "$1" = "--no-repair" ]; then
    echo "Connected without a valid bond."
    exit 1
fi

echo "Connected without a valid bond; re-pairing."
exec /bin/sh "$BT_DIR/repair.sh"
