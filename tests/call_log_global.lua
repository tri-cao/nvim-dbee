-- Run: nvim --headless -u NONE -i NONE -l tests/call_log_global.lua
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))
vim.opt.runtimepath:prepend(vim.env.NUI_RTP or (vim.fn.stdpath("data") .. "/lazy/nui.nvim"))

local listeners = {}
local calls = {
  { id = "a", connection_id = "first", query = "select 1", state = "archived", timestamp_us = 1 },
  { id = "b", connection_id = "second connection", query = "select 2", state = "archived", timestamp_us = 2 },
}
local selected, edited, canceled
local handler = {
  get_current_connection = function() end,
  connection_get_params = function(_, id)
    assert(id == "second connection", "preview resolved another call's connection")
    return { id = id, name = "Warehouse Analytics" }
  end,
  get_calls = function()
    return vim.deepcopy(calls)
  end,
  connection_get_calls = function()
    error("history must be global")
  end,
  register_event_listener = function(_, event, callback)
    listeners[event] = callback
  end,
  call_cancel = function(_, id)
    canceled = id
  end,
}
local result = {
  set_call = function(_, call)
    selected = call.id
  end,
  page_current = function() end,
}
local editor = {
  append_connection_query = function(_, id, query)
    edited = { id, query }
  end,
}
local history = require("dbee.ui.call_log"):new(handler, editor, result, require("dbee.config").default.call_log)
history:show(vim.api.nvim_get_current_win())
local function check_history()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  assert(#lines == 2, "global history must work without an active connection")
  assert(lines[1]:find("select 2", 1, true), "newest query is missing")
  assert(lines[2]:find("select 1", 1, true), "other connection's query is missing")
  assert(not lines[1]:find("second", 1, true) and not lines[2]:find("first", 1, true), "connection is displayed")
end
check_history()
listeners.current_connection_changed { conn_id = "first" }
check_history()
listeners.current_connection_changed { conn_id = "second" }
check_history()
vim.api.nvim_win_set_cursor(0, { 2, 0 })
history:do_action("show_result")
assert(selected == "a", "wrong connection's result selected")
history:do_action("edit_query")
assert(vim.deep_equal(edited, { "first", "select 1" }), "query opened in wrong scratchpad")
history:do_action("cancel_call")
assert(canceled == "a", "wrong query canceled")
vim.api.nvim_win_set_cursor(0, { 1, 0 })
history:do_action("edit_query")
assert(vim.deep_equal(edited, { "second connection", "select 2" }), "connection ID with spaces changed")
local common = require("dbee.ui.common")
local summary
common.float_hover = function(_, entries)
  summary = entries
  return function() end
end
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = history.bufnr })
assert(summary, "query preview is missing")
local connection
for _, entry in ipairs(summary) do
  if entry.key == "connection" then
    connection = entry.value
  end
end
assert(connection == "Warehouse Analytics", "preview must show the connection name instead of its ID")
assert(calls[2].connection_id == "second connection", "display name replaced the saved connection ID")
local original_notify = vim.notify
local notice
vim.notify = function(message) notice = message end
for _, id in ipairs { false, "", " \t " } do
  calls[1].connection_id = id or nil
  history:refresh()
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  edited = nil
  history:do_action("edit_query")
  assert(not edited, "missing connection opened the query on another connection")
  assert(notice and notice:find("original connection", 1, true), "missing connection was not reported")
  notice = nil
end
vim.notify = original_notify
calls = {}
listeners.call_state_changed {}
local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
assert(#lines == 1 and lines[1]:find("Call log", 1, true), "empty history retained old entries")
print("Global call log: all checks passed")
