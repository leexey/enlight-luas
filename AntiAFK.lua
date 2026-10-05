local enabled    = ui.checkbox("afk enable", false)
local afk_time   = ui.slider("afk time (s)", 1, 300, 30, 0)
local yaw_adjust = ui.slider("afk yaw adjust", -180, 180, 5, 0)

local last_active_time = game.get_time()
local prev_origin      = nil
local prev_pitch       = nil
local prev_yaw         = nil

events.on("create_move", function(cmd)
    if not enabled:get() then return end

    local player = game.get_local_player()
    local now = game.get_time()

    if not player or not player.alive then
        last_active_time = now
        prev_origin = nil
        return
    end

    local pitch, yaw = cmd:get_view_angles()

    if prev_origin == nil then
        prev_origin, prev_pitch, prev_yaw = player.origin, pitch, yaw
        last_active_time = now
        return
    end

    if player.origin ~= prev_origin or pitch ~= prev_pitch or yaw ~= prev_yaw then
        last_active_time = now
    end

    if now - last_active_time > afk_time:get() then
        cmd:set_button(buttons.jump, true)
        yaw = yaw + yaw_adjust:get()
        cmd:set_view_angles(pitch, yaw, false)
        pitch, yaw = cmd:get_view_angles()
    end

    prev_origin = player.origin
    prev_pitch  = pitch
    prev_yaw    = yaw
end)