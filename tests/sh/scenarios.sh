#!/bin/sh
# Scenarios for the shell scripts, run under busybox sh against the fake Kobo
# in stubs.sh. Each prints a transcript -- the script's stdout (what the popup
# shows), its stderr (what reaches crash.log), its exit code, and a trace of
# what it did to the fake device. The test is that it matches
# tests/expected/sh.txt.
#
# Usage, from the plugin directory: busybox sh tests/sh/scenarios.sh
#
# Each case runs a test copy of the scripts, changed in three ways only:
#   * absolute paths (/sys, /proc, /var/log, the daemons) point into the case's
#     own fake root;
#   * on.sh's two background launches run in the foreground, so a case never
#     depends on timing;
#   * connect.sh hands over to repair.sh in the same shell, where the stubs
#     are, rather than by exec'ing a fresh /bin/sh -- with set +e first, since
#     the exec'd repair.sh doesn't inherit connect.sh's set -e.

REPO=$(pwd)
HERE=$REPO/tests/sh
BB=${BUSYBOX:-busybox}
WORK=$REPO/tests/.work
rm -rf "$WORK"
mkdir -p "$WORK"
n=0

# new_case TITLE: a fresh fake device with the stack running, Bluetooth up,
# the controller powered, and nothing paired.
new_case() {
    n=$((n + 1))
    ROOT=$WORK/case$n
    mkdir -p "$ROOT/plugin" "$ROOT/bt/dev" "$ROOT/hci" "$ROOT/var/log" \
        "$ROOT/sys/devices/platform/bt/rfkill/rfkill0" "$ROOT/sys/class/bluetooth/hci0" \
        "$ROOT/proc/bus/input"
    echo 0 > "$ROOT/clock"
    : > "$ROOT/trace"
    echo yes > "$ROOT/bt/powered"
    : > "$ROOT/bt/devices"
    echo 1 > "$ROOT/sys/devices/platform/bt/rfkill/rfkill0/state"
    printf 'rtk_hciattach -\nbluetoothd -\n' > "$ROOT/procs"
    echo 1 > "$ROOT/hci/attach_ok"
    : > "$ROOT/proc/bus/input/devices"
    : > "$ROOT/proc/modules"
    : > "$ROOT/case.sh"
    cp "$HERE/stubs.sh" "$ROOT/stubs.sh"
    for f in "$REPO"/*.sh "$REPO/device.conf"; do
        # shellcheck disable=SC2016  # $BT_DIR is text to match, not to expand
        sed -e "s#/sys/#$ROOT/sys/#g" -e "s#/proc/#$ROOT/proc/#g" -e "s#/var/log/#$ROOT/var/log/#g" \
            -e "s#/sbin/rtk_hciattach#rtk_hciattach#g" -e "s#/libexec/bluetooth/bluetoothd#bluetoothd#g" \
            -e 's/ 2>&1 &$/ 2>\&1/' \
            -e 's#exec /bin/sh "$BT_DIR/repair.sh"#set +e; . "$BT_DIR/repair.sh"#' \
            "$f" > "$ROOT/plugin/${f##*/}"
    done
    echo
    echo "=== $1"
}

# Hooks and settings for this case, sourced after the stubs.
hooks() { cat >> "$ROOT/case.sh"; }

# A remote BlueZ already knows: add MAC NAME PAIRED CONNECTED [REACHABLE_AT].
known() {
    echo "$1 $2" >> "$ROOT/bt/devices"
    d=$ROOT/bt/dev/$(echo "$1" | tr : _)
    mkdir -p "$d"
    echo "$3" > "$d/paired"
    echo "$4" > "$d/connected"
    echo "${5:-0}" > "$d/reachable_at"
}

# A remote a scan can find: nearby MAC NAME APPEARS_AT REACHABLE_AT.
nearby() { echo "$1|$2|$3|$4" >> "$ROOT/bt/nearby"; }

# An input device listed in /proc/bus/input/devices.
input_device() {
    printf 'N: Name="%s"\nH: Handlers=sysrq kbd %s\n\n' "$1" "$2" >> "$ROOT/proc/bus/input/devices"
}

stack_off() {
    echo 0 > "$ROOT/sys/devices/platform/bt/rfkill/rfkill0/state"
    rmdir "$ROOT/sys/class/bluetooth/hci0"
    : > "$ROOT/procs"
    echo no > "$ROOT/bt/powered"
}

# run SCRIPT ARGS...: run it and print the transcript.
run() {
    script=$1
    shift
    echo "--- $script $*"
    export ROOT
    # shellcheck disable=SC2016  # expanded by the child shell, on purpose
    "$BB" sh -c '. "$ROOT/stubs.sh"; . "$ROOT/case.sh"; . "$0"' \
        "$ROOT/plugin/$script" "$@" > "$ROOT/out" 2> "$ROOT/err"
    code=$?
    sed 's/^/  | /' "$ROOT/out"
    sed -e "s#$ROOT#ROOT#g" -e 's/^/  ! /' "$ROOT/err"
    echo "  exit $code"
    sed 's/^/  ~ /' "$ROOT/trace"
    : > "$ROOT/trace"
}

F3=54:60:14:FE:CA:8C
KR=A4:3C:D7:91:B0:40

# --- lib.sh ------------------------------------------------------------------

lib_probe() {
    cat > "$ROOT/plugin/probe.sh" <<'EOF'
BT_DIR=$(dirname "$0")
. "$BT_DIR/lib.sh"
echo "names: $BT_DEVICE_NAMES"
for name in "Free3-P" "Kobo Remote"; do
    echo "$name: $(device_macs "$name" | tr '\n' ' ')"
done
EOF
}

new_case "lib: exact names, shared prefixes"
lib_probe
known "$F3" "Free3-P" yes no
known 11:11:11:11:11:11 "Free3-P Mouse" no no
known 22:22:22:22:22:22 "Free3-R" yes no
known "$KR" "Kobo Remote" yes no
known 33:33:33:33:33:33 "Kobo Remote" no no
run probe.sh

new_case "lib: no device.conf"
lib_probe
rm "$ROOT/plugin/device.conf"
run probe.sh

new_case "lib: an old single-name device.conf, with a comment"
lib_probe
printf '# BT_DEVICE_NAME="Free3-P"\nBT_DEVICE_NAME="Kobo Remote"\n' > "$ROOT/plugin/device.conf"
run probe.sh

new_case "lib: wait_for_bond, a bond settling on the 7th check"
cat > "$ROOT/plugin/probe.sh" <<'EOF'
BT_DIR=$(dirname "$0")
. "$BT_DIR/lib.sh"
wait_for_bond "$1" && echo "5 tries: bonded" || echo "5 tries: gave up at $(clock)"
wait_for_bond "$1" 10 && echo "10 tries: bonded at $(clock)" || echo "10 tries: gave up"
EOF
known "$F3" "Free3-P" no yes
hooks <<'EOF'
sleep() {
    echo $(( $(clock) + 1 )) > "$ROOT/clock"
    [ "$(clock)" -ge 8 ] && echo yes > "$(dev 54:60:14:FE:CA:8C)/paired"
    return 0
}
EOF
run probe.sh "$F3"

# --- connect.sh --------------------------------------------------------------

new_case "connect: the Free3 answers"
known "$F3" "Free3-P" yes no
known "$KR" "Kobo Remote" yes no
run connect.sh

new_case "connect: the Free3 is off, the Kobo Remote answers"
known "$F3" "Free3-P" yes no 9999
known "$KR" "Kobo Remote" yes no
run connect.sh

new_case "connect: the Kobo Remote lost its bond (battery change)"
known "$KR" "Kobo Remote" yes no
hooks <<'EOF'
# The link comes up but the bond is refused -- until a re-pair makes a new one.
on_connect() {
    echo yes > "$(dev "$1")/connected"
    [ -f "$ROOT/rebonded" ] || echo no > "$(dev "$1")/paired"
    echo "Connection successful"
}
on_pair() {
    : > "$ROOT/rebonded"
    echo yes > "$(dev "$1")/paired"
    echo yes > "$(dev "$1")/connected"
    echo "Pairing successful"
}
EOF
run connect.sh --no-repair
nearby "$KR" "Kobo Remote" 0 0
run connect.sh

new_case "connect: nothing paired"
run connect.sh

new_case "connect: nothing answers"
known "$F3" "Free3-P" yes no 9999
known "$KR" "Kobo Remote" yes no 9999
run connect.sh --no-repair

new_case "connect: only the remotes asked for"
known "$F3" "Free3-P" yes no 9999
known "$KR" "Kobo Remote" yes no
run connect.sh --no-repair "Free3-P"

new_case "connect: the controller is dead"
known "$F3" "Free3-P" yes no
echo yes > "$ROOT/hci/dead"
run connect.sh --no-repair

# --- repair.sh ---------------------------------------------------------------

new_case "repair: already connected and working, left alone"
known "$F3" "Free3-P" yes yes
input_device "Free3-P" event3
run repair.sh "Free3-P"

new_case "repair: connected and bonded but no input device, re-paired"
known "$F3" "Free3-P" yes yes
nearby "$F3" "Free3-P" 0 0
run repair.sh "Free3-P"

new_case "repair: a Free3 dropped by the power cycle (found at 14 s, answers at 45 s)"
known "$F3" "Free3-P" yes yes
nearby "$F3" "Free3-P" 14 45
run repair.sh "Free3-P"

new_case "repair: never found"
run repair.sh "Kobo Remote"

new_case "repair: found but never answers"
nearby "$F3" "Free3-P" 0 9999
run repair.sh

# --- on.sh and off.sh --------------------------------------------------------

new_case "on: from off"
stack_off
run on.sh

new_case "on: restarting a running stack"
hooks <<'EOF'
EXIT_DELAY=2
EOF
run on.sh

new_case "on: a slow attach, inside the wait"
stack_off
hooks <<'EOF'
ATTACH_TIME=8
EOF
run on.sh

new_case "on: the first attach fails, the retry works"
stack_off
echo 2 > "$ROOT/hci/attach_ok"
run on.sh

new_case "on: both attaches fail"
stack_off
: > "$ROOT/hci/attach_ok"
run on.sh

new_case "off"
run off.sh

# --- info.sh -----------------------------------------------------------------

new_case "info: Bluetooth and Wi-Fi on"
echo "8821cs 2105344 0 - Live 0x00000000 (O)" > "$ROOT/proc/modules"
run info.sh

new_case "info: attached but not answering"
echo yes > "$ROOT/hci/dead"
run info.sh

new_case "info: Bluetooth off"
stack_off
run info.sh

rm -rf "$WORK"
