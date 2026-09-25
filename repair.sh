#!/bin/sh

BT_DIR=$(dirname "$0")
# shellcheck source=lib.sh
. "$BT_DIR/lib.sh"

# repair.sh [NAME]: re-pair that remote, or the first in BT_DEVICE_NAMES. One
# remote only, on purpose -- this removes its bond before rebuilding it.
name=${1:-${BT_DEVICE_NAMES%%|*}}

# Cycle the controller's power to start the re-pair from a clean state. Wait
# for each change to show in `bluetoothctl show` rather than sleeping a fixed
# time.
bltctl power off 2>&1 | diag
wait_powered no
bltctl power on 2>&1 | diag
wait_powered yes

# Delete every old entry for the remote. A for loop rather than `| while read`,
# which would run the body in a subshell and lose anything it set.
for bluetooth_address in $(device_macs "$name"); do
  echo "Removing $bluetooth_address" | diag
  bltctl remove "$bluetooth_address" 2>&1 | diag
done

# Scan for the remote. bluetoothctl keeps discovery running for as long as it
# runs, so this is a 5 s scan that ends when timeout kills it -- measured on
# the Sage at the full 5 s. Devices it found stay known to bluetoothd after
# discovery stops, which is all the pair below needs. A sleep after it used
# to add 2 s with discovery already off.
bltctl scan on 2>&1 | diag

bluetooth_address=$(device_macs "$name" | head -n 1)
if [ -z "$bluetooth_address" ]; then
    echo "$name was not found while scanning. Make sure it is on and advertising"
    echo "(on the Kobo Remote, press a button), then try RePair again."
    exit 1
fi
# The pair gets 20 s rather than bltctl's 5. The Free3 takes longer than 5 s to
# finish pairing: on the Sage the timeout killed bluetoothctl partway through
# (no "Pairing successful" or "Failed to pair" in crash.log), RePair reported
# failure a few seconds after its light started blinking, and BlueZ finished
# the bond on its own shortly after.
pair_output=$(bltctl_for 20 pair "$bluetooth_address" 2>&1) || true
trust_output=$(bltctl trust "$bluetooth_address" 2>&1) || true
connect_output=$(bltctl connect "$bluetooth_address" 2>&1) || true

# Judge the outcome on the verified bond, not on bluetoothctl's word: a connect
# reports success in the Connected: yes / Paired: no state, and a pair or trust
# that failed says nothing about it here. This is the destructive path -- the
# old bond is already gone -- so it is the one that most needs to be sure.
# 10 tries rather than 5, for a bond that is still settling after that pair.
if wait_for_bond "$bluetooth_address" 10; then
    printf '%s\n' "$pair_output" "$trust_output" "$connect_output" | diag
    echo "Remote: $name"
    # main.lua keys off this exact string.
    echo "Connection successful"
    exit 0
fi

# The full story goes to crash.log; the popup gets the outcome and the first
# error bluetoothctl reported. Nothing from bluetoothctl reaches stdout here:
# its own "Connection successful" would read to main.lua as ours.
printf '%s\n' "$pair_output" "$trust_output" "$connect_output" "$bond_info" | diag
echo "Pairing $name did not produce a working bond."
reason=$(first_error "$pair_output" "$connect_output")
if [ -n "$reason" ]; then
    echo "$reason"
fi
echo "$bond_info" | grep -E "Paired:|Connected:"
exit 1
