local enabled = ui.checkbox("custom esp", true)
local team = ui.checkbox("show teammates", false)

local show_box = ui.checkbox("show box", true)
local box_color = ui.color("box color", 230, 230, 230, 255)

local show_health = ui.checkbox("show health bar", true)
local health_color = ui.color("health color", 125, 205, 144, 255)

local show_health_bg = ui.checkbox("health background", true)
local health_bg_color = ui.color("background color", 20, 20, 20, 255)

local show_name = ui.checkbox("show name", true)
local name_color = ui.color("name color", 230, 230, 230, 255)

local function update_ui()
    local active = enabled:get()

    box_color:set_visible(active and show_box:get())

    health_color:set_visible(
        active and show_health:get()
    )

    health_bg_color:set_visible(
        active and show_health:get() and show_health_bg:get()
    )

    name_color:set_visible(
        active and show_name:get()
    )
end

events.on("frame", function()
    update_ui()

    if not enabled:get() then return end

    local local_player = game.get_local_player()
    if not local_player then return end

    for _, player in ipairs(game.get_players()) do
        if player.alive
            and not player.is_local
            and not player.dormant
            and (team:get() or player.team ~= local_player.team) then

            local bottom = render.world_to_screen(player.origin)

            local top = render.world_to_screen(
                vector.new(
                    player.origin.x,
                    player.origin.y,
                    player.origin.z + 74
                )
            )

            if top and bottom then
                local height = bottom.y - top.y

                if height > 0 then
                    local width = height * 0.45
                    local x = top.x - width / 2

                    if show_box:get() then
                        local r, g, b, a = box_color:get()

                        render.outline(
                            x, top.y,
                            width, height,
                            r, g, b, a
                        )
                    end

                    if show_health:get() then
                        local health = math.max(
                            0,
                            math.min(player.health, 100)
                        ) / 100

                        if show_health_bg:get() then
                            local r, g, b, a = health_bg_color:get()

                            render.rect(
                                x - 5,
                                top.y,
                                3,
                                height,
                                r, g, b, a
                            )
                        end

                        local r, g, b, a = health_color:get()

                        render.rect(
                            x - 5,
                            bottom.y - height * health,
                            3,
                            height * health,
                            r, g, b, a
                        )
                    end
                    
                    if show_name:get() then
                        local r, g, b, a = name_color:get()

                        render.text(
                            top.x,
                            top.y - 17,
                            player.name,
                            r, g, b, a,
                            14, true, true
                        )
                    end
                end
            end
        end
    end
end)