-- Run from the repository root: nvim --headless -u NONE -i NONE -l tests/result_refresh.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.lines = 30

local ResultUI = require("dbee.ui.result")
package.loaded["dbee.api.ui"] = {}
local opts = vim.deepcopy(require("dbee.config").default.result)
opts.focus_result = false
opts.page_size = 20
opts.progress = { text_prefix = "Refreshing 100%", spinner = { "A", "B" } }
local listeners, executions, displays, cancellations, notices = {}, {}, {}, {}, {}
local next_state, execute_error = "unknown", nil
local original_notify = vim.notify
vim.notify = function(message)
  notices[#notices + 1] = message
end
local function emit(call, state)
  local updated = vim.tbl_extend("force", call, { state = state })
  listeners.call_state_changed { call = updated }
  return updated
end
local handler = {
  register_event_listener = function(_, name, callback)
    listeners[name] = callback
  end,
  get_current_connection = function()
    return { id = "other-connection" }
  end,
  connection_execute = function(_, id, query)
    if execute_error then
      error(execute_error)
    end
    local call = {
      id = "refresh-" .. (#executions + 1),
      connection_id = id,
      query = query,
      state = next_state,
      time_taken_us = 123000,
    }
    executions[#executions + 1] = call
    return call
  end,
  call_display_result = function(_, id, bufnr, from)
    displays[#displays + 1] = { id = id, from = from }
    local lines = { "     │ " .. id, "─────┼─────────" }
    for i = 1, 20 do
      lines[#lines + 1] = string.format(" %3d │ value-%d", from + i, from + i)
    end
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    return 60
  end,
  call_cancel = function(_, id)
    cancellations[#cancellations + 1] = id
  end,
}
local ui = ResultUI:new(handler, opts)
local parent = vim.api.nvim_get_current_win()
ui:do_action("refresh")
assert(#executions == 0, "R ran a query without a displayed call")
local old = {
  id = "original",
  connection_id = "original-connection",
  query = "select * from original_table;",
  state = "archived",
  time_taken_us = 1000,
}
ui:set_call(old)
ui:show(parent)
ui:page_next()
vim.api.nvim_win_set_cursor(parent, { 18, 5 })
vim.fn.winrestview { topline = 10 }
ui.header:update()
assert(ui.header.float_winid, "test did not pin the header")
local lines = vim.api.nvim_buf_get_lines(ui.bufnr, 0, -1, false)
local cursor = vim.api.nvim_win_get_cursor(parent)
local header = ui.header.line
local winbar = vim.wo[parent].winbar
local display_count = #displays
local function press(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
end
local function unchanged()
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(ui.bufnr, 0, -1, false), lines), "refresh cleared old rows")
  assert(ui.header.line == header and ui.header.float_winid, "refresh lost the pinned header")
  assert(vim.deep_equal(vim.api.nvim_win_get_cursor(parent), cursor), "refresh moved the cursor")
  assert(ui.page_index == 1, "refresh changed the displayed page before completion")
  assert(not vim.bo[ui.bufnr].modifiable and not vim.bo[ui.bufnr].modified, "refresh modified buffer options")
end
local function no_refresh_failure()
  for _, notice in ipairs(notices) do
    assert(not notice:find("Result refresh failed", 1, true), "unknown state reported a refresh failure: " .. notice)
  end
end

-- The actual default R mapping runs the exact query on its original connection.
press("R")
local pending = executions[#executions]
assert(pending.query == old.query and pending.connection_id == old.connection_id, "R used the active connection/query")
assert(ui:get_call() == old, "pending query replaced the displayed call")
no_refresh_failure()
assert(ui.refresh_call and ui.refresh_call.id == pending.id, "initial unknown state discarded the pending query")
assert(vim.wo[parent].winbar:find("Refreshing 100%%", 1, true), "refresh spinner is missing or unescaped")
unchanged()
local first_progress = ui.refresh_progress
assert(vim.wait(500, function() return ui.refresh_progress ~= first_progress end, 10), "spinner did not animate")
unchanged()
press("R")
assert(#executions == 1, "repeated R started overlapping refreshes")
emit(pending, "unknown")
assert(ui.refresh_call and ui.refresh_call.id == pending.id, "unknown event stopped the refresh")
no_refresh_failure()
emit(pending, "executing")
emit(pending, "retrieving")
ui:page_next()
assert(#displays == display_count, "loading refresh made a synchronous result RPC")
unchanged()
press("<C-c>")
assert(cancellations[1] == pending.id, "cancel targeted the old query")
emit(pending, "canceled")
assert(not ui.refresh_call and not ui.refresh_progress, "cancellation retained loading state")
assert(vim.wo[parent].winbar == winbar, "cancellation did not restore the page status")
unchanged()

-- Errors retain the previous table and stop the timer; R can then retry.
for _, state in ipairs { "executing_failed", "retrieving_failed", "overwritten" } do
  press("R")
  pending = executions[#executions]
  pending.error = "refresh error"
  emit(pending, state)
  unchanged()
  assert(not ui.refresh_call and vim.wo[parent].winbar == winbar, "failure retained its spinner")
  assert(notices[#notices]:find("refresh error", 1, true), "refresh failure was not reported")
end
execute_error = "connection unavailable"
press("R")
unchanged()
assert(not ui.refresh_call and vim.wo[parent].winbar == winbar, "execute RPC error changed the old result")
execute_error = nil

-- The complete replacement is displayed at page one only after retrieval finishes.
press("R")
pending = executions[#executions]
emit(old, "overwritten")
unchanged()
emit(pending, "archived")
assert(ui:get_call().id == pending.id and ui.page_index == 0, "completion did not switch to the new query")
assert(displays[#displays].id == pending.id and displays[#displays].from == 0, "replacement used the wrong result/page")
assert(ui.header.line:find(pending.id, 1, true), "replacement did not update column names")
assert(not ui.refresh_call and not ui.refresh_progress, "completed refresh retained its spinner")
winbar = vim.wo[parent].winbar
vim.wait(150, function() return false end, 10)
assert(vim.wo[parent].winbar == winbar, "stopped timer overwrote the new result status")

-- Immediate completion is handled without requiring a later event.
for _, state in ipairs { "archived", "archive_failed", "executing_failed" } do
  local before = ui:get_call()
  next_state = state
  press("R")
  pending = executions[#executions]
  assert(not ui.refresh_call and not ui.refresh_progress, "lost immediate " .. state)
  assert(ui:get_call().id == (state == "executing_failed" and before.id or pending.id), "wrong immediate result")
end
next_state = "unknown"

-- Switching queries discards refresh callbacks and removes its loading indicator.
press("R")
pending = executions[#executions]
ui:set_call(old)
ui:page_current()
display_count = #displays
emit(pending, "archived")
assert(ui:get_call() == old and #displays == display_count, "late refresh replaced a newly selected query")
assert(not vim.wo[parent].winbar:find("Refreshing", 1, true), "switching queries retained its spinner")
for _, state in ipairs { "unknown", "executing", "retrieving" } do
  ui:set_call(vim.tbl_extend("force", old, { state = state }))
  local count = #executions
  press("R")
  assert(#executions == count, "R duplicated an already running query")
end

-- Wiping the result buffer stops timer callbacks and ignores late completions.
ui:set_call(old)
ui:page_current()
press("R")
pending = executions[#executions]
local timer_count = #vim.fn.timer_info()
vim.api.nvim_buf_delete(ui.bufnr, { force = true })
assert(#vim.fn.timer_info() < timer_count and not ui.refresh_call, "buffer wipe leaked a spinner timer")
emit(pending, "archived")
vim.notify = original_notify
print("Result refresh: all checks passed")
