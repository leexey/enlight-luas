local enabled = ui.checkbox("remove legs", false)

local name = "cl_firstperson_legs"
local original = cvar.get_bool(name)
local previous = nil

events.on("frame", function()
    local active = enabled:get()

    if active == previous then return end
    previous = active

    cvar.set(name, not active)
end)

events.on("unload", function()
    if original ~= nil then
        cvar.set(name, original)
    end
end)