local assdraw = require 'mp.assdraw'
local options = require 'mp.options'

local opts = {
    show_label = "yes",
    show_top_label = "yes",
    show_initial_label = "no",
    control_mode = "ota",
    start_black = "no",
}
options.read_options(opts, "240mp-ota")
options.read_options(opts, "ttota")

local overlay = mp.create_osd_overlay("ass-events")
local transition_overlay = mp.create_osd_overlay("ass-events")
local hide_timer = nil
local menu_timer = nil
local DISPLAY_SECONDS = 7.0
local MENU_SECONDS = 7.0
local TEXT_WIDTH_FACTOR = 0.68
local latest_label = ""
local latest_stream_info = ""
local menu_visible = false
local quiet_next_file = false
local transition_pending = false
local C_WHITE = "&HFFFFFF&"
local C_ORANGE = "&H0078FF&"

local function labels_enabled()
    local value = tostring(opts.show_label or "yes"):lower()
    return value ~= "no" and value ~= "false" and value ~= "0" and value ~= "off"
end

local function top_label_enabled()
    local value = tostring(opts.show_top_label or opts.show_label or "yes"):lower()
    return value ~= "no" and value ~= "false" and value ~= "0" and value ~= "off"
end

local function ota_controls_enabled()
    return tostring(opts.control_mode or "ota"):lower() == "ota"
end

local function option_enabled(value)
    value = tostring(value or "no"):lower()
    return value == "yes" or value == "true" or value == "1" or value == "on"
end

local function initial_label_enabled()
    return option_enabled(opts.show_initial_label)
end

local function show_transition_black()
    transition_pending = true
    local ww, wh = mp.get_osd_size()
    if ww == 0 or wh == 0 then return end

    local ass = assdraw.ass_new()
    ass:new_event()
    ass:pos(0, 0)
    ass:append("{\\an7\\bord0\\shad0\\1c&H000000&\\1a&H00&}")
    ass:draw_start()
    ass:rect_cw(0, 0, ww, wh)
    ass:draw_stop()
    transition_overlay.res_x = ww
    transition_overlay.res_y = wh
    transition_overlay.data = ass.text
    transition_overlay:update()
end

local function hide_transition_black()
    transition_pending = false
    transition_overlay:remove()
end

local function ass_escape(text)
    return tostring(text):gsub("\\", "\\\\"):gsub("{", "\\{"):gsub("}", "\\}")
end

local function estimated_text_width(text, fs)
    return math.floor(#tostring(text or "") * fs * TEXT_WIDTH_FACTOR)
end

local function fit_text(text, max_w, fs)
    local value = tostring(text or ""):upper()
    if value == "" then return "" end

    local max_chars = math.floor(max_w / (fs * TEXT_WIDTH_FACTOR))
    if #value <= max_chars then return value end
    if max_chars <= 3 then return value:sub(1, math.max(0, max_chars)) end
    return value:sub(1, max_chars - 3) .. "..."
end

local function hide()
    if hide_timer then
        hide_timer:kill()
        hide_timer = nil
    end
    if menu_timer then
        menu_timer:kill()
        menu_timer = nil
    end
    menu_visible = false
    overlay:remove()
end

local function draw_solid_box(ass, x, y, w, h, color, alpha)
    ass:new_event()
    ass:pos(x, y)
    ass:append(string.format("{\\bord0\\shad0\\1c%s\\1a%s}",
                             color or "&H000000&", alpha or "&H55&"))
    ass:draw_start()
    ass:rect_cw(0, 0, w, h)
    ass:draw_stop()
end

local function draw_box(ass, x, y, w, h, alpha)
    draw_solid_box(ass, x, y, w, h, "&H000000&", alpha)
end

local function draw_channel_box(ass, x, y, w, h, border)
    local line = math.max(1, border or 1)
    draw_solid_box(ass, x, y, w, h, "&H000000&", "&H9F&")
    draw_solid_box(ass, x, y, w, line, C_WHITE, "&H00&")
    draw_solid_box(ass, x, y + h - line, w, line, C_WHITE, "&H00&")
    draw_solid_box(ass, x, y, line, h, C_WHITE, "&H00&")
    draw_solid_box(ass, x + w - line, y, line, h, C_WHITE, "&H00&")
end

local function draw_text(ass, x, y, anchor, text, fs, color)
    ass:new_event()
    ass:append(string.format(
        "{\\an%d\\pos(%d,%d)\\fnVCR OSD Mono\\fs%d\\1c%s\\1a&H00&\\bord0\\shad0}%s",
        anchor,
        x,
        y,
        fs,
        color or C_WHITE,
        ass_escape(text)))
end

local function channel_label_layout(ww, wh, label)
    local margin_x = math.floor(ww * 0.07)
    local margin_y = math.floor(wh * 0.09)
    local pad_x = math.floor(ww * 0.02)
    local fs = math.max(18, math.floor(wh * 0.055))
    local min_box_w = math.floor(ww * 0.18)
    local max_box_w = math.floor(ww * 0.66)
    local display_label = fit_text(label, max_box_w - pad_x * 2, fs)
    local box_w = math.min(max_box_w,
                           math.max(min_box_w,
                                    estimated_text_width(display_label, fs) + pad_x * 2))
    local box_h = math.floor(wh * 0.085)
    local box_x = ww - margin_x - box_w
    return {
        text = display_label,
        x = box_x,
        y = margin_y,
        w = box_w,
        h = box_h,
        fs = fs,
        text_x = box_x + math.floor(box_w / 2),
        border = math.max(1, math.floor(wh * 0.004)),
    }
end

local function append_channel_label(ass, layout)
    draw_channel_box(ass, layout.x, layout.y, layout.w, layout.h, layout.border)
    draw_text(ass, layout.text_x, layout.y + math.floor(layout.h / 2),
              5, layout.text, layout.fs)
end

local function draw_button(ass, x, y, w, h, label, fs)
    draw_box(ass, x, y, w, h, "&H55&")
    draw_text(ass, x + math.floor(w / 2), y + math.floor(h / 2), 5, label, fs)
end

local function draw_overlay(label, with_menu, force_top_label)
    if not label or label == "" then return false end

    local ww, wh = mp.get_osd_size()
    if ww == 0 or wh == 0 then return false end

    local show_top_label = force_top_label or top_label_enabled()
    if not show_top_label and not with_menu then
        overlay:remove()
        return false
    end

    local layout = channel_label_layout(ww, wh, label)

    local ass = assdraw.ass_new()

    if show_top_label then
        append_channel_label(ass, layout)
    end

    if with_menu then
        local lm = math.floor(ww * 0.12)
        local rm = math.floor(ww * 0.88)
        local menu_w = rm - lm
        local menu_fs = math.max(14, math.floor(wh * 0.0333333))
        local title_fs = math.max(18, math.floor(wh * 0.05))
        local info_fs = math.max(13, math.floor(wh * 0.028))
        local menu_y = math.floor(wh * 0.66)
        local menu_h = math.floor(wh * 0.23)
        local title_y = menu_y + math.floor(menu_h * 0.20)
        local info_y = menu_y + math.floor(menu_h * 0.42)
        local btn_y = menu_y + math.floor(menu_h * 0.64)
        local btn_h = math.floor(menu_fs * 1.65)
        local gap = math.floor(menu_w * 0.025)
        local btn_w = math.floor((menu_w - gap * 3) / 4)
        local inner_l = lm + math.floor(menu_w * 0.03)
        local inner_r = rm - math.floor(menu_w * 0.03)
        local info = latest_stream_info ~= "" and latest_stream_info or "SERVER INFO WAITING"

        draw_box(ass, lm, menu_y, menu_w, menu_h, "&H66&")
        draw_text(ass, inner_l, title_y, 4, "THE TUBE", title_fs, C_ORANGE)
        draw_text(ass, inner_r, title_y, 6,
                  fit_text(label, math.floor(menu_w * 0.52), menu_fs), menu_fs)
        draw_text(ass, inner_l, info_y, 4,
                  fit_text(info, math.floor(menu_w * 0.94), info_fs), info_fs)

        local bx = inner_l
        local usable_w = menu_w - math.floor(menu_w * 0.06)
        btn_w = math.floor((usable_w - gap * 3) / 4)
        local ota_controls = ota_controls_enabled()
        draw_button(ass, bx, btn_y, btn_w, btn_h, ota_controls and "CH +" or "REW", menu_fs)
        bx = bx + btn_w + gap
        draw_button(ass, bx, btn_y, btn_w, btn_h, ota_controls and "CH -" or "FF", menu_fs)
        bx = bx + btn_w + gap
        draw_button(ass, bx, btn_y, btn_w, btn_h, "MENU", menu_fs)
        bx = bx + btn_w + gap
        draw_button(ass, bx, btn_y, btn_w, btn_h, "BACK", menu_fs)
    end

    overlay.res_x = ww
    overlay.res_y = wh
    overlay.data = ass.text
    overlay:update()

    if hide_timer then hide_timer:kill() end
    hide_timer = mp.add_timeout(DISPLAY_SECONDS, hide)
    return true
end

local function render_tuning_transition(label)
    local ww, wh = mp.get_osd_size()
    if ww == 0 or wh == 0 then return false end

    local ass = assdraw.ass_new()
    ass:new_event()
    ass:pos(0, 0)
    ass:append("{\\an7\\bord0\\shad0\\1c&H000000&\\1a&H00&}")
    ass:draw_start()
    ass:rect_cw(0, 0, ww, wh)
    ass:draw_stop()
    append_channel_label(ass, channel_label_layout(ww, wh, label))

    transition_pending = true
    transition_overlay.res_x = ww
    transition_overlay.res_y = wh
    transition_overlay.data = ass.text
    transition_overlay:update()

    -- Keep the transparent playback label ready underneath the tuning screen.
    -- Removing the tuning layer then reveals it without a blank frame.
    draw_overlay(label, false, true)
    return true
end

local function start_label_timeout()
    if hide_timer then hide_timer:kill() end
    hide_timer = mp.add_timeout(DISPLAY_SECONDS, function()
        hide_timer = nil
        if transition_pending then
            return
        end
        if not menu_visible then
            overlay:remove()
        end
    end)
end

local function show_label(label)
    if not label or label == "" then return end
    latest_label = label

    if not top_label_enabled() and not menu_visible then
        overlay:remove()
        return
    end

    draw_overlay(label, menu_visible)
    if not menu_visible then
        start_label_timeout()
    end
    for _, delay in ipairs({0.2, 0.7, 1.4}) do
        mp.add_timeout(delay, function()
            if latest_label == label then
                draw_overlay(label, menu_visible)
            end
        end)
    end
end

local function show_tuned_channel(label)
    if not label or label == "" then return end
    latest_label = label
    draw_overlay(label, menu_visible, true)
    start_label_timeout()
    for _, delay in ipairs({0.2, 0.7, 1.4}) do
        mp.add_timeout(delay, function()
            if latest_label == label then
                draw_overlay(label, menu_visible, true)
            end
        end)
    end
end

local function show_tuning_transition(label)
    if not label or label == "" then return end
    latest_label = label
    if menu_timer then
        menu_timer:kill()
        menu_timer = nil
    end
    menu_visible = false
    render_tuning_transition(label)
    start_label_timeout()
end

local function hide_menu()
    if menu_timer then
        menu_timer:kill()
        menu_timer = nil
    end
    menu_visible = false
    if latest_label ~= "" then
        draw_overlay(latest_label, false)
        start_label_timeout()
    else
        overlay:remove()
    end
end

local function show_menu()
    local title = mp.get_property("media-title", "")
    if latest_label == "" and title ~= "" then
        latest_label = title
    end
    if latest_label == "" then
        latest_label = "AIR"
    end

    if hide_timer then
        hide_timer:kill()
        hide_timer = nil
    end
    if menu_timer then
        menu_timer:kill()
    end
    menu_visible = true
    draw_overlay(latest_label, true)
    menu_timer = mp.add_timeout(MENU_SECONDS, hide_menu)
end

local function toggle_menu()
    if menu_visible then
        hide_menu()
    else
        show_menu()
    end
end

mp.register_script_message("240mp-ota-channel", show_label)
mp.register_script_message("240mp-ota-tuned-channel", show_tuned_channel)
mp.register_script_message("240mp-ota-tune-transition", show_tuning_transition)
mp.register_script_message("240mp-ota-quiet-next-file", function()
    quiet_next_file = true
    hide()
    show_transition_black()
end)
mp.register_script_message("240mp-ota-transition-black", function()
    hide()
    show_transition_black()
end)
mp.register_script_message("240mp-ota-transition-black-hide", hide_transition_black)
mp.register_script_message("240mp-transition-black", function()
    hide()
    show_transition_black()
end)
mp.register_script_message("240mp-transition-black-hide", hide_transition_black)
mp.register_script_message("240mp-osd-menu-show", show_menu)
mp.register_script_message("240mp-osd-menu-hide", hide_menu)

mp.register_script_message("240mp-ota-stream-info", function(info)
    latest_stream_info = tostring(info or ""):upper()
    if menu_visible and latest_label ~= "" then
        draw_overlay(latest_label, true)
    end
end)

mp.register_event("file-loaded", function()
    -- Automatic video/commercial handoffs ask for a black transition without
    -- re-showing the channel label. Consume that request before the normal
    -- tune transition: show_initial_label is fixed when this mpv process is
    -- launched and otherwise leaks the original tune label into every file.
    if quiet_next_file then
        quiet_next_file = false
        if transition_pending then
            show_transition_black()
        end
        return
    end
    if transition_pending then
        if latest_label ~= "" and initial_label_enabled() then
            show_tuning_transition(latest_label)
        else
            show_transition_black()
        end
    end
    if not labels_enabled() or not top_label_enabled() then
        return
    end
    local title = mp.get_property("media-title", "")
    if title ~= "" then
        show_label(title)
    end
end)

mp.register_event("playback-restart", function()
    if transition_pending then
        hide_transition_black()
    end
    mp.commandv("script-message", "240mp-ota-file-loaded")
end)

mp.register_event("end-file", function()
    hide()
    show_transition_black()
end)

mp.register_event("shutdown", function()
    overlay:remove()
    transition_overlay:remove()
end)

if option_enabled(opts.start_black) then
    mp.add_timeout(0, function()
        if initial_label_enabled() then
            local label = mp.get_property("force-media-title", "")
            if label == "" then
                label = mp.get_property("media-title", "")
            end
            if label ~= "" then
                show_tuning_transition(label)
            else
                show_transition_black()
            end
        else
            show_transition_black()
        end
    end)
end

local function tune_relative(delta)
    mp.commandv("script-message", "240mp-ota-channel-step", tostring(delta))
end

local function tune_now()
    mp.commandv("script-message", "240mp-ota-tune-now")
end

local function tune_last()
    mp.commandv("script-message", "240mp-ota-last-channel")
end

local function consume_navigation()
end

local function seek_with_overlay(seconds)
    mp.command("no-osd seek " .. tostring(seconds))
    show_menu()
end

if ota_controls_enabled() then
    mp.add_forced_key_binding("UP", "ota-channel-up", function() tune_relative(1) end)
    mp.add_forced_key_binding("DOWN", "ota-channel-down", function() tune_relative(-1) end)
    mp.add_forced_key_binding("LEFT", "ota-left-disabled", consume_navigation)
    mp.add_forced_key_binding("RIGHT", "ota-right-disabled", consume_navigation)
    mp.add_forced_key_binding("PREV", "ota-prev-disabled", consume_navigation)
else
    mp.add_forced_key_binding("UP", "tube-up-disabled", consume_navigation)
    mp.add_forced_key_binding("DOWN", "tube-down-disabled", consume_navigation)
    mp.add_forced_key_binding("LEFT", "tube-seek-back", function() seek_with_overlay(-10) end)
    mp.add_forced_key_binding("RIGHT", "tube-seek-forward", function() seek_with_overlay(30) end)
end
mp.add_forced_key_binding("MENU", "ota-menu", toggle_menu)
mp.add_forced_key_binding("ENTER", "ota-enter-disabled", ota_controls_enabled() and consume_navigation or toggle_menu)
mp.add_forced_key_binding("KP_ENTER", "ota-kp-enter-disabled", ota_controls_enabled() and consume_navigation or toggle_menu)
mp.add_key_binding("ESC", "ota-esc", function() mp.command("quit") end)
mp.add_key_binding("BS", "ota-bs", function() mp.command("quit") end)
