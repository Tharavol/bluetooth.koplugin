-- A fake KOReader for loading the plugin outside a device. Run with the plugin
-- directory as the current directory: main.lua is loaded as "main.lua", so the
-- plugin resolves its directory to "/kodir/", and sibling modules are found
-- through package.path's "./?.lua".
--
-- Everything the plugin touches is faked: the clock and timers, sysfs and
-- /proc, the input devices, the scripts (through Trapper), settings, and the
-- UI. Every visible effect is printed as one transcript line, prefixed with the
-- fake time, so two versions of the plugin can be compared by diffing output.

local Env = {}

local STUB_NAMES = {
    "dispatcher", "ui/widget/infomessage", "ui/uimanager", "ui/widget/container/inputcontainer",
    "device", "ui/event", "ui/trapper", "logger", "gettext", "ffi/util", "ffi",
    "libs/libkoreader-lfs", "ui/elements/reader_menu_order", "ui/elements/filemanager_menu_order",
    "ui/network/manager",
}

local real_open = io.open

function Env.new(opts)
    opts = opts or {}
    local E = {
        clock = opts.start or 1000,
        queue = {},
        seq = 0,
        rfkill = opts.rfkill or "1",
        hci0 = opts.hci0 ~= false,
        proc = opts.proc or {},          -- list of {name=, event=}
        nodes = opts.nodes,              -- set of openable /dev/input paths; nil = all
        conf = opts.conf,                -- device.conf text, nil = missing
        settings = opts.settings or {},
        responders = opts.responders or {},
        fds = {},                        -- fd -> path, for the fake readlink
        next_fd = 10,
        quiet_dbg = opts.quiet_dbg,
        wifi_on = opts.wifi_on ~= false,
    }

    function E.say(fmt, ...)
        print(string.format("[%4d] " .. fmt, E.clock - (opts.start or 1000), ...))
    end

    function E.at(t, f)
        E.seq = E.seq + 1
        table.insert(E.queue, { t = t, seq = E.seq, f = f })
    end

    function E.run(until_t)
        while true do
            table.sort(E.queue, function(a, b)
                if a.t ~= b.t then return a.t < b.t end
                return a.seq < b.seq
            end)
            local job = E.queue[1]
            if not job or job.t > until_t then break end
            table.remove(E.queue, 1)
            if job.t > E.clock then E.clock = job.t end
            job.f()
        end
        if until_t > E.clock then E.clock = until_t end
    end

    -- Fresh modules for every environment: the plugin keeps process-wide
    -- state in module upvalues and in required modules.
    for _, name in ipairs(STUB_NAMES) do
        package.loaded[name] = nil
        package.preload[name] = nil
    end
    for name in pairs(package.loaded) do
        if name:match("^bluetooth") then package.loaded[name] = nil end
    end

    os.time = function() return math.floor(E.clock) end
    os.execute = function(cmd) E.say("EXEC %s", (cmd:gsub("^/bin/sh ", ""))) ; return 0 end

    local S = E.settings
    G_reader_settings = {
        isTrue = function(_, k) return S[k] == true end,
        nilOrTrue = function(_, k) return S[k] == nil or S[k] == true end,
        flipNilOrTrue = function(_, k) if S[k] == nil or S[k] == true then S[k] = false else S[k] = nil end end,
        flipNilOrFalse = function(_, k) if S[k] then S[k] = nil else S[k] = true end end,
        readSetting = function(_, k, d) if S[k] == nil and d ~= nil then S[k] = d end return S[k] end,
        saveSetting = function(_, k, v) S[k] = v end,
        flush = function() E.say("SETTINGS flushed") end,
    }

    package.preload["gettext"] = function() return function(s) return s end end
    package.preload["ffi/util"] = function()
        return { template = function(s, ...)
            local a = { ... }
            return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end))
        end }
    end
    package.preload["libs/libkoreader-lfs"] = function() return { currentdir = function() return "/kodir" end } end
    package.preload["ui/elements/reader_menu_order"] = function() return { setting = { "network", "screen" } } end
    package.preload["ui/elements/filemanager_menu_order"] = function() return { setting = { "network", "screen" } } end

    -- ffi: only what the plugin uses, with readlink answering from E.fds.
    package.preload["ffi"] = function()
        return {
            cdef = function() end,
            new = function() return { value = nil } end,
            string = function(buf) return buf.value end,
            C = { readlink = function(path, buf)
                local fd = tonumber(path:match("/proc/self/fd/(%d+)"))
                local target = E.fds[fd]
                if not target then return -1 end
                buf.value = target
                return #target
            end },
        }
    end

    package.preload["ui/network/manager"] = function()
        return { isWifiOn = function() return E.wifi_on end }
    end

    package.preload["logger"] = function()
        return {
            info = function(m) E.say("INFO %s", m) end,
            dbg = function(m) if not E.quiet_dbg then E.say("DBG  %s", m) end end,
            warn = function(m) E.say("WARN %s", m) end,
        }
    end

    package.preload["ui/uimanager"] = function()
        return {
            scheduleIn = function(_, d, f) E.at(E.clock + d, f) end,
            nextTick = function(_, f) E.at(E.clock, f) end,
            show = function(_, w) E.say("POPUP %s", (tostring(w.text):gsub("\n", " | "))) end,
            sendEvent = function(_, ev) E.say("EVENT %s %s", ev.name, tostring(ev.arg)) end,
        }
    end
    package.preload["ui/event"] = function() return { new = function(_, n, a) return { name = n, arg = a } end } end
    package.preload["ui/widget/infomessage"] = function() return { new = function(_, t) return t end } end
    package.preload["ui/widget/container/inputcontainer"] = function()
        return { extend = function(_, t) return t end }
    end

    package.preload["dispatcher"] = function()
        return {
            registerAction = function() end,
            execute = function(_, actions)
                local names = {}
                for k in pairs(actions) do table.insert(names, k) end
                table.sort(names)
                E.say("DISPATCH %s", table.concat(names, ","))
            end,
            menuTextFunc = function(_, actions)
                local n = 0
                for _ in pairs(actions) do n = n + 1 end
                return n .. " actions"
            end,
            addSubMenu = function(_, caller, items, settings, key)
                table.insert(items, { text = "picker for " .. key })
                settings[key] = settings[key] or {}
                settings[key].toggle_bookmark = true
                caller.updated = true
            end,
        }
    end

    E.input = {
        opened_devices = {},
        registerEventAdjustHook = function(_, f) E.hook = f; E.say("HOOK registered") end,
        open = function(_, path)
            if E.input.opened_devices[path] then return end
            if E.nodes and not E.nodes[path] then error("No such file: " .. path) end
            local fd = E.next_fd
            E.next_fd = E.next_fd + 1
            E.input.opened_devices[path] = fd
            E.fds[fd] = path
            E.say("OPEN %s fd %d", path, fd)
        end,
        close = function(_, path)
            local fd = E.input.opened_devices[path]
            E.input.opened_devices[path] = nil
            if fd then E.fds[fd] = nil end
            E.say("CLOSE %s fd %s", path, tostring(fd))
        end,
    }
    package.preload["device"] = function() return { input = E.input, model = "Kobo_cadmus" } end

    -- Scripts. A responder gets (E, script name, args, background) and returns
    -- output, seconds. Default responders model the stack's own scripts.
    local function respond(script, args, bg)
        local r = E.responders[script]
        if r then return r(E, args, bg) end
        if script == "on.sh" then
            E.rfkill, E.hci0 = "1", true
            return "complete\n", 8
        elseif script == "off.sh" then
            E.rfkill, E.hci0 = "0", false
            return "off\n", 1
        elseif script == "info.sh" then
            return "Controller: Realtek\nBlueZ: 5.63\n", 1
        end
        return "No remote answered. Press a button on it and try again.\n", 10
    end

    package.preload["ui/trapper"] = function()
        local T = {}
        function T.isWrapped() return coroutine.running() ~= nil end
        function T.wrap(_, f)
            local co = coroutine.create(f)
            local ok, err = coroutine.resume(co)
            if not ok then E.say("ERROR %s", tostring(err)) end
        end
        function T.dismissablePopen(_, cmd, trap)
            local body = cmd:match("^out=%$%(/bin/sh (.*)%); printf") or cmd
            local path_and_args = body:gsub("^'/kodir/'", "/kodir/")
            local script, args = path_and_args:match("^/kodir/([%w%._]+)%s*(.*)$")
            local bg = type(trap) == "table"
            E.say("RUN%s %s %s", bg and "(bg)" or "    ", tostring(script), args or "")
            if not bg then E.say("SHOW %s", tostring(trap)) end
            local out, secs = respond(script, args, bg)
            local co = coroutine.running()
            if not co then return true, out end
            E.at(E.clock + (secs or 1), function()
                local ok, err = coroutine.resume(co)
                if not ok then E.say("ERROR %s", tostring(err)) end
            end)
            coroutine.yield()
            E.say("DONE %s", tostring(script))
            return true, out
        end
        return T
    end

    io.open = function(p, m)
        if p == "/kodir/device.conf" then
            if not E.conf then return nil end
            local lines = {}
            for l in (E.conf .. "\n"):gmatch("([^\n]*)\n") do table.insert(lines, l) end
            local i = 0
            return { lines = function() return function() i = i + 1 return lines[i] end end, close = function() end }
        elseif p == "/sys/devices/platform/bt/rfkill/rfkill0/state" then
            return { read = function() return E.rfkill end, close = function() end }
        elseif p == "/sys/class/bluetooth/hci0/uevent" then
            return E.hci0 and { close = function() end } or nil
        elseif p == "/proc/bus/input/devices" then
            local lines = {}
            for _, d in ipairs(E.proc) do
                table.insert(lines, 'N: Name="' .. d.name .. '"')
                table.insert(lines, "H: Handlers=sysrq kbd " .. d.event)
                table.insert(lines, "")
            end
            local i = 0
            return { lines = function() return function() i = i + 1 return lines[i] end end, close = function() end }
        elseif p:match("^/dev/input/") then
            if E.nodes and not E.nodes[p] then return nil end
            return { close = function() end }
        end
        return real_open(p, m)
    end

    io.popen = function(cmd)
        if cmd == "iwconfig" then
            return { read = function() return E.wifi == false and "" or "wlan0 ESSID:\"home\"" end,
                     close = function() end }
        end
        return nil
    end

    function E.load()
        local B = dofile("main.lua")
        E.B = B
        return B
    end

    function E.instance()
        local B = E.B
        B.ui = { menu = { registerToMainMenu = function() end } }
        B:init()
        return B
    end

    function E.press(value, t)
        E.hook(nil, { type = 4, code = 4, value = value,
                      time = { sec = math.floor(t), usec = math.floor((t % 1) * 1e6 + 0.5) } })
    end

    function E.menu()
        local items = {}
        E.B:addToMainMenu(items)
        return items.bluetooth
    end

    return E
end

return Env
