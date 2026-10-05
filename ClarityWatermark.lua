local logo_url = "https:" .. "/" .. "/" .. "media.discordapp.net/attachments/1444517539152658432/1556762012350947370/clarity_logo.png?backend=b2&ex=6ac5571a&is=6ac4059a&hm=aa2e4231df6d43e80883695dd2002fc804d8948c11e04f99fea015176ecaa0e6&=&format=png&quality=lossless&width=640&height=640"
assets.prepare({{file = "clarity_logo.png", url = logo_url}})
local logo
if assets.exists("clarity_logo.png") then logo = render.load_image(assets.path("clarity_logo.png")) end

local enabled = ui.checkbox("Watermark", true)
local name = ui.textbox("Username", "username", 64, "Enter a name")
local tag = "clarity"
local logo_size = 60
local font_path = (os.getenv("WINDIR") or "C:\\Windows") .. "\\Fonts\\segoeuib.ttf"
local font, font_attempted
local progress, elapsed = 0, 0
local current_width, target_width, text_height
local pieces

local function update_layout(delta, user)
    local fps = delta > 0 and math.floor(1 / delta) or 0
    pieces = {
        {text = tag, color = {51, 204, 51}, spacing = 2},
        {text = " | ", color = {58, 58, 58}, spacing = 2},
        {text = user, color = {140, 140, 140}, spacing = 2},
        {text = " | ", color = {58, 58, 58}, spacing = 2},
        {text = tostring(fps), color = {255, 255, 255}, spacing = 5},
        {text = "fps", color = {140, 140, 140}, spacing = 0}
    }
    target_width, text_height = 14, 0
    for _, piece in ipairs(pieces) do
        local width, height = render.measure_text(piece.text, 14, font or 0)
        piece.width = width
        target_width = target_width + width + piece.spacing
        text_height = math.max(text_height, height)
    end
    if not current_width then current_width = target_width end
end

events.on("frame", function(delta)
    delta = math.max(delta or 0, 0)
    progress = math.max(0, math.min(1, progress + delta * (enabled:get() and 5 or -5)))
    if progress <= 0 then return end

    if not font_attempted then
        font = render.create_font(font_path, 14)
        font_attempted = true
    end

    elapsed = elapsed + delta
    local user = name:get()
    if user == "" then user = "username" end
    if not pieces or elapsed >= 0.5 or pieces[3].text ~= user then
        update_layout(delta, user)
        elapsed = elapsed % 0.5
    end
    current_width = current_width + (target_width - current_width) * (1 - math.exp(-delta * 10))
    if math.abs(current_width - target_width) < 0.05 then current_width = target_width end

    local screen_width, screen_height = render.get_screen_size()
    if screen_width <= 0 or screen_height <= 0 then return end
    local height = text_height + 16
    local x, y = screen_width - current_width - 7, 7

    render.rect(x, y, current_width, height, 38, 38, 38, 148 * progress, 5)
    render.outline(x, y, current_width, height, 0, 0, 0, 199 * progress, 5, 1)
    render.rect(x + 2, y + 2, current_width - 4, height - 4, 25, 25, 25, 255 * progress, 5)
    render.outline(x + 2, y + 2, current_width - 4, height - 4, 0, 0, 0, 255 * progress, 5, 1)

    local text_x, text_y = x + 7, y + 7
    render.push_clip(x + 5, y + 2, current_width - 10, height - 4)
    local logo_info = logo and render.image_info(logo)
    if logo_info and logo_info.ready then
        render.image(logo, text_x + (pieces[1].width - logo_size) / 3, y + (height - logo_size) / 2 + 3, logo_size, logo_size, 255, 255, 255, 180 * progress)
    end
    render.pop_clip()
    render.push_clip(x + 2, y + 2, current_width - 4, height - 4)
    for _, piece in ipairs(pieces) do
        local color = piece.color
        render.text(text_x, text_y, piece.text, color[1], color[2], color[3], 255 * progress, 14, false, true, font or 0)
        text_x = text_x + piece.width + piece.spacing
    end
    render.pop_clip()
end)
