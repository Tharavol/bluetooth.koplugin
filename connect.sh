#!/bin/bash

set -e

timeout 5s bluetoothctl power on
device=$(timeout 5s bluetoothctl devices | grep Q36)
bluetooth_address=$(echo "$device" | grep -oE '[0-9A-Fa-f]{2}([-:][0-9A-Fa-f]{2}){5}')
timeout 5s bluetoothctl connect "$bluetooth_address"
