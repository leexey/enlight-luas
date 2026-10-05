local settings = {
    velocity = ui.checkbox("Show Velocity", true),
    previous = ui.combobox("Show Velocity Old", { "None", "Add To Velocity", "New Object" }, 2),
    units = ui.checkbox("Show Units", true),
    vertical = ui.combobox("Show Vert", { "None", "Add To Units", "New Object" }, 2),
    animation = ui.checkbox("Enable Animations", true),
    fade = ui.checkbox("Animate Opacity", true),
    slide = ui.checkbox("Animate Slide", true),
    layout = ui.checkbox("Animate Layout", true),
    duration = ui.slider("Animation Duration (ms)", 50, 1200, 250, 0),
    distance = ui.slider("Slide Distance", 0, 120, 24, 0),
    direction = ui.combobox("Slide Direction", { "From Right", "From Left" }, 1),
    position = ui.slider("Pos Y Divisor", 0.5, 10, 1.2, 2),
    offset_x = ui.slider("Offset X", -500, 500, 0, 0),
    offset_y = ui.slider("Offset Y", -300, 300, 0, 0),
    font_size = ui.slider("Font Size", 12, 48, 24, 0),
    spacing = ui.slider("Line Spacing", 0, 35, 8, 0),
    speed_up = ui.color("Velocity Gain", 25, 255, 100, 255),
    speed_down = ui.color("Velocity Loss", 225, 100, 100, 255),
    speed_same = ui.color("Velocity Neutral", 255, 200, 100, 255),
    old = ui.color("Velocity Old", 200, 200, 200, 255),
    units_color = ui.color("Units", 255, 255, 255, 255),
    vert = ui.color("Vertical", 255, 255, 255, 255)
}

local function rgb(name)
    local r, g, b, a = settings[name]:get()
    return { r, g, b, a }
end
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function round(v) return math.floor(v + 0.5) end
local function lerp(a, b, t) return a + (b - a) * t end
local function smooth(t) t = clamp(t, 0, 1); return t * t * (3 - 2 * t) end

local last_map = engine.get_map()
local old_player, last_command, ground_since, takeoff_origin
local takeoff_speed, old_takeoff_speed, units, vertical = 0, 0, 0, 0
local previous_speed, color_time = 0, 0
local last_frame = nil

local function reset()
    old_player, last_command, ground_since, takeoff_origin = nil, nil, nil, nil
    takeoff_speed, old_takeoff_speed, units, vertical = 0, 0, 0, 0
    previous_speed, color_time = 0, 0
end

local function player_now()
    if not game.is_in_game() then return nil end
    local p = game.get_local_player()
    if not p or not p.alive or p.dormant then return nil end
    return p
end

local function map_check()
    local m = engine.get_map()
    if m ~= last_map then last_map = m; reset() end
end

local function save_distance(origin)
    if not takeoff_origin then return end
    local dx, dy = origin.x - takeoff_origin.x, origin.y - takeoff_origin.y
    units = round(math.sqrt(dx * dx + dy * dy) + 37)
    vertical = round(origin.z - takeoff_origin.z)
    if units > 500 then units, vertical = 0, 0 end
end

events.on("create_move", function(cmd)
    map_check()
    local p = player_now()
    if not p then reset(); return end
    local key = cmd.number ~= 0 and cmd.number or cmd.tick
    if key == last_command then return end
    last_command = key
    local now = utils.get_time()
    local ground = p.flags & flags.on_ground ~= 0
    local v = p.velocity
    local speed = round(vector.length(v, true))
    if p.move_type == move_type.noclip or p.move_type == move_type.ladder or p.move_type == move_type.observer then
        old_player, ground_since, takeoff_origin = nil, nil, nil
        takeoff_speed, old_takeoff_speed, units, vertical = 0, 0, 0, 0
        return
    end
    local old = old_player
    if not old then
        old_player = p
        if ground then ground_since, takeoff_origin = now, p.origin end
    end
    local was_ground = old and old.flags & flags.on_ground ~= 0
    local jump = old and was_ground and not ground
    local jb = old and not was_ground and not ground and old.velocity.z < 0 and v.z > 0
    if ground then
        ground_since = ground_since or now
    else
        if ground_since and now - ground_since > 0.1 then
            takeoff_speed, old_takeoff_speed = 0, 0
        end
        ground_since = nil
    end
    if jump or jb then
        old_takeoff_speed, takeoff_speed = takeoff_speed, speed
        if jb then save_distance(p.origin) end
        takeoff_origin = p.origin
    end
    if ground and old and not was_ground then save_distance(p.origin) end
    if ground and ground_since and now - ground_since > 1.25 then
        takeoff_speed, old_takeoff_speed, units, vertical = 0, 0, 0, 0
    end
    if ground then takeoff_origin = p.origin end
    old_player = p
end)

-- Each visual element has its own transition, including when text changes or disappears.
local nodes = {}
local layout_y = {}
local function animate(id, visible, now)
    local n = nodes[id]
    if not n then
        n = { value = 0, from = 0, target = 0, started = now }
        nodes[id] = n
    end
    local target = visible and 1 or 0
    local enabled = settings.animation:get()
    if not enabled then
        n.value, n.from, n.target, n.started = target, target, target, now
        return target
    end
    local duration = math.max(0.001, settings.duration:get() / 1000)
    local progress = smooth((now - n.started) / duration)
    n.value = lerp(n.from, n.target, progress)
    if n.target ~= target then
        n.from, n.target, n.started = n.value, target, now
    end
    return n.value
end

local function line_y(id, target, now)
    if not settings.animation:get() or not settings.layout:get() then
        layout_y[id] = { y = target, from = target, to = target, start = now }
        return target
    end
    local n = layout_y[id]
    if not n then
        n = { y = target, from = target, to = target, start = now }
        layout_y[id] = n
    end
    local d = math.max(0.001, settings.duration:get() / 1000)
    n.y = lerp(n.from, n.to, smooth((now - n.start) / d))
    if math.abs(n.to - target) > 0.1 then
        n.from, n.to, n.start = n.y, target, now
    end
    return n.y
end

local function draw(x, y, str, tint, opacity, slide_amount, centered)
    if not str or str == "" or opacity <= 0.001 then return end
    local a = clamp(round(opacity * tint[4]), 0, 255)
    local size = settings.font_size:get()
    local center = centered ~= false
    local px = x + slide_amount
    render.text(px + 1, y + 1, str, 0, 0, 0, round(a * 0.55), size, center, true)
    render.text(px, y, str, tint[1], tint[2], tint[3], a, size, center, true)
end

local function effect(value)
    if not settings.animation:get() then return 1, 0 end
    local opacity = settings.fade:get() and value or (value > 0.001 and 1 or 0)
    local sign = settings.direction:get() == 1 and 1 or -1
    local dx = settings.slide:get() and sign * (1 - value) * settings.distance:get() or 0
    return opacity, dx
end

local function speed_tint(speed)
    if speed > previous_speed then return rgb("speed_up") end
    if speed < previous_speed then return rgb("speed_down") end
    return rgb("speed_same")
end

events.on("frame", function()
    map_check()
    local p = player_now()
    if not p then
        reset()
        nodes, layout_y = {}, {}
        return
    end
    local now = utils.get_time()
    local w, h = render.get_screen_size()
    if w <= 0 or h <= 0 then return end
    local x = w / 2 + settings.offset_x:get()
    local y = h / settings.position:get() + settings.offset_y:get() + 10
    local font = settings.font_size:get()
    local line_height = font - 2 + settings.spacing:get()
    local speed = round(vector.length(p.velocity, true))
    if not old_player then
        old_player = p
        if p.flags & flags.on_ground ~= 0 and p.move_type == move_type.walk then
            ground_since, takeoff_origin = now, p.origin
        end
    end
    if ground_since and p.flags & flags.on_ground ~= 0 and now - ground_since > 1.25 then
        takeoff_speed, old_takeoff_speed, units, vertical = 0, 0, 0, 0
    end

    local prev_mode, vert_mode = settings.previous:get(), settings.vertical:get()
    local show_speed = settings.velocity:get()
    local show_old = prev_mode ~= 1 and takeoff_speed > 0
    local show_units = settings.units:get() and takeoff_speed > 0 and units > 100
    local show_vert = vert_mode ~= 1 and takeoff_speed > 0 and math.abs(vertical) > 10
    local old_inline = prev_mode == 2 and show_speed
    local vert_inline = vert_mode == 2 and show_units

    local a_speed = animate("speed", show_speed, now)
    local a_old = animate("old", show_old, now)
    local a_units = animate("units", show_units, now)
    local a_vert = animate("vert", show_vert, now)
    local old_row = prev_mode == 3 or (prev_mode == 2 and not show_speed)
    local vert_row = vert_mode == 3 or (vert_mode == 2 and not show_units)

    local row_speed = y
    local row_old = y + line_height
    local row_units = y + line_height * (1 + (old_row and a_old or 0)) + settings.spacing:get()
    local row_vert = row_units + line_height
    row_speed = line_y("speed", row_speed, now)
    row_old = line_y("old", row_old, now)
    row_units = line_y("units", row_units, now)
    row_vert = line_y("vert", row_vert, now)

    local old_text = "(" .. takeoff_speed .. ")"
    local units_text = units .. " Units"
    local vert_text = (vertical >= 0 and "+" or "") .. vertical .. " Vert"
    local fade_units = clamp(units / 255, 0, 1)
    if ground_since then fade_units = math.min(fade_units, clamp((ground_since + 1.25 - now) * 1000 / 255, 0, 1)) end

    local sa, sx = effect(a_speed)
    local oa, ox = effect(a_old)
    local ua, ux = effect(a_units)
    local va, vx = effect(a_vert)
    local tint = speed_tint(speed)
    local old_tint, units_tint, vert_tint = rgb("old"), rgb("units_color"), rgb("vert")

    local value = tostring(speed)
    local value_width = render.measure_text(value, font)
    local old_width = render.measure_text(old_text, font)
    local gap = 5
    local inline_width = (old_inline and a_old or 0) * (old_width + gap)
    draw(x - inline_width / 2, row_speed, value, tint, sa, sx, true)
    if prev_mode == 2 and show_speed then
        local left = x - (value_width + inline_width) / 2
        draw(left + value_width + gap, row_speed, old_text, old_tint, oa, ox, false)
    elseif old_row then
        draw(x, row_old, old_text, old_tint, oa, ox, true)
    end

    local units_inline_width = (vert_inline and a_vert or 0) * (render.measure_text(" [" .. vert_text .. "]", font))
    draw(x - units_inline_width / 2, row_units, units_text, units_tint, ua * fade_units, ux, true)
    if vert_mode == 2 and show_units then
        local full_width = render.measure_text(units_text, font) + units_inline_width
        local left = x - full_width / 2
        draw(left + render.measure_text(units_text, font), row_units,
            " [" .. vert_text .. "]", vert_tint, va * fade_units, vx, false)
    elseif vert_row then
        draw(x, row_vert, vert_text, vert_tint, va * fade_units, vx, true)
    end
    if now - color_time > 0.064 then previous_speed, color_time = speed, now end
end)

events.on("player_spawn", function(event)
    local p = game.get_local_player()
    if p and event.userid_index == p.index then
        reset()
        nodes, layout_y = {}, {}
    end
end)