#!/bin/sh

BT_DIR=$(dirname "$0")
# shellcheck source=lib.sh
. "$BT_DIR/lib.sh"

# repair.sh [NAME]: re-pair that remote, or the first in BT_DEVICE_NAMES. One
# remote only, on purpose -- this removes its bond before rebuilding it.
name=${1:-${BT_DEVICE_NAMES%%|*}}

# shut off the power, make sure its turned off
bltctl power off
sleep 2
# turn back the power, make sure it's come back online
bltctl power on
sleep 2

# Delete every old entry for the remote. A for loop rather than `| while read`,
# which would run the body in a subshell and lose anything it set.
for bluetooth_address in $(device_macs "$name"); do
  echo "Removing $bluetooth_address"
  bltctl remove "$bluetooth_address"
done

# Scan for the remote. bluetoothctl keeps discovery running for as long as it
# runs, so this is a 5 s scan that ends when timeout kills it -- measured on
# the Sage at the full 5 s. Devices it found stay known to bluetoothd after
# discovery stops, which is all the pair below needs. A sleep after it used
# to add 2 s with discovery already off.
bltctl scan on

bluetooth_address=$(device_macs "$name" | head -n 1)
if [ -z "$bluetooth_address" ]; then
    echo "$name not found. Is it on and in pairing mode?"
    exit 1
fi
pair_output=$(bltctl pair "$bluetooth_address" 2>&1) || true
trust_output=$(bltctl trust "$bluetooth_address" 2>&1) || true
connect_output=$(bltctl connect "$bluetooth_address" 2>&1) || true

# Judge the outcome on the verified bond, not on bluetoothctl's word: a connect
# reports success in the Connected: yes / Paired: no state, and a pair or trust
# that failed says nothing about it here. This is the destructive path -- the
# old bond is already gone -- so it is the one that most needs to be sure.
if wait_for_bond "$bluetooth_address"; then
    echo "$pair_output"
    echo "$trust_output"
    echo "$connect_output"
    echo "Remote: $name"
    # main.lua keys off this exact string.
    echo "Connection successful"
    exit 0
fi

echo "Pairing $name did not produce a working bond."
echo "$pair_output"
echo "$trust_output"
# bluetoothctl prints its own "Connection successful", which main.lua would take
# for ours. Keep the rest of the connect output for diagnosis.
echo "$connect_output" | grep -v "Connection successful"
echo "$bond_info" | grep -E "Paired:|Connected:"
exit 1
