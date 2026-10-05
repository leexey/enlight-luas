
local bit = require("bit")

local enabled      = ui.checkbox("Jump Trail", true)
local lifetime     = ui.slider("Trail lifetime (seconds)", 0.1, 10.0, 3.0, 1)
local normal_color = ui.color("Trail color", 0, 255, 0, 255)
local failed_color = ui.color("Trail color if failed", 255, 0, 0, 255)
local thickness    = ui.slider("Trail thickness", 1, 10, 5, 1)
local threshold    = ui.slider("Speed loss threshold", 1, 150, 50, 0)
local sample_ticks = ui.slider("Sample every N ticks", 1, 8, 2, 0)
local fade         = ui.checkbox("Trail fade out", true)

local segments = {}
local previous_origin, previous_speed, previous_tick
local jump_failed = false
local last_sample_tick = nil
local last_tick = nil
local last_map = nil
local MAX_SEGMENTS = 1024

local function reset()
    segments = {}
    previous_origin, previous_speed, previous_tick = nil, nil, nil
    jump_failed = false
    last_sample_tick, last_tick = nil, nil
end

local function copy_vector(v)
    return vector.new(v.x, v.y, v.z)
end

local function ground(flags)
    return bit.band(flags or 0, 1) ~= 0
end

local function valid_movement(move_type)
    return move_type ~= 8 and move_type ~= 9
end

local function prune(now)
    local life = lifetime:get()
    local first = 1
    while first <= #segments and now - segments[first].time >= life do
        first = first + 1
    end
    if first > 1 then
        local kept = {}
        for i = first, #segments do kept[#kept + 1] = segments[i] end
        segments = kept
    end
end

events.on("create_move", function(cmd)
    if not enabled:get() then
        reset()
        return
    end

    local player = game.get_local_player()
    if not player or not player.alive or not player.origin or not player.velocity then
        reset()
        return
    end

    local map = globals.mapname()
    if last_map and map ~= last_map then reset() end
    last_map = map

    local tick = game.get_tick()
    if type(tick) ~= "number" then return end
    if last_tick and (tick < last_tick or tick - last_tick > 128) then reset() end
    if last_tick == tick then return end
    last_tick = tick

    local origin = player.origin
    local speed = player.velocity:length2d()
    local on_ground = ground(player.flags)
    local movement_ok = valid_movement(player.move_type)

    if on_ground then
        previous_origin = nil
        previous_speed = nil
        previous_tick = nil
        last_sample_tick = nil
        jump_failed = false
        return
    end

    if not movement_ok then
        previous_origin = nil
        previous_speed = nil
        previous_tick = nil
        last_sample_tick = nil
        jump_failed = false
        return
    end

    if last_sample_tick and tick - last_sample_tick < math.floor(sample_ticks:get()) then
        return
    end
    last_sample_tick = tick

    if previous_origin and previous_speed then
        if previous_speed - speed >= threshold:get() then
            jump_failed = true
        end
        
        if origin:distance(previous_origin) < 256 then
            local r, g, b, a
            if jump_failed then
                r, g, b, a = failed_color:get()
            else
                r, g, b, a = normal_color:get()
            end
            segments[#segments + 1] = {
                from = previous_origin,
                to = copy_vector(origin),
                time = globals.realtime(),
                r = r, g = g, b = b, a = a
            }
            if #segments > MAX_SEGMENTS then table.remove(segments, 1) end
        end
    end

    previous_origin = copy_vector(origin)
    previous_speed = speed
    previous_tick = tick
end)

events.on("frame", function(dt)
    if not enabled:get() then
        if #segments > 0 then reset() end
        return
    end

    local now = globals.realtime()
    prune(now)
    local life = lifetime:get()
    local width = thickness:get()
    for i = 1, #segments do
        local s = segments[i]
        local alpha = s.a
        if fade:get() then
            alpha = math.floor(alpha * math.max(0, 1 - (now - s.time) / life) + 0.5)
        end
        if alpha > 0 then
            renderer.polyline_3d({s.from, s.to}, s.r, s.g, s.b, alpha, width)
        end
    end
end)

events.on("unload", reset)
