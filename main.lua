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

-- local BTKeyManager = require("BTKeyManager")

local _ = require("gettext")

-- local Bluetooth = EventListener:extend{
local Bluetooth = InputContainer:extend{
    name = "Bluetooth",
    input_device_path = "/dev/input/event4",  -- Device path
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
    local command = "/bin/sh /mnt/onboard/.adds/koreader/plugins/bluetooth.koplugin/" .. script
    local handle = io.popen(command)
    local result = handle:read("*a")
    handle:close()
    return result
end

function Bluetooth:onBluetoothOn()
    local script = self:getScriptPath("on.sh")
    local result = self:executeScript(script)

    if not result or result == "" then
        self:popup(_("Error: No result from the Bluetooth script"))
        return
    end

    if result:match("complete") then
        self:popup(_("Bluetooth turned on."))
    else
        self:popup(_("Result: ") .. result)
    end
end

function Bluetooth:onBluetoothOff()
    local script = self:getScriptPath("off.sh")
    local result = self:executeScript(script)

    self:popup(_("Bluetooth turned off."))
end

function Bluetooth:onRefreshPairing()
    if not self:isBluetoothOn() then
        self:popup(_("Bluetooth is off. Please turn it on before refreshing pairing."))
        return
    end
    self:refreshPairing()
    self:popup(_("Bluetooth device at ") .. self.input_device_path .. " is now open.")
end

function Bluetooth:refreshPairing()
    local status, err = pcall(function()
        -- Ensure the device path is valid
        if not self.input_device_path or self.input_device_path == "" then
            error("Invalid device path")
        end
        -- Device.input:close(self.input_device_path) -- Close the input using the high-level parameter
        Device.input.open(self.input_device_path)  -- Reopen the input using the high-level parameter
    end)
    if not status then
        self:popup(_("Error: ") .. err)
    end
end

function Bluetooth:onDeviceRepair()
    if not self:isBluetoothOn() then
        self:popup(_("Bluetooth is off. Please turn it on before connecting to a device."))
        return
    end
    local script = self:getScriptPath("repair.sh")
    local result = self:executeScript(script)

    -- Simplify the message: focus on the success and device name
    local success = result:match("Connection successful")  -- Check if connection was successful
    if success then
        -- wait one second, then connect to the event fd
        os.execute("sleep 3")
        self:refreshPairing()
        self:popup(_("Connection successful!"))
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
    local result = self:executeScript(script)

    -- Simplify the message: focus on the success and device name
    local success = result:match("Connection successful")  -- Check if connection was successful

    if success then

        -- wait one second, then connect to the event fd
        os.execute("sleep 3")
        self:refreshPairing()

        self:popup(_("Connection successful!"))
    else
        self:popup(_("Result: ") .. result)  -- Show full result for debugging if something goes wrong
    end
end

function Bluetooth:isBluetoothOn()
  local file = io.open("/sys/devices/platform/bt/rfkill/rfkill0/state", "r")
  if file then
    local content = file:read("*line")
    file:close()
    return content == "1"
  end
  return false
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
    local result = handle:read("*a")
    handle:close()

    -- Check if Wi-Fi is enabled by looking for 'ESSID'
    return result:match("ESSID") ~= nil
end


return Bluetooth
