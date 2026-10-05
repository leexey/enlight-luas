local ffi = require('ffi')
local enabled = ui.checkbox('Grenade Camera', false)
local CVAR = 'sv_grenade_trajectory_prac_pipreview'
local PATTERN = '32 C0 4C 8D 44 24 30 88 05 ? ? ? ? 48 8D 54 24 40 48 8B CB'
local RENDER_START = 12
local grenade_types = {hegrenade=true,flashbang=true,smokegrenade=true,molotov=true,incgrenade=true,decoy=true}
local flag, active, raised = nil, false, false
local saved_cvar, owns_cvar, cvar_on = nil, false, false
local attempts, next_scan = 0, 0
local scan_tick = 0

local function find_flag()
    if flag then return end
    scan_tick = scan_tick + 1
    if attempts >= 12 or scan_tick < next_scan then return end
    attempts = attempts + 1
    next_scan = scan_tick + 256
    local addr = client.find_pattern('client.dll', PATTERN)
    if not addr then
        if attempts == 12 then print('[Grenade Camera] pattern not found after retries; flag disabled') end
        return
    end
    local ins = ffi.cast('uint8_t*', addr) + 7
    if ins[0] ~= 0x88 or ins[1] ~= 0x05 then
        print('[Grenade Camera] unexpected instruction, flag disabled')
        attempts = 12
        return
    end
    local disp = ffi.cast('int32_t*', ins + 2)[0]
    flag = ffi.cast('uint8_t*', ins + 6 + disp)
    print('[Grenade Camera] flag resolved')
end

local function write_flag(on, force)
    if not flag then return end
    if not force and raised == on then return end
    flag[0] = on and 1 or 0
    raised = on
end

local function set_convar(on)
    if on == cvar_on then return end
    if on then
        if not owns_cvar then
            saved_cvar = cvar.get(CVAR)
            if saved_cvar == nil then return end
            owns_cvar = true
        end
        cvar.set(CVAR, true)
        cvar_on = true
    else
        if owns_cvar then cvar.set(CVAR, saved_cvar) end
        owns_cvar, saved_cvar, cvar_on = false, nil, false
    end
end

local function grenade_active()
    local player = game.get_local_player()
    if not player or not player.alive then return false end
    local index = entity.get_local_player()
    local weapon_index = index and entity.get_player_weapon(index)
    local weapon = weapon_index and entity.get_weapon_state(weapon_index)
    if not weapon or not grenade_types[weapon.type] then return false end
    return weapon.pin_pulled == true or (type(weapon.throw_time) == 'number' and weapon.throw_time > 0)
end

local function restore()
    active = false
    write_flag(false)
    set_convar(false)
end

events.on('create_move', function()
    if not enabled:get() then
        if active or raised or cvar_on then restore() end
        return
    end
    find_flag()
    local now = grenade_active()
    if now ~= active then
        active = now
        set_convar(now)
        write_flag(now)
    end
end)

events.on('frame_stage', function(info)
    if info and info.stage == RENDER_START and active and enabled:get() then
        write_flag(true, true)
    end
end)

events.on('frame', function()
    if not enabled:get() and (active or raised or cvar_on) then restore() end
end)

events.on('unload', restore)