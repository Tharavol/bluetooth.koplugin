#!/bin/sh

set -e

BT_DIR=$(dirname "$0")
# shellcheck source=lib.sh
. "$BT_DIR/lib.sh"

# connect.sh [--no-repair] [NAME]
# With NAME, only that remote. Without, every remote in BT_DEVICE_NAMES, in
# order, stopping at the first with a working bond.
no_repair=
if [ "$1" = "--no-repair" ]; then
    no_repair=yes
    shift
fi
names=${1:-$BT_DEVICE_NAMES}

bltctl power on 2>&1 | diag

# Split the list on "|" into the positional parameters. Names contain spaces,
# so IFS can't be left at its default for this; globbing is off in case one
# ever contains a * or ?.
set -f
old_ifs=$IFS
IFS='|'
# shellcheck disable=SC2086  # splitting is the point
set -- $names
IFS=$old_ifs
set +f

known=
unbonded_name=
for name in "$@"; do
    # First exact match only. More than one would otherwise become a
    # multi-line address that bluetoothctl rejects with an error that reads
    # nothing like the actual problem.
    bluetooth_address=$(device_macs "$name" | head -n 1)
    if [ -z "$bluetooth_address" ]; then
        continue  # never paired with this one
    fi
    echo "$name: trying $bluetooth_address" | diag
    known=yes

    # Reconnect to the bond we already have. Capture the output rather than
    # printing it, so a "Connection successful" from this attempt can't be
    # mistaken for overall success if the bond turns out to be incomplete.
    connect_output=$(bltctl connect "$bluetooth_address" 2>&1) || true

    # A reconnect can land in "Connected: yes / Paired: no": the remote comes
    # back without re-bonding, BlueZ resolves GAP/GATT but the HID
    # characteristics stay inaccessible, and no input device is ever created.
    # The connect itself reports success, so the bond has to be checked
    # separately -- and polled, since it takes a moment to settle (see
    # wait_for_bond in lib.sh).
    if wait_for_bond "$bluetooth_address"; then
        # Report on the verified state, not on the connect call. main.lua keys
        # off this exact string, and the connect's own output is not a
        # trustworthy source for it -- a reconnect can fail while the bond is
        # perfectly fine. The connect output goes to crash.log for diagnostics;
        # the verified state has the word.
        echo "$connect_output" | diag
        echo "Remote: $name"
        echo "Connection successful"
        exit 0
    fi

    # Link up but no bond: the one case a re-pair fixes. Remember the first,
    # but keep going -- a remote further down the list may be fine as it is.
    if [ -z "$unbonded_name" ] && echo "$bond_info" | grep -q "Connected: yes"; then
        unbonded_name=$name
    fi
done

if [ -n "$unbonded_name" ]; then
    # Only a full remove/scan/pair/trust/connect recovers the bond, which is
    # what repair.sh does -- hand over so its output is what gets reported.
    #
    # Unless --no-repair was passed, which is how the unattended reconnect
    # calls this. repair.sh removes the bond before rebuilding it, and doing
    # that with nobody watching risks leaving the remote worse off than it
    # started if the pairing doesn't take. Report the state instead.
    if [ -n "$no_repair" ]; then
        echo "$unbonded_name connected without a valid bond."
        exit 1
    fi
    echo "$unbonded_name connected without a valid bond; re-pairing."
    exec /bin/sh "$BT_DIR/repair.sh" "$unbonded_name"
fi

if [ -z "$known" ]; then
    echo "No remote is paired yet. Pair one with RePair."
else
    echo "No remote answered. Press a button on it and try again."
fi
exit 1
