--[[--
This is a plugin to manage Bluetooth.

@module koplugin.Bluetooth
--]]--

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local InputContainer = require("ui/widget/container/inputcontainer")
local Device = require("device")
local Event = require("ui/event")  -- Add this line
local Trapper = require("ui/trapper")
local logger = require("logger")

-- local BTKeyManager = require("BTKeyManager")

local _ = require("gettext")

-- Module-level state, shared by every instance of this plugin in the process.
-- KOReader init()s plugins once per UI context (FileManager and ReaderUI), and
-- registerEventAdjustHook CHAINS hooks rather than replacing them. Keeping the
-- flag and the debounce table here means only one hook is ever registered, and
-- it debounces against a single shared table.
local bt_hook_registered = false
local bt_last_seen = {}

-- Scancodes reported by the official Kobo Remote (BLE HID-over-GATT).
-- NOTE: these are the values KOReader's own input pipeline sees, which are NOT
-- the same numbers evtest prints for the same button.
local BT_SCAN_FORWARD = 458833
local BT_SCAN_BACK = 458834

-- The remote auto-repeats while a button is held (~150-200ms cadence), so a
-- press must only fire once until a clear gap indicates a genuine release.
local BT_REPEAT_GAP = 0.5

local PLUGIN_DIR = "/mnt/onboard/.adds/koreader/plugins/bluetooth.koplugin/"

-- Seconds to wait for the uhid node after the link comes up.
local BT_INPUT_WAIT = 5

-- Seconds between watcher ticks. The remote can come back without anyone
-- touching the menu: a keypress makes it re-advertise and BlueZ reconnects it
-- unprompted, because repair.sh trusted it.
local BT_WATCH_INTERVAL = 5

-- Only one watcher for the whole process, for the same reason as
-- bt_hook_registered above: init() runs once for FileManager and again for
-- ReaderUI, and two timers would race each other onto the same device.
local bt_watch_scheduled = false

-- Seconds between unattended reconnect attempts. Far slower than the watch
-- tick, because each attempt spawns bluetoothctl and waits on 5 s timeouts,
-- and can only succeed if the remote happens to be advertising right then.
local BT_RECONNECT_INTERVAL = 60

-- When the last unattended attempt started. A timestamp rather than an
-- in-progress flag on purpose: a flag left true by an error would disable
-- reconnection for the rest of the session, while a stale timestamp costs at
-- most one extra attempt. Overlap isn't reachable in practice -- connect.sh's
-- bluetoothctl calls are capped at 5 s each, well inside the interval.
local bt_last_reconnect = 0

-- Read from device.conf so the name lives in one place; the shell scripts
-- source the same file. Falls back to the default if it's missing.
local function readDeviceName()
    local f = io.open(PLUGIN_DIR .. "device.conf", "r")
    if not f then
        return "Kobo Remote"
    end
    local content = f:read("*a")
    f:close()
    return content:match('BT_DEVICE_NAME="([^"]+)"') or "Kobo Remote"
end

local BT_DEVICE_NAME = readDeviceName()

-- The paths we actually have open. Event numbers move across reconnects, so
-- closing whatever /proc lists now could close something we never opened.
local bt_open_paths = {}

-- local Bluetooth = EventListener:extend{
local Bluetooth = InputContainer:extend{
    name = "Bluetooth",
}

function Bluetooth:onDispatcherRegisterActions()
    Dispatcher:registerAction("bluetooth_on_action",
        {category="none", event="BluetoothOn", title=_("Bluetooth On"), general=true})
    Dispatcher:registerAction("bluetooth_off_action",
        {category="none", event="BluetoothOff", title=_("Bluetooth Off"), general=true})
    Dispatcher:registerAction("refresh_pairing_action",
        {category="none", event="RefreshPairing", title=_("Refresh Device Input"), general=true})
    Dispatcher:registerAction("connect_to_device_action",
        {category="none", event="ConnectToDevice", title=_("Connect to Device"), general=true})
end

function Bluetooth:registerKeyEvents()
    self.key_events.BTGotoNextChapter = { { "BTGotoNextChapter" }, event = "BTGotoNextChapter" }
    self.key_events.BTGotoPrevChapter = { { "BTGotoPrevChapter" }, event = "BTGotoPrevChapter" }
    self.key_events.BTDecreaseFontSize = { { "BTDecreaseFontSize" }, event = "BTDecreaseFontSize" }
    self.key_events.BTIncreaseFontSize = { { "BTIncreaseFontSize" }, event = "BTIncreaseFontSize" }
    self.key_events.BTToggleBookmark = { { "BTToggleBookmark" }, event = "BTToggleBookmark" }
    self.key_events.BTIterateRotation = { { "BTIterateRotation" }, event = "BTIterateRotation" }
    self.key_events.BTBluetoothOff = { { "BTBluetoothOff" }, event = "BTBluetoothOff" }
    self.key_events.BTRight = { { "BTRight" }, event = "BTRight" }
    self.key_events.BTLeft = { { "BTLeft" }, event = "BTLeft" }
	self.key_events.BTIncreaseBrightness = { { "BTIncreaseBrightness" }, event = "BTIncreaseBrightness" }
	self.key_events.BTDecreaseBrightness = { { "BTDecreaseBrightness" }, event = "BTDecreaseBrightness" }
	self.key_events.BTIncreaseWarmth = { { "BTIncreaseWarmth" }, event = "BTIncreaseWarmth" }
	self.key_events.BTDecreaseWarmth = { { "BTDecreaseWarmth" }, event = "BTDecreaseWarmth" }
	self.key_events.BTNextBookmark = { { "BTNextBookmark" }, event = "BTNextBookmark" }
	self.key_events.BTPrevBookmark = { { "BTPrevBookmark" }, event = "BTPrevBookmark" }
	self.key_events.BTLastBookmark = { { "BTLastBookmark" }, event = "BTLastBookmark" }
	self.key_events.BTToggleNightMode = { { "BTToggleNightMode" }, event = "BTToggleNightMode" }
	self.key_events.BTToggleStatusBar = { { "BTToggleStatusBar" }, event = "BTToggleStatusBar" }

end


function Bluetooth:onBTGotoNextChapter()
    UIManager:sendEvent(Event:new("GotoNextChapter"))
end

function Bluetooth:onBTGotoPrevChapter()
    UIManager:sendEvent(Event:new("GotoPrevChapter"))
end

function Bluetooth:onBTDecreaseFontSize()
    UIManager:sendEvent(Event:new("DecreaseFontSize", 2))
end

function Bluetooth:onBTIncreaseFontSize()
    UIManager:sendEvent(Event:new("IncreaseFontSize", 2))
end

function Bluetooth:onBTToggleBookmark()
    UIManager:sendEvent(Event:new("ToggleBookmark"))
end

function Bluetooth:onBTIterateRotation()
    UIManager:sendEvent(Event:new("IterateRotation"))
end

function Bluetooth:onBTBluetoothOff()
    UIManager:sendEvent(Event:new("BluetoothOff"))
end

function Bluetooth:onBTRight()
    UIManager:sendEvent(Event:new("GotoViewRel", 1))
end

function Bluetooth:onBTLeft()
    UIManager:sendEvent(Event:new("GotoViewRel", -1))
end

function Bluetooth:onBTIncreaseBrightness()
    UIManager:sendEvent(Event:new("IncreaseFlIntensity", 10))
end

function Bluetooth:onBTDecreaseBrightness()
    UIManager:sendEvent(Event:new("DecreaseFlIntensity", 10))
end

function Bluetooth:onBTIncreaseWarmth()
    UIManager:sendEvent(Event:new("IncreaseFlWarmth", 1))
end

function Bluetooth:onBTDecreaseWarmth()
    UIManager:sendEvent(Event:new("IncreaseFlWarmth", -1))
end

function Bluetooth:onBTNextBookmark()
    UIManager:sendEvent(Event:new("GotoNextBookmarkFromPage"))
end

function Bluetooth:onBTPrevBookmark()
    UIManager:sendEvent(Event:new("GotoPreviousBookmarkFromPage"))
end

function Bluetooth:onBTLastBookmark()
    UIManager:sendEvent(Event:new("GoToLatestBookmark"))
end

function Bluetooth:onBTToggleNightMode()
    UIManager:sendEvent(Event:new("ToggleNightMode"))
end

function Bluetooth:onBTToggleStatusBar()
    UIManager:sendEvent(Event:new("ToggleFooterMode"))
end


function Bluetooth:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    self:registerKeyEvents()

    -- The remote reports button presses as EV_MSC/MSC_SCAN only; the kernel
    -- never synthesises an EV_KEY for these usages, so translate them here.
    if not bt_hook_registered then
        bt_hook_registered = true
        Device.input:registerEventAdjustHook(function(_, ev)
            if ev.type == 4 and ev.code == 4 then  -- EV_MSC, MSC_SCAN
                local now = ev.time.sec + ev.time.usec / 1000000
                local prev = bt_last_seen[ev.value] or 0
                bt_last_seen[ev.value] = now
                if now - prev < BT_REPEAT_GAP then
                    return  -- still inside the same held-button repeat run
                end
                if ev.value == BT_SCAN_FORWARD then
                    UIManager:sendEvent(Event:new("GotoViewRel", 1))
                elseif ev.value == BT_SCAN_BACK then
                    UIManager:sendEvent(Event:new("GotoViewRel", -1))
                end
            end
        end)
    end

    -- Started here rather than from onBluetoothOn so it survives a KOReader
    -- restart with Bluetooth already on, instead of waiting for a toggle.
    -- Guarded, so the second instance doesn't add a second timer.
    self:scheduleWatch()
end

function Bluetooth:addToMainMenu(menu_items)
    menu_items.bluetooth = {
        text = _("Bluetooth"),
        sorting_hint = "network",
        sub_item_table = {
            {
                text = _("Toggle Bluetooth"),
                keep_menu_open = true,
                checked_func = function()
                  return self:isBluetoothOn()
                end,
                callback = function()
                    if not self:isWifiEnabled() then
                        self:popup("Please turn on Wi-Fi to continue.")
                    else
                      if self:isBluetoothOn() then
                        self:onBluetoothOff()
                      else
                        self:onBluetoothOn()
                      end
                    end
                end,
                separator = true,
            },
            {
                text = _("Reconnect to Device"),
                enabled_func = function()
                  return self:isBluetoothOn()
                end,
                callback = function()
                    self:onConnectToDevice()
                end,
            },
            {
                text = _("RePair & Reconnect to Device (long!)"),
                enabled_func = function()
                  return self:isBluetoothOn()
                end,
                callback = function()
                    self:onDeviceRepair()
                end,
            },
            {
                text = _("Refresh Device Input"),
                enabled_func = function()
                  return self:isBluetoothOn()
                end,
                callback = function()
                    self:onRefreshPairing()
                end,
            },
        },
    }
end

function Bluetooth:getScriptPath(script)
    return script
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
-- `script` may carry arguments; it is appended to the interpreter and plugin
-- directory as-is. `message` is what Trapper shows while it works -- a string
-- gets a dismissable widget, and `true` an invisible one that still lets a tap
-- through, which is what the unattended reconnect wants.
--
-- Needs to run inside Trapper:wrap(); outside one, Trapper logs a warning and
-- falls back to a blocking io.popen, which is exactly today's behaviour.
function Bluetooth:executeScript(script, message)
    local command = "/bin/sh " .. PLUGIN_DIR .. script
    return Trapper:dismissablePopen(command, message)
end

function Bluetooth:onBluetoothOn()
    if not Trapper:isWrapped() then
        return Trapper:wrap(function() self:onBluetoothOn() end)
    end

    local script = self:getScriptPath("on.sh")
    local completed, result = self:executeScript(script, _("Starting Bluetooth…"))

    if not completed then
        logger.dbg("Bluetooth: " .. script .. " dismissed or could not be run")
        return
    end

    if not result or result == "" then
        self:popup(_("Error: No result from the Bluetooth script"))
        return
    end

    if result:match("complete") then
        -- on.sh succeeded; go straight into pair/connect so a single menu tap
        -- brings the remote all the way up. onDeviceRepair shows its own popup.
        self:onDeviceRepair()
    else
        self:popup(_("Result: ") .. result)
    end
end

function Bluetooth:onBluetoothOff()
    if not Trapper:isWrapped() then
        return Trapper:wrap(function() self:onBluetoothOff() end)
    end

    local script = self:getScriptPath("off.sh")

    -- The uhid device goes away with the stack, so drop our handle first
    -- rather than leaving it open against a device that no longer exists.
    self:closeInputDevices()

    -- Both return values are ignored on purpose: off.sh prints nothing on
    -- success, and dismissing the message doesn't call the teardown back, so
    -- the stack goes down either way and the popup below stays true.
    self:executeScript(script, _("Turning Bluetooth off…"))

    self:popup(_("Bluetooth turned off."))
end

function Bluetooth:onRefreshPairing()
    if not self:isBluetoothOn() then
        self:popup(_("Bluetooth is off. Please turn it on before refreshing pairing."))
        return
    end
    if self:refreshPairing() then
        self:popup(_("Bluetooth device at ") .. table.concat(bt_open_paths, ", ") .. " is now open.")
    end
end

-- Locate every /dev/input/eventN carrying the remote's name. The numbers are
-- not stable across reconnects, so they have to be resolved every time rather
-- than assumed. Blocks look like:
--   N: Name="Kobo Remote"
--   H: Handlers=sysrq leds event3
--
-- Every match, not the first. BlueZ can leave more than one uhid device for the
-- same remote: the Kobo Remote has shown up on the Sage as two identically
-- named devices, only one of which delivered any events -- and the first match
-- was the dead one, so the remote was connected but turned no pages. A device
-- that never sends anything costs nothing to hold open, so holding them all is
-- the one choice that can't pick wrong.
function Bluetooth:findInputDevices()
    local paths = {}
    local f = io.open("/proc/bus/input/devices", "r")
    if not f then
        return paths
    end
    local in_block = false
    for line in f:lines() do
        local name = line:match('^N: Name="(.*)"%s*$')
        if name then
            -- Exact, like the scripts: a substring match would also take any
            -- other device whose name merely contains the remote's.
            in_block = name == BT_DEVICE_NAME
        elseif in_block then
            local ev = line:match("^H: Handlers=.*(event%d+)")
            if ev then
                table.insert(paths, "/dev/input/" .. ev)
                in_block = false
            end
        end
    end
    f:close()
    return paths
end

-- Poll until every listed device has a node we can actually open.
--
-- /proc/bus/input/devices lists the kernel's input device, but the /dev node
-- is created separately and not at the same instant -- and the entry can be
-- listed while the node is absent entirely. Checking only /proc is what
-- produced "Error opening input device </dev/input/event3>: No such file or
-- directory" on a reconnect.
--
-- Returns the openable paths and the listed ones, so the caller can tell
-- "remote isn't there" (nothing listed) from "node never appeared" (listed,
-- none openable).
function Bluetooth:waitForInputDevices()
    local ready, listed = {}, {}
    for i = 0, BT_INPUT_WAIT do
        if i > 0 then
            os.execute("sleep 1")
        end
        listed, ready = self:findInputDevices(), {}
        for _i, path in ipairs(listed) do
            local f = io.open(path, "r")
            if f then
                f:close()
                table.insert(ready, path)
            end
        end
        if #listed > 0 and #ready == #listed then
            break
        end
    end
    return ready, listed
end

-- Drop one handle we hold. Not fatal if the close fails, but it means the
-- handle leaked, so log it rather than swallowing it -- it shows up in
-- crash.log if the call is wrong.
local function closeInputPath(path)
    local closed, close_err = pcall(function() Device.input:close(path) end)
    if not closed then
        logger.warn("Bluetooth: could not close " .. path .. ": " .. tostring(close_err))
    end
end

-- Drop every handle we hold. Safe to call when nothing is open.
function Bluetooth:closeInputDevices()
    for _i, path in ipairs(bt_open_paths) do
        closeInputPath(path)
    end
    bt_open_paths = {}
end

-- Open one more path alongside whatever we already hold. Returns false plus
-- the error rather than reporting it, so the caller decides whether it deserves
-- a popup: the menu paths want one, the watcher has to stay silent.
function Bluetooth:openInputDevice(path)
    local ok, err = pcall(function()
        Device.input:open(path)
    end)
    if not ok then
        return false, err
    end
    table.insert(bt_open_paths, path)
    return true
end

-- Open exactly these paths, dropping whatever we currently hold first. True
-- if at least one opened; otherwise false plus the last error.
function Bluetooth:reopenInputDevices(paths)
    self:closeInputDevices()
    local last_err
    for _i, path in ipairs(paths) do
        local ok, err = self:openInputDevice(path)
        if not ok then
            last_err = err
        end
    end
    if #bt_open_paths == 0 then
        return false, last_err
    end
    return true
end

-- Notice the remote coming and going without a menu tap.
--
-- Pressing a button makes the remote re-advertise, and BlueZ reconnects it on
-- its own because repair.sh trusted it. The uhid device is recreated with
-- whatever event number happens to be free, so KOReader is left holding an fd
-- to a device that no longer exists -- connected, but dead, until "Refresh
-- Device Input" is tapped. Watching /proc closes that gap.
--
-- Runs against the module table rather than an instance: KOReader tears the
-- plugin down and rebuilds it when moving between FileManager and ReaderUI, so
-- the timer outlives any single self.
-- Ask for the link back without anyone tapping anything.
--
-- BlueZ will not re-dial an LE peripheral: its [Policy] reconnect works by
-- calling a profile's connect method, HoG hasn't got one, and the attempt dies
-- with "Operation not supported". Doing it from here is the only route.
--
-- Always runs connect.sh with --no-repair, so an unattended attempt can never
-- take the destructive path: repair.sh removes the bond before rebuilding it,
-- and a re-pair that doesn't take would leave the remote worse off than it
-- started. Recovering a lost bond stays a deliberate menu tap.
function Bluetooth:tryReconnect()
    local now = os.time()
    if now - bt_last_reconnect < BT_RECONNECT_INTERVAL then
        return
    end
    bt_last_reconnect = now

    -- The tick is a plain timer callback rather than a coroutine, so this needs
    -- its own wrap. Passing `true` asks Trapper for an invisible widget that
    -- still lets a tap through: a background attempt must not put anything on
    -- screen, and if the reader is touched mid-attempt that tap cancels us and
    -- is then delivered normally. The next interval tries again regardless.
    Trapper:wrap(function()
        local completed, result = self:executeScript("connect.sh --no-repair", true)

        -- Every outcome gets a line. Logging only the two recognised ones left
        -- silence meaning both "never ran" and "ran and said something else",
        -- which is not a distinction worth having to guess at from a log.
        if not completed then
            logger.info("Bluetooth: unattended reconnect was interrupted")
        elseif not result then
            logger.info("Bluetooth: unattended reconnect produced no output")
        elseif result:match("Connection successful") then
            -- Opening the input device is left to the next tick, which is what
            -- it's for; the uhid node lags the link coming up anyway.
            logger.info("Bluetooth: reconnected the remote unattended")
        elseif result:match("without a valid bond") then
            logger.info("Bluetooth: the remote is back but its bond is gone; needs a re-pair")
        else
            logger.info("Bluetooth: unattended reconnect did not take: " ..
                        result:gsub("%s+", " "):sub(1, 120))
        end
    end)
end

local function btWatchTick()
    bt_watch_scheduled = false

    if Bluetooth:isBluetoothOn() then
        local paths = Bluetooth:findInputDevices()
        if #paths > 0 then
            -- Reconcile what we hold with what is listed: close what has gone,
            -- open what is new, and leave the rest alone so a live remote isn't
            -- dropped for a moment whenever one of its siblings changes.
            local listed = {}
            for _i, path in ipairs(paths) do
                listed[path] = true
            end
            local kept, held = {}, {}
            for _i, path in ipairs(bt_open_paths) do
                if listed[path] then
                    table.insert(kept, path)
                    held[path] = true
                else
                    logger.info("Bluetooth: watcher closing " .. path .. "; it is no longer listed")
                    closeInputPath(path)
                end
            end
            bt_open_paths = kept
            for _i, path in ipairs(paths) do
                if not held[path] then
                    local ok, err = Bluetooth:openInputDevice(path)
                    if ok then
                        logger.info("Bluetooth: watcher opened the remote at " .. path)
                    else
                        -- Typically the udev lag -- /proc lists the device
                        -- before the node exists. The next tick picks it up,
                        -- so stay quiet.
                        logger.dbg("Bluetooth: watcher could not open " .. path .. ": " .. tostring(err))
                    end
                end
            end
        else
            if #bt_open_paths > 0 then
                -- The remote went away. Drop the handles instead of leaving
                -- them pointing at destroyed uhid devices until the next connect.
                logger.info("Bluetooth: watcher closing " .. table.concat(bt_open_paths, ", ") ..
                            "; the remote is gone")
                Bluetooth:closeInputDevices()
            end
            Bluetooth:tryReconnect()
        end
    end

    Bluetooth:scheduleWatch()
end

-- Ticks even while Bluetooth is off, where the check costs two small sysfs
-- reads: a watcher that stops has to be started again from somewhere, and
-- that's one more thing to get wrong across the two plugin instances.
function Bluetooth:scheduleWatch()
    if bt_watch_scheduled then
        return
    end
    bt_watch_scheduled = true
    UIManager:scheduleIn(BT_WATCH_INTERVAL, btWatchTick)
end

-- Returns true if the input device was opened. Callers must check it before
-- reporting success: this pops up its own error, and claiming the device is
-- open right after that is the common case when the event number has moved.
function Bluetooth:refreshPairing()
    local ready, listed = self:waitForInputDevices()
    if #ready == 0 then
        if #listed > 0 then
            self:popup(BT_DEVICE_NAME .. _(" is connected and listed as ") .. table.concat(listed, ", ") ..
                       _(", but no device node for it exists."))
        else
            self:popup(_("Could not find ") .. BT_DEVICE_NAME ..
                       _(" in /proc/bus/input/devices. Is it connected?"))
        end
        return false
    end

    -- reopenInputDevices closes the previous fds first, which must happen even
    -- when the paths are unchanged: a disconnect destroys the uhid device and
    -- the reconnect can recreate it on the same event number, so the fd we
    -- hold refers to a device that no longer exists. Same path, different
    -- device, no events. Skipping the close here is why a reconnect onto the
    -- same eventN left the remote connected but dead.
    local ok, err = self:reopenInputDevices(ready)
    if not ok then
        self:popup(_("Error: ") .. tostring(err))
        return false
    end

    return true
end

function Bluetooth:onDeviceRepair()
    if not Trapper:isWrapped() then
        return Trapper:wrap(function() self:onDeviceRepair() end)
    end

    if not self:isBluetoothOn() then
        self:popup(_("Bluetooth is off. Please turn it on before connecting to a device."))
        return
    end
    local script = self:getScriptPath("repair.sh")
    local completed, result = self:executeScript(script, _("Pairing with the remote…"))

    if not completed then
        logger.dbg("Bluetooth: " .. script .. " dismissed or could not be run")
        return
    end

    if not result then
        self:popup(_("Error: could not run ") .. script)
        return
    end

    -- Simplify the message: focus on the success and device name
    local success = result:match("Connection successful")  -- Check if connection was successful
    if success then
        -- refreshPairing polls for the uhid node, so no fixed sleep needed
        if self:refreshPairing() then
            self:popup(_("Connection successful!"))
        end
    else
        self:popup(_("Result: ") .. result)  -- Show full result for debugging if something goes wrong
    end
end

function Bluetooth:onConnectToDevice()
    -- Trapper needs a coroutine to yield into. Wrapping here rather than at the
    -- menu callback covers the Dispatcher entry point too, so a gesture bound
    -- to this action gets the same treatment as a menu tap.
    if not Trapper:isWrapped() then
        return Trapper:wrap(function() self:onConnectToDevice() end)
    end

    if not self:isBluetoothOn() then
        self:popup(_("Bluetooth is off. Please turn it on before connecting to a device."))
        return
    end

    local script = self:getScriptPath("connect.sh")
    local completed, result = self:executeScript(script, _("Connecting to the remote…"))

    if not completed then
        -- Dismissed: connect.sh is still running and may yet succeed, so
        -- reporting a failure that hasn't happened would be worse than saying
        -- nothing. A failed popen also lands here and is indistinguishable, so
        -- log it -- silence is the right call for the common case, and the
        -- rare one shouldn't vanish entirely.
        logger.dbg("Bluetooth: " .. script .. " dismissed or could not be run")
        return
    end

    if not result then
        self:popup(_("Error: could not run ") .. script)
        return
    end

    -- Simplify the message: focus on the success and device name
    local success = result:match("Connection successful")  -- Check if connection was successful

    if success then

        -- refreshPairing polls for the uhid node, so no fixed sleep needed
        if self:refreshPairing() then
            self:popup(_("Connection successful!"))
        end
    else
        self:popup(_("Result: ") .. result)  -- Show full result for debugging if something goes wrong
    end
end

function Bluetooth:isBluetoothOn()
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

function Bluetooth:debugPopup(msg)
    self:popup(_("DEBUG: ") .. msg)
end

function Bluetooth:popup(text)
    local popup = InfoMessage:new{
        text = text,
    }
    UIManager:show(popup)
end

function Bluetooth:isWifiEnabled()
    local handle = io.popen("iwconfig")
    if not handle then
        return false
    end
    local result = handle:read("*a")
    handle:close()

    -- Check if Wi-Fi is enabled by looking for 'ESSID'
    return result:match("ESSID") ~= nil
end


return Bluetooth