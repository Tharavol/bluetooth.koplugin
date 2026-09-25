--[[--
The Bluetooth stack as the plugin sees it: running the scripts that drive it,
and whether it (and Wi-Fi) is up.

@module koplugin.Bluetooth.stack
--]]--

local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")
local Config = require("bluetooth_config")

local Stack = {}

-- Quote a string for sh: the plugin directory, and remote names passed to a
-- script.
function Stack.shellQuote(str)
    return "'" .. str:gsub("'", "'\\''") .. "'"
end

-- The "widget" for a run nobody should see or be able to cancel. Trapper
-- takes a table as an already-shown widget: it attaches its dismiss_callback
-- and, since it didn't create it, never shows or closes it. This one is never
-- shown, so nothing can dismiss it and every tap goes to the reader as normal.
--
-- Trapper's own invisible widget (passing `true`) is dismissed by any tap, and
-- on the Sage it was: "unattended reconnect was interrupted" and "startup was
-- interrupted" logged together at startup, with both scripts left running
-- unsupervised (#30). A fresh table per run, since Trapper writes into it.
function Stack.BACKGROUND()
    return {}
end

-- Wait `seconds` without stalling the UI. Inside a coroutine (Trapper:wrap),
-- yield and have UIManager resume us; outside one, all that's left is a
-- blocking sleep. Every caller today runs wrapped.
function Stack.pause(seconds)
    local co = coroutine.running()
    if not co then
        os.execute("sleep " .. tonumber(seconds))
        return
    end
    UIManager:scheduleIn(seconds, function() coroutine.resume(co) end)
    coroutine.yield()
end

-- Run a script off the UI thread, showing a dismissable message while it works.
--
-- Returns Trapper's own pair: completed, output. `completed` is false when the
-- message was dismissed, and the script keeps running regardless -- there's no
-- way to call it back, so the output of a dismissed run can't be trusted.
--
-- Callers must take BOTH values: assigning this to a single variable binds
-- the boolean instead of the output, which then blows up on the first
-- result:match(). Trapper:wrap swallows that error into a pcall, so the
-- symptom is nothing happening rather than a traceback.
--
-- `script` is a file name in the plugin directory, and may carry arguments;
-- it is appended to the quoted directory as-is, so the shell reads the two as
-- one word. `message` is what Trapper shows while it works -- a string
-- gets a dismissable widget. Background runs pass BACKGROUND() instead: see
-- there.
--
-- Needs to run inside Trapper:wrap(); outside one, Trapper logs a warning and
-- falls back to a blocking io.popen.
--
-- The script's output is collected by the shell and written in one piece when
-- it exits, always with at least a newline. Trapper decides the script is done
-- by polling the pipe with FIONREAD, and then reads the rest with a blocking
-- read("*all") on the UI thread, which gives two failure modes (#47):
--   * no output at all (off.sh on success): EOF reads as 0 bytes available,
--     so it never completes, and the message stays up until tapped away;
--   * early output (repair.sh relaying bluetoothctl as it goes): the first
--     line counts as done, and the blocking read then freezes the reader for
--     the rest of the script.
-- stderr is left alone and still goes to crash.log.
function Stack.run(script, message)
    local command = "out=$(/bin/sh " .. Stack.shellQuote(Config.PLUGIN_DIR) .. script .. "); printf '%s\\n' \"$out\""
    return Trapper:dismissablePopen(command, message)
end

-- Run a script and wait for it, blocking, with its output discarded. Only for
-- the one place that must not return early: see Bluetooth:onSuspend.
function Stack.runBlocking(script)
    os.execute("/bin/sh " .. Stack.shellQuote(Config.PLUGIN_DIR) .. script .. " >/dev/null 2>&1")
end

function Stack.isBluetoothOn()
    local file = io.open("/sys/devices/platform/bt/rfkill/rfkill0/state", "r")
    if not file then
        return false
    end
    local content = file:read("*line")
    file:close()
    if content ~= "1" then
        return false
    end

    -- rfkill only reports that the radio is unblocked, which it can be at boot
    -- with nothing attached to it. hci0 appears under /sys/class/bluetooth only
    -- once rtk_hciattach has registered the controller, and every sysfs device
    -- directory has a uevent file, so this is the cheap existence check.
    -- (It still reads as "on" for an attached-but-DOWN hci0.)
    local hci = io.open("/sys/class/bluetooth/hci0/uevent", "r")
    if not hci then
        return false
    end
    hci:close()
    return true
end

-- Whether Wi-Fi is on, which Bluetooth needs (#42): the two share the Sage's
-- RTL8821CS, and KOReader's Wi-Fi off cuts the whole chip's power. On, not
-- connected -- only the power matters.
--
-- Asks KOReader, which on a Kobo checks that the Wi-Fi interface exists (it
-- does only while the Wi-Fi driver is loaded). This used to grep iwconfig for
-- "ESSID", which also appears as "ESSID:off/any" on an interface that is up
-- but not associated, and says nothing when there is none.
function Stack.isWifiOn()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr or not NetworkMgr.isWifiOn then
        return true  -- can't tell; let on.sh try
    end
    local ok_on, on = pcall(NetworkMgr.isWifiOn, NetworkMgr)
    return not ok_on or on and true or false
end

return Stack
