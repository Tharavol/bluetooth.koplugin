-- KOReader runs plugins under LuaJIT.
std = "luajit"

-- Methods are defined with `:` for a uniform call style even when they don't
-- touch the instance, so an unused implicit self is noise, not a finding.
self = false

-- `_` is gettext here, so unused loop indices are spelled `_i` instead.
ignore = { "213/_.*" }

-- KOReader's global settings object.
read_globals = { "G_reader_settings" }
