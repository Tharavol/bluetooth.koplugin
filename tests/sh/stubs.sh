# shellcheck shell=sh
#
# A fake Kobo for the scripts: the commands they run, as shell functions. In
# busybox ash a function wins over a built-in applet of the same name, so these
# stand in for sleep, date, pidof and killall too.
#
# All state lives in files under $ROOT, because the scripts call most of these
# inside $( ), in subshells that can't change the caller's variables:
#
#   clock                    fake seconds; sleep advances it, nothing waits
#   trace                    one line per interesting call, with the clock
#   bt/powered               yes|no, the controller's power
#   bt/devices               "MAC Name" per device BlueZ knows
#   bt/dev/MAC/{paired,connected}   yes|no  (MAC with _ for :; see dev)
#   bt/dev/MAC/reachable_at  clock from which the remote answers pages
#   bt/nearby                "MAC|Name|appears_at|reachable_at" per device a
#                            scan can find: from which clock a scan sees it, and
#                            from which it answers pages
#   bt/scans                 scan rounds so far
#   procs                    running daemons, "name exit_at" (exit_at once killed)
#   hci/attach_ok            attempts of rtk_hciattach that bring hci0 up (e.g. "1 2")
#   hci/attempts             rtk_hciattach runs so far
#   hci/ready_at             clock at which the pending attach creates hci0
#
# The case file sourced after this one may redefine any on_* hook.

clock() { cat "$ROOT/clock"; }

trace() { echo "[$(clock)] $*" >> "$ROOT/trace"; }

# Advance the clock and let the fake hardware catch up with it.
sleep() {
    echo $(( $(clock) + ${1%%[!0-9]*} )) > "$ROOT/clock"
    hw_tick
}

date() {
    case "$1" in
        +%s) clock ;;
        *) echo "12:00:$(clock)" ;;
    esac
}

timeout() { shift; "$@"; }
setsid() { "$@"; }

# --- daemons ---------------------------------------------------------------

proc_start() { echo "$1 -" >> "$ROOT/procs"; }

pidof() {
    [ -f "$ROOT/procs" ] || return 1
    awk -v n="$1" -v t="$(clock)" '$1 == n && ($2 == "-" || $2 > t) { f = 1 } END { exit !f }' "$ROOT/procs"
}

# A killed daemon takes EXIT_DELAY seconds to go (default 1): killall only
# signals, which is what on.sh has to wait out.
killall() {
    [ -f "$ROOT/procs" ] || return 1
    trace "killall $1"
    # The controller goes with the process attaching it.
    [ "$1" = rtk_hciattach ] && rm -rf "$ROOT/sys/class/bluetooth/hci0"
    awk -v n="$1" -v t=$(( $(clock) + ${EXIT_DELAY:-1} )) \
        '$1 == n && $2 == "-" { $2 = t } { print }' "$ROOT/procs" > "$ROOT/procs.new"
    mv "$ROOT/procs.new" "$ROOT/procs"
}

# Attempt N brings hci0 up ATTACH_TIME seconds later (default 3) if N is listed
# in hci/attach_ok; otherwise hci0 never appears. It writes its log only when it
# exits, like the real one.
rtk_hciattach() {
    n=$(( $(cat "$ROOT/hci/attempts" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$ROOT/hci/attempts"
    trace "rtk_hciattach (attempt $n)"
    proc_start rtk_hciattach
    echo "RTK_BT: attempt $n"
    if [ "$(cat "$ROOT/sys/devices/platform/bt/rfkill/rfkill0/state")" = 1 ] &&
        grep -qw "$n" "$ROOT/hci/attach_ok"; then
        echo $(( $(clock) + ${ATTACH_TIME:-3} )) > "$ROOT/hci/ready_at"
        echo "RTK_BT: IC: RTL8821CS"
        echo "RTK_BT: Device setup complete"
    else
        echo never > "$ROOT/hci/ready_at"
        echo "RTK_BT: Retransmission exhausts"
    fi
}

bluetoothd() {
    trace "bluetoothd"
    proc_start bluetoothd
}

hw_tick() {
    ready=$(cat "$ROOT/hci/ready_at" 2>/dev/null)
    if [ -n "$ready" ] && [ "$ready" != never ] && [ "$(clock)" -ge "$ready" ]; then
        mkdir -p "$ROOT/sys/class/bluetooth/hci0"
        echo never > "$ROOT/hci/ready_at"
    fi
}

hciconfig() {
    if [ ! -d "$ROOT/sys/class/bluetooth/hci0" ]; then
        echo "Can't get device info: No such device" >&2
        return 1
    fi
    case "$2" in
        up|down) trace "hciconfig hci0 $2"; return 0 ;;
        version)
            [ "$(cat "$ROOT/hci/dead" 2>/dev/null)" = yes ] && return 1
            printf '%s\n' "hci0:	Type: Primary  Bus: UART" \
                "	BD Address: 58:B0:D4:00:00:01  ACL MTU: 1021:8  SCO MTU: 255:12" \
                "	HCI Version: 4.1 (0x7)  Revision: 0xa99e" \
                "	LMP Version: 4.1 (0x7)  Subversion: 0x8821" \
                "	Manufacturer: Realtek Semiconductor Corporation (93)"
            return 0 ;;
    esac
    echo "hci0:	Type: Primary  Bus: UART"
    if pidof bluetoothd && [ "$(cat "$ROOT/hci/dead" 2>/dev/null)" != yes ]; then
        echo "	UP RUNNING"
    else
        echo "	DOWN"
    fi
}

# --- bluetoothctl ----------------------------------------------------------

# A device's state folder, named after its MAC with _ for : (Windows can't
# have : in a file name, and the tests run there too).
dev() { echo "$ROOT/bt/dev/$(echo "$1" | tr : _)"; }

bt_known() { grep -q "^$1 " "$ROOT/bt/devices" 2>/dev/null; }

# Make MAC known to BlueZ, as a scan that found it would.
bt_add() {
    bt_known "$1" && return
    echo "$1 $2" >> "$ROOT/bt/devices"
    mkdir -p "$(dev "$1")"
    echo no > "$(dev "$1")/paired"
    echo no > "$(dev "$1")/connected"
    echo "${3:-0}" > "$(dev "$1")/reachable_at"
    echo "[NEW] Device $1 $2"
}

bt_forget() {
    grep -v "^$1 " "$ROOT/bt/devices" > "$ROOT/bt/devices.new" 2>/dev/null
    mv "$ROOT/bt/devices.new" "$ROOT/bt/devices"
    rm -rf "$(dev "$1")"
}

reachable() { [ "$(clock)" -ge "$(cat "$(dev "$1")/reachable_at")" ]; }

# Default behaviours; a case file may redefine them.
on_scan() {
    [ -f "$ROOT/bt/nearby" ] || return 0
    while IFS='|' read -r mac name appears reach; do
        if [ "$(clock)" -ge "$appears" ]; then
            bt_add "$mac" "$name" "$reach"
        fi
    done < "$ROOT/bt/nearby"
}

on_connect() {
    if reachable "$1"; then
        echo yes > "$(dev "$1")/connected"
        echo "Connection successful"
    else
        echo "Failed to connect: org.bluez.Error.Failed br-connection-page-timeout"
        return 1
    fi
}

on_pair() {
    if reachable "$1"; then
        echo yes > "$(dev "$1")/paired"
        echo yes > "$(dev "$1")/connected"
        echo "Pairing successful"
    else
        # An unanswered page takes 5 s (hcitool con on the Sage), after which
        # BlueZ drops the device.
        echo $(( $(clock) + 5 )) > "$ROOT/clock"
        echo "Failed to pair: org.bluez.Error.ConnectionAttemptFailed"
        bt_forget "$1"
        return 1
    fi
}

bluetoothctl() {
    case "$1" in
        show)
            echo "Controller 58:B0:D4:00:00:01 (public)"
            echo "	Powered: $(cat "$ROOT/bt/powered")" ;;
        power)
            trace "bluetoothctl power $2"
            [ "$2" = on ] && echo yes > "$ROOT/bt/powered" || echo no > "$ROOT/bt/powered"
            echo "Changing power $2 succeeded" ;;
        devices)
            [ -f "$ROOT/bt/devices" ] && sed 's/^/Device /' "$ROOT/bt/devices" ;;
        info)
            if bt_known "$2"; then
                echo "Device $2 (public)"
                echo "	Paired: $(cat "$(dev "$2")/paired")"
                echo "	Connected: $(cat "$(dev "$2")/connected")"
            else
                echo "Device $2 not available"
                return 1
            fi ;;
        remove)
            trace "bluetoothctl remove $2"
            bt_forget "$2"
            echo "Device has been removed" ;;
        scan)
            n=$(( $(cat "$ROOT/bt/scans" 2>/dev/null || echo 0) + 1 ))
            echo "$n" > "$ROOT/bt/scans"
            trace "bluetoothctl scan (round $n)"
            echo "Discovery started"
            echo $(( $(clock) + 4 )) > "$ROOT/clock"
            on_scan ;;
        pair|trust|connect)
            trace "bluetoothctl $1 $2"
            if ! bt_known "$2"; then
                echo "Device $2 not available"
                return 1
            fi
            case "$1" in
                pair) echo "Attempting to pair with $2"; on_pair "$2" ;;
                trust) echo "Changing $2 trust succeeded" ;;
                connect) echo "Attempting to connect to $2"; on_connect "$2" ;;
            esac ;;
        --version) echo "bluetoothctl: 5.63" ;;
        *) echo "unknown bluetoothctl command $1" >&2; return 1 ;;
    esac
}
