local assdraw = require 'mp.assdraw'

local overlay = mp.create_osd_overlay("ass-events")
local hide_timer = nil
local loaded = false

local C_WHITE = "&HFFFFFF&"
local C_BLACK = "&H000000&"
local C_BLUE  = "&HA81E00&"
local A_OPAQUE = "&H00&"
local A_BOX = "&H55&"

local function ass_escape(text)
    return tostring(text or ""):gsub("\\", "\\\\"):gsub("{", "\\{"):gsub("}", "\\}")
end

local function hide()
    if hide_timer then
        hide_timer:kill()
        hide_timer = nil
    end
    overlay:remove()
end

local function draw_rect(ass, x, y, w, h, colour, alpha)
    ass:new_event()
    ass:pos(x, y)
    ass:append(string.format("{\\bord0\\shad0\\1c%s\\1a%s}", colour, alpha))
    ass:draw_start()
    ass:rect_cw(0, 0, w, h)
    ass:draw_stop()
end

local function draw_text(ass, x, y, anchor, text, fs, colour)
    ass:new_event()
    ass:append(string.format(
        "{\\an%d\\pos(%d,%d)\\fnVCR OSD Mono\\fs%d\\1c%s\\1a%s\\bord0\\shad0}%s",
        anchor, x, y, fs, colour, A_OPAQUE, ass_escape(text)))
end

local function show_status(label, detail, seconds)
    label = tostring(label or ""):upper()
    detail = tostring(detail or ""):upper()
    if label == "" then return end

    local ww, wh = mp.get_osd_size()
    if ww == 0 or wh == 0 then return end

    local margin_x = math.floor(ww * 0.075)
    local y = math.floor(wh * 0.095)
    local x = ww - margin_x
    local fs = math.max(22, math.floor(wh * 0.075))
    local detail_fs = math.max(14, math.floor(wh * 0.0333333))
    local box_w = math.min(math.floor(ww * 0.48), math.floor(math.max(#label * fs * 0.55, #detail * detail_fs * 0.55) + ww * 0.05))
    local box_h = detail ~= "" and math.floor(fs * 1.75) or math.floor(fs * 1.2)
    local box_x = x - box_w
    local box_y = y - math.floor(fs * 0.45)

    local ass = assdraw.ass_new()
    draw_rect(ass, box_x, box_y, box_w, box_h, C_BLACK, A_BOX)
    draw_text(ass, x - math.floor(ww * 0.02), y, 6, label, fs, C_WHITE)
    if detail ~= "" then
        draw_text(ass, x - math.floor(ww * 0.02), y + math.floor(fs * 0.72), 6, detail, detail_fs, C_WHITE)
    end

    overlay.res_x = ww
    overlay.res_y = wh
    overlay.data = ass.text
    overlay:update()

    if hide_timer then hide_timer:kill() end
    hide_timer = mp.add_timeout(seconds or 1.8, hide)
end

mp.register_script_message("240mp-vcr-status", function(label, detail)
    show_status(label, detail or "", 1.8)
end)

mp.register_event("file-loaded", function()
    loaded = true
    local input = (mp.get_opt("vcr-input") or "VIDEO 1"):upper()
    local title = (mp.get_property("media-title", "") or ""):upper()
    show_status(input, title, 2.4)
end)

mp.register_event("end-file", function()
    loaded = false
    hide()
end)

mp.observe_property("pause", "bool", function(_, paused)
    if not loaded then return end
    if paused then
        show_status("PAUSE", "", 2.0)
    else
        show_status("PLAY", "", 1.2)
    end
end)
