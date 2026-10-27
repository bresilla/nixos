-- Eva's widgets: every widget its themes' skins draw, by the name the skin
-- is found under (`widgets.pill { ... }`, `widgets.seek_bar { ... }`). Each
-- is a kit archetype (lib.kit.archetypes) with the settings that make it
-- what it is, the role a screen reader is told, and the theme's skin for
-- its name. Popups, scrolled views and drags are eva's own glue
-- (themes.kit.popup, themes.kit.scroll, themes.kit.drag); the rest is the
-- kit's.
local control = require("lib.kit.control")

local M = {}

local function archetype(name) return require("lib.kit.archetypes." .. name) end

-- The widgets of each archetype, by name.
M.NAMES = {
  Press = { "push", "suggested", "destructive", "flat", "raised", "outlined", "text", "tonal", "elevated", "pill",
    "circular", "icon", "link", "close", "copy", "loading", "toggle", "toggle_group_member", "switch", "checkbox",
    "radio", "chip_assist", "chip_filter", "chip_input", "chip_suggestion", "tag", "tile", "card_action",
    "row_activation", "menu_item", "check_menu_item", "radio_menu_item", "keycap", "fab", "extended_fab",
    "speed_dial_item", "segment", "rating_star", "help", "disclosure_button", "repeat_button", "back", "forward",
    "hold_button" },
  Range = { "slider", "vertical_slider", "range_slider", "discrete_slider", "log_slider", "angle_slider", "knob",
    "bipolar_knob", "stepped_knob", "fader", "spin_button", "scrubber", "scroll_bar", "seek_bar", "volume",
    "brightness", "zoom", "rating", "level_control", "osd_level" },
  Plane = { "colour_plane", "hue_wheel", "xy_pad", "pan_pad", "envelope_point", "joystick", "minimap_viewport",
    "crop_handle" },
  Selection = { "tabs", "segmented", "view_switcher", "inline_view_switcher", "radio_group", "toggle_group",
    "list_selection", "grid_selection", "carousel_dots", "pagination", "stepper_header", "sidebar_list",
    "breadcrumbs", "day_grid", "swatch_grid", "emoji_grid", "icon_chooser", "transfer_side", "rating_items" },
  Popup = { "menu", "context_menu", "menu_bar_menu", "submenu", "popover", "tooltip", "rich_tooltip", "hover_card",
    "dropdown_list", "autocomplete_list", "command_palette", "dialog", "alert_dialog", "message_dialog",
    "preferences_dialog", "about_dialog", "shortcuts_dialog", "bottom_sheet", "side_sheet", "drawer", "toast",
    "snackbar", "banner", "notification_popup", "lightbox", "tour_step" },
  TextField = { "entry", "password", "search", "text_area", "url", "email", "numeric_entry", "otp", "tag_input",
    "mentions", "inline_rename", "entry_row", "filter_field", "code_input" },
  Scroll = { "scroll_view", "scroll_area", "pager", "shelf", "infinite_scroll" },
  Collection = { "list", "boxed_list", "list_box", "virtual_list", "grid_view", "flow_box", "data_table", "tree_view",
    "tree_table", "file_list", "timeline", "feed", "chat_log", "kanban_column", "transfer_list" },
  Disclosure = { "expander", "expander_row", "accordion", "collapsible_header", "collapsible_section", "details",
    "tree_node", "show_more", "collapsible_card", "fold_out" },
  Drag = { "split_pane", "resizable_panel", "resize_grip", "reorderable_rows", "reorderable_tabs",
    "sortable_grid", "swipe_dismiss", "swipe_actions", "pull_to_refresh", "sheet_handle", "window_move",
    "drag_source", "drop_zone", "slide_to_confirm" },
  Navigation = { "navigation_view", "view_stack", "tab_pages", "carousel", "onboarding", "wizard",
    "settings_subpages", "master_detail" },
  Shell = { "window_layout", "header_bar", "toolbar_view", "split_view", "overlay_split_view",
    "navigation_split_view", "multi_pane", "breakpoint_bin", "clamp", "bottom_bar" },
}

-- What each widget sets unless its spec says otherwise.
local DEFAULTS = {
  Press = {
    toggle = { checkable = true },
    switch = { checkable = true, width = 52, height = 32 },
    checkbox = { checkable = true, tristate = true, width = 24, height = 24 },
    radio = { checkable = true, exclusive = true, width = 24, height = 24 },
    chip_filter = { checkable = true },
    check_menu_item = { checkable = true },
    radio_menu_item = { checkable = true, exclusive = true },
    toggle_group_member = { checkable = true, exclusive = true },
    segment = { checkable = true, exclusive = true },
    rating_star = { checkable = true },
    repeat_button = { auto_repeat = true, width = 40, height = 40 },
    disclosure_button = { checkable = true },
    tile = { checkable = true },
    circular = { width = 48, height = 48 },
    close = { width = 40, height = 40 },
    help = { width = 40, height = 40 },
    back = { width = 40, height = 40 },
    forward = { width = 40, height = 40 },
    fab = { width = 56, height = 56 },
    extended_fab = { height = 56 },
    hold_button = { hold = 800 },
  },
  Range = {
    vertical_slider = { orientation = "vertical" },
    fader = { orientation = "vertical", value = 0.75 },
    range_slider = { range = true },
    discrete_slider = { snap = "always", step = 1, from = 0, to = 10 },
    stepped_knob = { snap = "always", step = 1, from = 0, to = 10, drag_mode = "vertical" },
    rating = { snap = "always", step = 1, from = 0, to = 5 },
    log_slider = { logarithmic = true, from = 20, to = 20000, value = 1000 },
    angle_slider = { wrap = true, from = 0, to = 360, drag_mode = "angular", angle_from = 0, angle_sweep = 360 },
    knob = { drag_mode = "vertical" },
    bipolar_knob = { from = -1, to = 1, value = 0, drag_mode = "vertical" },
    zoom = { from = 0.25, to = 4, value = 1, logarithmic = true, step = 0.25 },
    spin_button = { step = 1, snap = "always", from = 0, to = 100, drag_mode = "vertical" },
    seek_bar = { live = false },
    scroll_bar = { wheel = false },
    volume = { from = 0, to = 1 },
    brightness = { from = 0, to = 1 },
    level_control = { from = 0, to = 1 },
    osd_level = { enabled = false, from = 0, to = 1 },
  },
  Plane = {
    hue_wheel = { polar = true, y = 1 },
    joystick = { constraint = "circle", x_from = -1, x_to = 1, y_from = -1, y_to = 1, y_up = true, spring = true },
    xy_pad = { y_up = true },
    pan_pad = { constraint = "circle", x_from = -1, x_to = 1, y_from = -1, y_to = 1, y_up = true },
    envelope_point = { y_up = true },
  },
  Selection = {
    tabs = { orientation = "horizontal" },
    segmented = { orientation = "horizontal", item_width = 80, item_height = 36 },
    view_switcher = { orientation = "horizontal", item_width = 88, item_height = 56 },
    inline_view_switcher = { orientation = "horizontal", item_width = 96, item_height = 36 },
    radio_group = { orientation = "vertical", item_width = 200, item_height = 40 },
    toggle_group = { mode = "multi", item_width = 44, item_height = 40 },
    list_selection = { orientation = "vertical", item_width = 220, item_height = 40 },
    sidebar_list = { orientation = "vertical", item_width = 220, item_height = 40 },
    grid_selection = { orientation = "grid", item_width = 56, item_height = 56 },
    carousel_dots = { orientation = "horizontal", item_width = 24, item_height = 24 },
    pagination = { orientation = "horizontal", item_width = 36, item_height = 36 },
    stepper_header = { orientation = "horizontal", item_width = 96, item_height = 64 },
    breadcrumbs = { orientation = "horizontal", item_height = 36 },
    swatch_grid = { orientation = "grid", item_width = 32, item_height = 32 },
    emoji_grid = { orientation = "grid", item_width = 40, item_height = 40 },
    icon_chooser = { orientation = "grid", item_width = 44, item_height = 44 },
    day_grid = { orientation = "grid", columns = 7, item_width = 40, item_height = 36 },
    transfer_side = { orientation = "vertical", mode = "range", item_width = 220, item_height = 36 },
    rating_items = { orientation = "horizontal", item_width = 36, item_height = 36 },
  },
  TextField = {
    password = { echo = "password", reveal = true },
    url = { validator = "url" }, email = { validator = "email" },
    numeric_entry = { validator = "number" }, search = { clear = true },
    otp = { max_length = 6, validator = "integer" },
    text_area = { multiline = true, wrap = true, vertical_alignment = "top" },
  },
  Collection = {
    data_table = { layout = "table" },
    tree_view = { layout = "tree" },
    tree_table = { layout = "tree" },
    file_list = { row_height = 36 },
    boxed_list = { row_height = 50 },
    timeline = { row_height = 56 },
    feed = { row_height = 92 },
    kanban_column = { row_height = 64 },
    chat_log = { row_height = 48, size_field = "height" },
  },
  -- (A navigation's mode is the engine's own default, a stack, unless named.)
  Navigation = {
    view_stack = { mode = "stack" }, tab_pages = { mode = "stack" }, carousel = { mode = "stack" },
    onboarding = { mode = "stack" }, wizard = { mode = "stack" }, settings_subpages = { mode = "stack" },
    master_detail = { mode = "stack" },
  },
}

-- The role each widget is announced with, where its archetype's default
-- for an unknown name is not it; and its items' roles likewise.
local ROLE = {
  checkbox = "check_box", radio = "radio_button", rating_star = "radio_button", link = "link",
  check_menu_item = "menu_item_check", radio_menu_item = "menu_item_radio", toggle = "toggle_button",
  toggle_group_member = "toggle_button", chip_filter = "toggle_button", segment = "radio_button",
  scroll_bar = "scroll_bar",
  segmented = "radio_group", radio_group = "radio_group", rating_items = "radio_group",
  grid_selection = "grid", icon_chooser = "grid", breadcrumbs = "navigation", list_selection = "list_box",
  transfer_side = "list_box",
  password = "password_text", otp = "password_text", search = "search_field", filter_field = "search_field",
  text_area = "text_area", mentions = "text_area", code_input = "text_area",
  data_table = "table", tree_view = "tree", tree_table = "tree_grid",
  tree_node = "tree_item",
  split_pane = "splitter", resizable_panel = "splitter", resize_grip = "grip", sheet_handle = "grip",
  window_move = "grip",
  tab_pages = "tab_panel",
}
local ITEM_ROLE = {
  segmented = "radio_button", radio_group = "radio_button", rating_items = "radio_button",
  grid_selection = "grid_cell", icon_chooser = "grid_cell", breadcrumbs = "link",
  list_selection = "list_box_option", transfer_side = "list_box_option",
}

local function get(v) if type(v) == "function" then return v() end return v end

local function with_defaults(group, widget, spec)
  local merged = {}
  for k, v in pairs((DEFAULTS[group] or {})[widget] or {}) do merged[k] = v end
  for k, v in pairs(spec or {}) do merged[k] = v end
  merged.widget = widget
  if merged.accessible_role == nil then merged.accessible_role = ROLE[widget] end
  -- A group's name without `exclusive` still makes radio buttons one group.
  if merged.group == nil and merged.exclusive then merged.group = "default" end
  return merged
end

-- A selection's items, each told the role its widget gives it.
local function with_item_role(widget, spec)
  local role = ITEM_ROLE[widget]
  if not role or spec.items == nil then return spec end
  local given = spec.items
  local function tag(list)
    local out = {}
    for i, item in ipairs(list or {}) do
      if type(item) == "table" then
        local copy = {}
        for k, v in pairs(item) do copy[k] = v end
        if copy.accessible_role == nil then copy.accessible_role = role end
        out[i] = copy
      else
        out[i] = { label = tostring(item), accessible_role = role }
      end
    end
    return out
  end
  spec.items = type(given) == "function" and function() return tag(get(given)) end or tag(given)
  return spec
end

--- `spec` told the roles `widget` gives it and its items, and nothing else:
--- for an archetype made directly, with no widget's defaults.
function M.roles(widget, spec)
  if spec.accessible_role == nil then spec.accessible_role = ROLE[widget] end
  return with_item_role(widget, spec)
end

-- A file list given no delegate of its own is a table of name, size and date.
local FILE_COLUMNS = {
  { key = "name", title = "Name", width = 0.56, sortable = true },
  { key = "size", title = "Size", width = 0.2, sortable = true },
  { key = "modified", title = "Modified", width = 0.24, sortable = true },
}
local function file_columns(spec)
  if spec.delegate ~= nil or spec.columns ~= nil then return spec end
  spec.layout = spec.layout or "table"
  local W0 = tonumber(get(spec.width)) or 300
  local columns = {}
  for i, c in ipairs(FILE_COLUMNS) do
    columns[i] = { key = c.key, title = c.title, sortable = c.sortable, width = math.floor(W0 * c.width) }
  end
  spec.columns = columns
  return spec
end

-- A chat log's bubbles are as tall as their text.
local function bubble_height(row, width)
  local text = type(row) == "table" and tostring(row.text or row.label or "") or tostring(row)
  local per_line = math.max(8, math.floor((width * 0.72 - 28) / 7.4))
  local lines = 0
  for part in (text .. "\n"):gmatch("([^\n]*)\n") do lines = lines + math.max(1, math.ceil(#part / per_line)) end
  return 20 * math.max(1, lines) + 40
end
local function chat_rows(spec)
  if spec.size_field ~= "height" or type(spec.rows) ~= "table" then return spec end
  local W0 = tonumber(get(spec.width)) or 300
  for _, row in ipairs(spec.rows) do
    if type(row) == "table" and row.height == nil then row.height = bubble_height(row, W0) end
  end
  return spec
end

local MAKE = {
  Press = function(w, spec) return (control.make("Press", w, with_defaults("Press", w, spec))) end,
  Range = function(w, spec) return (control.make("Range", w, with_defaults("Range", w, spec))) end,
  Plane = function(w, spec) return (control.make("Plane", w, with_defaults("Plane", w, spec))) end,
  Selection = function(w, spec)
    return (archetype("selection").make(w, with_item_role(w, with_defaults("Selection", w, spec))))
  end,
  Popup = function(w, spec) return require("themes.kit.popup").make(w, spec) end,
  TextField = function(w, spec) return archetype("text_field").make(w, with_defaults("TextField", w, spec)) end,
  Scroll = function(w, spec) return require("themes.kit.scroll").make(w, spec) end,
  Collection = function(w, spec)
    local merged = with_defaults("Collection", w, spec)
    if w == "file_list" then file_columns(merged) end
    if w == "chat_log" then chat_rows(merged) end
    return archetype("collection").make(w, merged)
  end,
  Disclosure = function(w, spec) return archetype("disclosure").make(w, with_defaults("Disclosure", w, spec)) end,
  Drag = function(w, spec) return require("themes.kit.drag").make(w, with_defaults("Drag", w, spec)) end,
  Navigation = function(w, spec) return archetype("navigation").make(w, with_defaults("Navigation", w, spec)) end,
  Shell = function(w, spec) return archetype("shell").make(w, with_defaults("Shell", w, spec)) end,
}

for group, names in pairs(M.NAMES) do
  for _, widget in ipairs(names) do
    M[widget] = function(spec) return MAKE[group](widget, spec) end
  end
end

--- A pressable area from a MouseArea-style table -- node properties,
--- children, `on_*` handlers -- as a kit Press `area`: the press, Tab and
--- the keys that click it are the archetype's, the theme's skin marks it.
--- `settings` are the Press's own (`checked`, `group`, ...).
function M.area(props, settings)
  local spec, node, children = { widget = "area" }, {}, {}
  for key, value in pairs(props or {}) do
    if type(key) == "number" then children[key] = value
    elseif type(key) == "string" and key:match("^on_") then spec[key] = value
    else node[key] = value end
  end
  for key, value in pairs(settings or {}) do spec[key] = value end
  if node.enabled ~= nil then spec.enabled = node.enabled end
  return (control.make("Press", "area", spec, { props = node, children = children }))
end

--- A shield: a box that takes the pointer so nothing under it does, and
--- nothing else -- no focus, no keys. `props` are its node's.
function M.shield(props)
  local node = {}
  for key, value in pairs(props or {}) do node[key] = value end
  node.focus_policy = "none"
  return (control.make("Control", "shield", { widget = "shield" }, { props = node }))
end

--- Fades every press but an area while it is disabled, its caption, icon
--- and ground together, unless its spec gives an opacity of its own.
function M.fade(skins, opacity)
  local names = { "Press" }
  for _, name in ipairs(M.NAMES.Press) do names[#names + 1] = name end
  for _, name in ipairs(names) do
    local draw = skins[name]
    if type(draw) == "function" then
      skins[name] = function(t, spec, node, ...)
        if node and spec.widget ~= "area" and spec.opacity == nil then
          node.opacity = function() return t.enabled == false and opacity or 1 end
        end
        return draw(t, spec, node, ...)
      end
    end
  end
end

return M
