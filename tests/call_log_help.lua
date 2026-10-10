-- Run: nvim --headless -u NONE -i NONE -l tests/call_log_help.lua
-- Set NUI_RTP if nui.nvim is installed outside the usual lazy.nvim directory.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))
vim.opt.runtimepath:prepend(vim.env.NUI_RTP or (vim.fn.stdpath("data") .. "/lazy/nui.nvim"))
vim.o.lines = 40
vim.o.columns = 120

local config = vim.deepcopy(require("dbee.config").default.call_log)
for _, km in ipairs(config.mappings) do
  if km.action == "show_result" then
    km.key = "gr"
  end
end
table.insert(config.mappings, {
  key = "gx",
  mode = { "n", "v" },
  action = function() end,
  opts = { desc = "Custom history action" },
})
local calls = {}
local selected, canceled
local handler = {
  get_current_connection = function()
    return { id = "conn" }
  end,
  register_event_listener = function() end,
  connection_get_calls = function()
    return calls
  end,
  call_cancel = function(_, id)
    canceled = id
  end,
}
local result = {
  set_call = function(_, call)
    selected = call
  end,
  page_current = function() end,
}
local history_win = vim.api.nvim_get_current_win()
local history = require("dbee.ui.call_log"):new(handler, {}, result, config)
history:show(history_win)

local function press(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
end

-- Help works with empty history and closes without leaking a window or buffer.
for _, close_key in ipairs { "q", "<Esc>", "?" } do
  press("?")
  local popup_win = vim.api.nvim_get_current_win()
  local popup_buf = vim.api.nvim_get_current_buf()
  assert(popup_win ~= history_win, "? did not focus the popup")
  local content = table.concat(vim.api.nvim_buf_get_lines(popup_buf, 0, -1, false), "\n")
  for _, km in ipairs(config.mappings) do
    assert(content:find(km.key, 1, true), "popup omitted mapping " .. km.key)
  end
  assert(content:find("gx (n, v)  Custom history action", 1, true), "custom mapping is missing")
  assert(content:find("gr (n, v, o)  Show result of selected query", 1, true), "configured result mapping is missing")
  assert(not content:find("  <CR>", 1, true), "popup showed the default instead of the configured mapping")
  assert(not vim.api.nvim_get_option_value("modifiable", { buf = popup_buf }), "help buffer is editable")
  press(close_key)
  assert(not vim.api.nvim_win_is_valid(popup_win), "close key did not dismiss the popup")
  assert(not vim.api.nvim_buf_is_valid(popup_buf), "popup buffer was not cleaned up")
  assert(vim.api.nvim_get_current_win() == history_win, "close did not restore history focus")
end

-- Help also works alongside query previews, including on a small screen.
calls = { { id = "query", query = "select 1", state = "archived", timestamp_us = 1000000 } }
history:refresh()
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_get_current_buf() })
vim.o.lines = 12
vim.o.columns = 35
press("?")
local popup_win = vim.api.nvim_get_current_win()
local popup_buf = vim.api.nvim_get_current_buf()
assert(vim.api.nvim_win_get_width(popup_win) <= 31, "popup exceeds screen width")
assert(vim.api.nvim_win_get_height(popup_win) <= 8, "popup exceeds screen height")
press("G")
assert(vim.api.nvim_win_get_cursor(popup_win)[1] == vim.api.nvim_buf_line_count(popup_buf), "help cannot scroll")
vim.api.nvim_set_current_win(history_win)
assert(not vim.api.nvim_win_is_valid(popup_win), "leaving did not close popup")
assert(not vim.api.nvim_buf_is_valid(popup_buf), "leaving did not clean up popup buffer")
assert(not selected and not canceled, "help triggered a query action")
press("gr")
assert(selected == calls[1], "show_result stopped working after help")
press("<C-c>")
assert(canceled == calls[1].id, "cancel_call stopped working after help")
print("Query history help: all checks passed")
