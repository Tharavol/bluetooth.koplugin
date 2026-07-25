--[[--
This is a plugin to manage Bluetooth.

@module koplugin.Bluetooth
--]]--

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local Device = require("device")
local EventListener = require("ui/widget/eventlistener")
local Event = require("ui/event")  -- Add this line
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

-- The path we actually have open. The event number moves across reconnects, so
-- closing input_device_path could close something we never opened.
local bt_open_path = nil

-- local Bluetooth = EventListener:extend{
local Bluetooth = InputContainer:extend{
    name = "Bluetooth",
    input_device_path = "/dev/input/event3",  -- Device path
}

function Bluetooth:onDispatcherRegisterActions()
    Dispatcher:registerAction("bluetooth_on_action", {category="none", event="BluetoothOn", title=_("Bluetooth On"), general=true})
    Dispatcher:registerAction("bluetooth_off_action", {category="none", event="BluetoothOff", title=_("Bluetooth Off"), general=true})
    Dispatcher:registerAction("refresh_pairing_action", {category="none", event="RefreshPairing", title=_("Refresh Device Input"), general=true}) -- New action
    Dispatcher:registerAction("connect_to_device_action", {category="none", event="ConnectToDevice", title=_("Connect to Device"), general=true}) -- New action
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

function Bluetooth:executeScript(script)
    local command = "/bin/sh " .. PLUGIN_DIR .. script
    local handle = io.popen(command)
    if not handle then
        -- io.popen can fail outright; without this the :read below would throw
        -- out of the plugin and take KOReader down instead of showing a popup.
        return nil
    end
    local result = handle:read("*a")
    handle:close()
    return result
end

-- The scripts block for several seconds and executeScript reads them to EOF on
-- the UI thread, so paint a message first or the reader just appears frozen.
function Bluetooth:showBusy(text)
    local msg = InfoMessage:new{ text = text }
    UIManager:show(msg)
    UIManager:forceRePaint()
    return msg
end

function Bluetooth:onBluetoothOn()
    local script = self:getScriptPath("on.sh")
    local busy = self:showBusy(_("Starting Bluetooth…"))
    local result = self:executeScript(script)
    UIManager:close(busy)

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
    local script = self:getScriptPath("off.sh")

    -- The uhid device goes away with the stack, so drop our handle first
    -- rather than leaving it open against a device that no longer exists.
    self:closeInputDevice()
    self:executeScript(script)  -- off.sh prints nothing on success

    self:popup(_("Bluetooth turned off."))
end

function Bluetooth:onRefreshPairing()
    if not self:isBluetoothOn() then
        self:popup(_("Bluetooth is off. Please turn it on before refreshing pairing."))
        return
    end
    if self:refreshPairing() then
        self:popup(_("Bluetooth device at ") .. self.input_device_path .. " is now open.")
    end
end

-- Locate the remote's /dev/input/eventN by name. The number is not stable
-- across reconnects, so it has to be resolved every time rather than assumed.
-- Blocks look like:
--   N: Name="Kobo Remote"
--   H: Handlers=sysrq leds event3
function Bluetooth:findInputDevice()
    local f = io.open("/proc/bus/input/devices", "r")
    if not f then
        return nil
    end
    local in_block, path = false, nil
    for line in f:lines() do
        if line:match('^N: Name="') then
            in_block = line:find(BT_DEVICE_NAME, 1, true) ~= nil
        elseif in_block then
            local ev = line:match("^H: Handlers=.*(event%d+)")
            if ev then
                path = "/dev/input/" .. ev
                break
            end
        end
    end
    f:close()
    return path
end

-- Poll for a device node we can actually open.
--
-- /proc/bus/input/devices lists the kernel's input device, but the /dev node
-- is created separately and not at the same instant -- and the entry can be
-- listed while the node is absent entirely. Checking only /proc is what
-- produced "Error opening input device </dev/input/event3>: No such file or
-- directory" on a reconnect.
--
-- Returns the path, or nil plus the path that was listed but not openable, so
-- the caller can tell "remote isn't there" from "node never appeared".
function Bluetooth:waitForInputDevice()
    local listed = nil
    for i = 0, BT_INPUT_WAIT do
        if i > 0 then
            os.execute("sleep 1")
        end
        local path = self:findInputDevice()
        if path then
            listed = path
            local f = io.open(path, "r")
            if f then
                f:close()
                return path
            end
        end
    end
    return nil, listed
end

-- Drop the handle we hold, if any. Safe to call when nothing is open.
function Bluetooth:closeInputDevice()
    if not bt_open_path then
        return
    end
    local closed, close_err = pcall(function() Device.input:close(bt_open_path) end)
    if not closed then
        -- Not fatal, but it means the handle leaked. Log it rather than
        -- swallowing it, so it shows up in crash.log if the call is wrong.
        logger.warn("Bluetooth: could not close " .. bt_open_path .. ": " .. tostring(close_err))
    end
    bt_open_path = nil
end

-- Returns true if the input device was opened. Callers must check it before
-- reporting success: this pops up its own error, and claiming the device is
-- open right after that is the common case when the event number has moved.
function Bluetooth:refreshPairing()
    local path, listed = self:waitForInputDevice()
    if not path then
        if listed then
            self:popup(BT_DEVICE_NAME .. _(" is connected and listed as ") .. listed ..
                       _(", but that device node does not exist."))
        else
            self:popup(_("Could not find ") .. BT_DEVICE_NAME ..
                       _(" in /proc/bus/input/devices. Is it connected?"))
        end
        return false
    end

    -- Close the previous fd before opening a new one. This must happen even
    -- when the path is unchanged: a disconnect destroys the uhid device and
    -- the reconnect can recreate it on the same event number, so the fd we
    -- hold refers to a device that no longer exists. Same path, different
    -- device, no events. Skipping the close here is why a reconnect onto the
    -- same eventN left the remote connected but dead.
    self:closeInputDevice()

    local status, err = pcall(function()
        Device.input:open(path)
    end)
    if not status then
        self:popup(_("Error: ") .. tostring(err))
        return false
    end

    bt_open_path = path
    self.input_device_path = path
    return true
end

function Bluetooth:onDeviceRepair()
    if not self:isBluetoothOn() then
        self:popup(_("Bluetooth is off. Please turn it on before connecting to a device."))
        return
    end
    local script = self:getScriptPath("repair.sh")
    local busy = self:showBusy(_("Pairing with the remote…"))
    local result = self:executeScript(script)
    UIManager:close(busy)

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
    if not self:isBluetoothOn() then
        self:popup(_("Bluetooth is off. Please turn it on before connecting to a device."))
        return
    end

    local script = self:getScriptPath("connect.sh")
    local busy = self:showBusy(_("Connecting to the remote…"))
    local result = self:executeScript(script)
    UIManager:close(busy)

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