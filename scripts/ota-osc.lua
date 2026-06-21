local assdraw = require 'mp.assdraw'

local overlay = mp.create_osd_overlay("ass-events")
local hide_timer = nil
local DISPLAY_SECONDS = 7.0
local latest_label = ""

local function ass_escape(text)
    return tostring(text):gsub("\\", "\\\\"):gsub("{", "\\{"):gsub("}", "\\}")
end

local function hide()
    if hide_timer then
        hide_timer:kill()
        hide_timer = nil
    end
    overlay:remove()
end

local function draw_label(label)
    if not label or label == "" then return false end
    label = ass_escape(label)

    local ww, wh = mp.get_osd_size()
    if ww == 0 or wh == 0 then return false end

    local margin_x = math.floor(ww * 0.08)
    local margin_y = math.floor(wh * 0.11)
    local pad_x = math.floor(ww * 0.018)
    local pad_y = math.floor(wh * 0.012)
    local fs = math.max(18, math.floor(wh * 0.065))
    local box_w = math.min(math.floor(ww * 0.72), math.floor(#label * fs * 0.56 + pad_x * 2))
    local box_h = math.floor(fs * 1.35 + pad_y * 2)
    local box_x = ww - margin_x - box_w
    local text_x = ww - margin_x - pad_x

    local ass = assdraw.ass_new()

    ass:new_event()
    ass:pos(box_x, margin_y)
    ass:append("{\\bord0\\shad0\\1c&H000000&\\1a&H55&}")
    ass:draw_start()
    ass:rect_cw(0, 0, box_w, box_h)
    ass:draw_stop()

    ass:new_event()
    ass:append(string.format(
        "{\\an6\\pos(%d,%d)\\fnVCR OSD Mono\\fs%d\\1c&HFFFFFF&\\1a&H00&\\bord0\\shad0}%s",
        text_x,
        margin_y + math.floor(box_h / 2),
        fs,
        label))

    overlay.res_x = ww
    overlay.res_y = wh
    overlay.data = ass.text
    overlay:update()

    if hide_timer then hide_timer:kill() end
    hide_timer = mp.add_timeout(DISPLAY_SECONDS, hide)
    return true
end

local function show_label(label)
    if not label or label == "" then return end
    latest_label = label

    draw_label(label)
    for _, delay in ipairs({0.2, 0.7, 1.4}) do
        mp.add_timeout(delay, function()
            if latest_label == label then
                draw_label(label)
            end
        end)
    end
end

mp.register_script_message("240mp-ota-channel", show_label)

mp.register_event("file-loaded", function()
    local title = mp.get_property("media-title", "")
    if title ~= "" then
        show_label(title)
    end
end)

local function tune_relative(delta)
    mp.commandv("script-message", "240mp-ota-channel-step", tostring(delta))
end

local function tune_now()
    mp.commandv("script-message", "240mp-ota-tune-now")
end

local function tune_last()
    mp.commandv("script-message", "240mp-ota-last-channel")
end

mp.add_forced_key_binding("UP", "ota-channel-up", function() tune_relative(1) end)
mp.add_forced_key_binding("DOWN", "ota-channel-down", function() tune_relative(-1) end)
mp.add_forced_key_binding("LEFT", "ota-last-channel", tune_last)
mp.add_forced_key_binding("PREV", "ota-last-channel-prev", tune_last)
mp.add_forced_key_binding("ENTER", "ota-tune-enter", tune_now)
mp.add_forced_key_binding("KP_ENTER", "ota-tune-kp-enter", tune_now)
mp.add_key_binding("ESC", "ota-esc", function() mp.command("quit") end)
mp.add_key_binding("BS", "ota-bs", function() mp.command("quit") end)
