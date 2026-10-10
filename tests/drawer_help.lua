-- Run: nvim --headless -u NONE -i NONE -l tests/drawer_help.lua
-- Set NUI_RTP if nui.nvim is installed outside the usual lazy.nvim directory.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))
vim.opt.runtimepath:prepend(vim.env.NUI_RTP or (vim.fn.stdpath("data") .. "/lazy/nui.nvim"))
vim.o.lines = 40
vim.o.columns = 120

package.loaded["dbee.api.ui"] = {}
local config = vim.deepcopy(require("dbee.config").default.drawer)
-- Existing configurations must still get the popup even with this legacy option.
config.disable_help = true
for _, km in ipairs(config.mappings) do
  if km.action == "refresh" then
    km.key = "gR"
  end
end
table.insert(config.mappings, {
  key = "gx",
  mode = { "n", "v" },
  action = function() end,
  opts = { desc = "Custom drawer action" },
})
local handler = {
  get_current_connection = function()
    return { id = "conn" }
  end,
  register_event_listener = function() end,
  get_sources = function()
    return {}
  end,
}
local editor = {
  get_current_note = function() end,
  register_event_listener = function() end,
  namespace_get_notes = function()
    return {}
  end,
}
local drawer_win = vim.api.nvim_get_current_win()
local drawer = require("dbee.ui.drawer"):new(handler, editor, {}, config)
drawer:show(drawer_win)

local function check_layout()
  local nodes = drawer.tree:get_nodes()
  assert(nodes[#nodes - 1].name == "global notes", "global notes are not at the bottom")
  assert(nodes[#nodes].name == "local notes", "local notes are not last")
  assert(not drawer.tree:get_node("__help_node__"), "help is still in the tree")
end
check_layout()
drawer.tree:get_node("__master_note_global__"):collapse()
drawer:refresh()
check_layout()
assert(not drawer.tree:get_node("__master_note_global__"):is_expanded(), "refresh lost expansion state")

local function press(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
end

for _, close_key in ipairs { "q", "<Esc>", "?" } do
  press("?")
  local popup_win = vim.api.nvim_get_current_win()
  assert(popup_win ~= drawer_win, "? did not focus the popup")
  local popup_buf = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false)
  local content = table.concat(lines, "\n")
  for _, km in ipairs(config.mappings) do
    assert(content:find(km.key, 1, true), "popup omitted mapping " .. km.key)
  end
  assert(content:find("gx (n, v)  Custom drawer action", 1, true), "custom mapping is missing")
  assert(not content:find("  r (n)", 1, true), "popup showed the default instead of the configured mapping")
  assert(not vim.api.nvim_get_option_value("modifiable", { buf = popup_buf }), "help buffer is editable")
  press(close_key)
  assert(not vim.api.nvim_win_is_valid(popup_win), "close key did not dismiss the popup")
  assert(not vim.api.nvim_buf_is_valid(popup_buf), "popup buffer was not cleaned up")
  assert(vim.api.nvim_get_current_win() == drawer_win, "close did not restore drawer focus")
end

-- Leaving the popup also cleans up; a small screen keeps all mappings scrollable.
vim.o.lines = 12
vim.o.columns = 35
press("?")
local popup_win = vim.api.nvim_get_current_win()
local popup_buf = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_win_get_width(popup_win) <= 31, "popup exceeds screen width")
assert(vim.api.nvim_win_get_height(popup_win) <= 8, "popup exceeds screen height")
press("G")
assert(vim.api.nvim_win_get_cursor(popup_win)[1] == vim.api.nvim_buf_line_count(popup_buf), "help cannot scroll")
vim.api.nvim_set_current_win(drawer_win)
assert(not vim.api.nvim_win_is_valid(popup_win), "leaving did not close popup")
assert(not vim.api.nvim_buf_is_valid(popup_buf), "leaving did not clean up popup buffer")

-- Legacy disable_help=false also renders no help node.
config.disable_help = false
local other = require("dbee.ui.drawer"):new(handler, editor, {}, config)
other:show(drawer_win)
assert(not other.tree:get_node("__help_node__"), "legacy option restored the help node")
print("Drawer help: all checks passed")
