-- Scenarios for the Lua side of the plugin, run against a fake KOReader
-- (env.lua). Each prints a transcript of everything the plugin does; the test
-- is that it matches tests/expected/lua.txt.
--
-- Usage, from the plugin directory: luajit tests/lua/scenarios.lua
local HERE = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = HERE .. "/?.lua;" .. package.path
local FIXTURES = HERE .. "/../fixtures"
local Env = require("env")

local BOTH = 'BT_DEVICE_NAMES="Free3-P|Kobo Remote"'

local function title(s) print("\n=== " .. s) end

local function menuItem(menu, pattern)
    for _, it in ipairs(menu.sub_item_table) do
        local text = it.text or (it.text_func and it.text_func())
        if text and text:match(pattern) then return it end
    end
end

-- 1. device.conf parsing, seen through the RePair submenu.
for _, conf in ipairs({
    false,
    BOTH,
    '# BT_DEVICE_NAME="Old Remote"\nBT_DEVICE_NAME="Kobo Remote"',
    "BT_DEVICE_NAMES='A|B'\nBT_DEVICE_NAMES=\"C\"",
}) do
    title("names: " .. tostring(conf):gsub("\n", " / "))
    local E = Env.new({ conf = conf or nil, rfkill = "1" })
    E.load()
    local sub = menuItem(E.menu(), "RePair").sub_item_table_func()
    local t = {}
    for _, s in ipairs(sub) do table.insert(t, s.text) end
    print("  " .. table.concat(t, " / "))
end

-- 2. Press pairing, replaying evtest captures.
local function replay(file, E)
    for line in io.lines(FIXTURES .. "/" .. file) do
        local t, kind, v = line:match("^(%S+) (%a) ?(%x*)")
        t = tonumber(t)
        if kind == "M" then
            E.hook(nil, { type = 4, code = 4, value = tonumber(v, 16),
                          time = { sec = math.floor(t), usec = math.floor((t % 1) * 1e6 + 0.5) } })
        elseif kind == "S" then
            E.hook(nil, { type = 0, code = 0, value = 0,
                          time = { sec = math.floor(t), usec = math.floor((t % 1) * 1e6 + 0.5) } })
        end
    end
end
for _, cap in ipairs({ "free3.cap", "kobo.cap", "kobo_nosyn_full.cap", "hold3s.cap", "hold2s.cap" }) do
    title("replay " .. cap)
    local E = Env.new({ conf = BOTH, rfkill = "0", hci0 = false, settings = { bluetooth_autostart = false } })
    E.load(); E.instance()
    replay(cap, E)
end

-- 3. Invert and the third button.
do
    title("invert and third button")
    local E = Env.new({ conf = BOTH, rfkill = "0", hci0 = false, settings = { bluetooth_autostart = false } })
    E.load(); E.instance()
    local menu = E.menu()
    local inv = menuItem(menu, "Invert")
    local t = 100
    local function press(v) E.press(v, t); E.press(v, t + 0.03); t = t + 1 end
    press(0x70051); press(0x70052)
    inv.callback(); print("  inverted: " .. tostring(inv.checked_func()))
    press(0x70051); press(0x70052)
    inv.callback()
    press(0x7002c); E.run(E.clock)
    local third = menuItem(menu, "Third button")
    print("  " .. third.text_func())
    local sub = third.sub_item_table_func()
    print("  " .. sub[1].text .. " / " .. third.text_func())
    press(0x7002c); E.run(E.clock)
    E.B:onFlushSettings()
end

-- 4. Startup: autostart, then the watcher connects.
do
    title("startup")
    local E = Env.new({ conf = BOTH, rfkill = "0", hci0 = false })
    E.responders["connect.sh"] = function(E2)
        if E2.clock - 1000 >= 20 then
            E2.proc = { { name = "Free3-P", event = "event3" } }
            return "Remote: Free3-P\nConnection successful\n", 3
        end
        return "No remote answered. Press a button on it and try again.\n", 5
    end
    E.load(); E.instance(); E.instance()  -- FileManager and ReaderUI
    E.run(E.clock + 60)
end

-- 5. Startup with the option off, and with Bluetooth already on.
do
    title("startup: option off")
    local E = Env.new({ conf = BOTH, rfkill = "0", hci0 = false, settings = { bluetooth_autostart = false } })
    E.load(); E.instance(); E.run(E.clock + 12)
    title("startup: already on, Kobo Remote connected")
    E = Env.new({ conf = BOTH, proc = { { name = "Kobo Remote", event = "event4" } }, quiet_dbg = true })
    E.load(); E.instance(); E.run(E.clock + 70)
end

-- 6. Wake, then a RePair and a menu connect while the fast window runs.
do
    title("resume, repair, connect")
    local E = Env.new({ conf = BOTH, quiet_dbg = true })
    E.responders["repair.sh"] = function() return "Pairing Free3-P did not produce a working bond.\n", 40 end
    E.responders["connect.sh"] = function(_, _args, bg)
        if bg then return "No remote answered. Press a button on it and try again.\n", 12 end
        return "Remote: Kobo Remote\nConnection successful\n", 12
    end
    E.load(); E.instance()
    E.B:onSuspend(); E.B:onResume()
    E.at(E.clock + 35, function() E.B:onDeviceRepair("Free3-P") end)
    E.at(E.clock + 150, function()
        E.proc = { { name = "Kobo Remote", event = "event4" }, { name = "Kobo Remote", event = "event5" } }
        E.B:onConnectToDevice()
    end)
    E.run(E.clock + 320)
end

-- 7. Repair outcomes.
for _, case in ipairs({
    { "success", "Remote: Free3-P\nConnection successful\n" },
    { "already", "Remote: Free3-P\nAlready connected\nConnection successful\n" },
    { "failure", "Pairing Free3-P did not produce a working bond.\n" ..
                 "Failed to pair: org.bluez.Error.ConnectionAttemptFailed\n" },
    { "no node", "Remote: Free3-P\nConnection successful\n", nodes = {} },
}) do
    title("repair: " .. case[1])
    local E = Env.new({ conf = BOTH, proc = { { name = "Free3-P", event = "event3" } }, nodes = case.nodes,
                        settings = { bluetooth_autostart = false }, quiet_dbg = true })
    E.responders["repair.sh"] = function() return case[2], 30 end
    E.load(); E.instance()
    E.at(E.clock + 1, function() E.B:onDeviceRepair("Free3-P") end)
    E.run(E.clock + 45)
end

-- 8. Preference: which remotes the watcher dials.
for _, case in ipairs({
    { "Kobo Remote only", { { name = "Kobo Remote", event = "event4" } } },
    { "Free3 only", { { name = "Free3-P", event = "event3" } } },
    { "none", {} },
}) do
    title("preference: " .. case[1])
    local E = Env.new({ conf = BOTH, proc = case[2], settings = { bluetooth_autostart = false } })
    E.load(); E.instance()
    E.run(E.clock + 16)
end

-- 9. The fd guard: a vanished device whose fd KOReader closed and reused.
do
    title("fd guard")
    local E = Env.new({ conf = BOTH, proc = { { name = "Kobo Remote", event = "event3" },
                                              { name = "Free3-P", event = "event4" } },
                        settings = { bluetooth_autostart = false }, quiet_dbg = true })
    E.load(); E.instance()
    E.run(E.clock + 6)
    -- event3 vanishes; KOReader closed its fd itself, and the number now
    -- belongs to something else.
    E.proc = { { name = "Free3-P", event = "event4" } }
    local fd3 = E.input.opened_devices["/dev/input/event3"]
    E.fds[fd3] = "/dev/input/event9"
    E.run(E.clock + 6)
    print("  entry for event3 left: " .. tostring(E.input.opened_devices["/dev/input/event3"]))
    print("  event4 still open: " .. tostring(E.input.opened_devices["/dev/input/event4"]))
end

-- 10. A dead controller: restart, then rate-limited.
do
    title("dead controller")
    local E = Env.new({ conf = BOTH, settings = { bluetooth_autostart = false }, quiet_dbg = true })
    E.responders["connect.sh"] = function()
        return "The Bluetooth controller is not responding. Toggle Bluetooth off and on.\n", 2
    end
    E.load(); E.instance()
    E.run(E.clock + 200)
end

-- 11. The menu: toggle, Wi-Fi gate, refresh, info, startup option.
do
    title("menu")
    local E = Env.new({ conf = BOTH, rfkill = "0", hci0 = false, settings = { bluetooth_autostart = false },
                        quiet_dbg = true })
    E.load(); E.instance()
    local menu = E.menu()
    local texts = {}
    for _, it in ipairs(menu.sub_item_table) do table.insert(texts, it.text or it.text_func()) end
    print("  " .. table.concat(texts, " / "))
    local toggle = menuItem(menu, "Toggle")
    print("  enabled (off): " .. tostring(menuItem(menu, "Reconnect").enabled_func()))
    E.responders["connect.sh"] = function(E2, _, bg)
        if bg then return "No remote answered. Press a button on it and try again.\n", 5 end
        E2.proc = { { name = "Free3-P", event = "event3" } }
        return "Remote: Free3-P\nConnection successful\n", 4
    end
    toggle.callback()
    E.run(E.clock + 20)
    print("  checked: " .. tostring(toggle.checked_func()))
    menuItem(menu, "Refresh").callback(); E.run(E.clock + 2)
    menuItem(menu, "Bluetooth info").callback(); E.run(E.clock + 2)
    local startup = menuItem(menu, "startup")
    print("  startup: " .. tostring(startup.checked_func()))
    startup.callback(); print("  startup: " .. tostring(startup.checked_func()))
    startup.callback(); print("  startup: " .. tostring(startup.checked_func()))
    toggle.callback()
    E.run(E.clock + 5)
    print("  checked: " .. tostring(toggle.checked_func()))
end

-- 12. Suspend with Bluetooth off does nothing; placement beside Network.
do
    title("suspend while off, menu order")
    local E = Env.new({ conf = BOTH, rfkill = "0", hci0 = false, settings = { bluetooth_autostart = false } })
    E.load(); E.instance()
    E.B:onSuspend(); E.B:onResume(); E.run(E.clock + 3)
    print("  order: " .. table.concat(require("ui/elements/reader_menu_order").setting, ","))
end

-- 13. Wi-Fi. Bluetooth needs it on (#42): Toggle refuses without it, and
-- nothing reacts when it changes -- a known issue, documented rather than
-- handled.
do
    title("wifi off: toggle refuses")
    local E = Env.new({ conf = BOTH, rfkill = "0", hci0 = false, wifi_on = false,
                        settings = { bluetooth_autostart = false }, quiet_dbg = true })
    E.load(); E.instance()
    menuItem(E.menu(), "Toggle").callback()
    E.run(E.clock + 2)
    title("wifi changes while connected: no reaction")
    E = Env.new({ conf = BOTH, proc = { { name = "Free3-P", event = "event3" } },
                  settings = { bluetooth_autostart = false }, quiet_dbg = true })
    E.load(); E.instance()
    E.run(E.clock + 6)
    E.wifi_on = false
    E.run(E.clock + 12)
    E.wifi_on = true
    E.run(E.clock + 12)
end
