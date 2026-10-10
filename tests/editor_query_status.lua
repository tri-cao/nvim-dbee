-- Run: nvim --headless -u NONE -i NONE -l tests/editor_query_status.lua
-- Set NUI_RTP if nui.nvim is installed outside the usual lazy.nvim directory.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))
vim.opt.runtimepath:prepend(vim.env.NUI_RTP or (vim.fn.stdpath("data") .. "/lazy/nui.nvim"))

local directory = vim.fn.tempname()
local listeners, calls = {}, {}
local state = "executing"
local selected
local handler = {
  get_current_connection = function()
    return { id = "connection" }
  end,
  register_event_listener = function(_, event, callback)
    listeners[event] = callback
  end,
  connection_execute = function(_, connection, query)
    assert(connection == "connection", "wrong connection")
    local call = { id = tostring(#calls + 1), query = query, state = state }
    table.insert(calls, call)
    return call
  end,
}
local config = vim.deepcopy(require("dbee.config").default.editor)
config.directory = directory
local editor = require("dbee.ui.editor"):new(handler, {
  set_call = function(_, call)
    selected = call
  end,
}, config)
local note_id = editor:namespace_create_note("global", "queries")
editor:set_current_note(note_id)
editor:show(vim.api.nvim_get_current_win())
local buf = vim.api.nvim_get_current_buf()
local ns = vim.api.nvim_create_namespace("dbee_query_status")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "select", "  1;", "", "select 2;" })

local function signs(buffer)
  local result = {}
  local marks = vim.api.nvim_buf_get_extmarks(buffer or buf, ns, 0, -1, { details = true })
  assert(#marks <= 1, "scratchpad has more than one query status")
  for _, mark in ipairs(marks) do
    if mark[4].sign_text then
      result[mark[2]] = { text = vim.trim(mark[4].sign_text), hl = mark[4].sign_hl_group }
    end
  end
  return result
end

local function complete(call, new_state)
  local received = false
  vim.schedule(function()
    listeners.call_state_changed { call = { id = call.id, state = new_state } }
    received = true
  end)
  assert(vim.wait(1000, function() return received end), "completion event timed out")
end

local function press(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "xt", false)
  return calls[#calls]
end

-- Enter uses the statement's first line rather than the cursor's line.
local utils = require("dbee.utils")
local original_query = utils.query_under_cursor
utils.query_under_cursor = function(buffer)
  assert(buffer == buf, "wrong query buffer")
  return "select\n  1", 0, 1
end
vim.api.nvim_win_set_cursor(0, { 2, 2 })
local call = press("<CR>")
assert(call.query == "select\n  1" and selected == call, "Enter did not execute the statement")
assert(vim.tbl_isempty(signs()), "a pending query showed a result")
complete(call, "retrieving")
assert(vim.tbl_isempty(signs()), "retrieval showed success too early")
complete(call, "archived")
assert(signs()[0].text == "✓" and signs()[0].hl == "DbeeQuerySuccess", "success sign is missing")
assert(not signs()[1], "sign was placed on the cursor line")
assert(vim.wo.signcolumn == "auto", "editor hides query signs")
assert(vim.api.nvim_get_hl(0, { name = "DbeeQuerySuccess" }).fg == 0x22c55e, "success is not green")
assert(vim.api.nvim_get_hl(0, { name = "DbeeQueryFailure" }).fg == 0xef4444, "failure is not red")
vim.cmd("colorscheme default")
assert(vim.api.nvim_get_hl(0, { name = "DbeeQuerySuccess" }).fg == 0x22c55e, "colorscheme lost success color")
assert(vim.api.nvim_get_hl(0, { name = "DbeeQueryFailure" }).fg == 0xef4444, "colorscheme lost failure color")

-- Rerunning clears the old sign; late completion of an older run cannot replace it.
local older = press("<CR>")
assert(vim.tbl_isempty(signs()), "rerun retained its old success sign")
call = press("<CR>")
complete(older, "archived")
assert(vim.tbl_isempty(signs()), "an older run overwrote the pending status")
complete(call, "executing_failed")
assert(signs()[0].text == "✗" and signs()[0].hl == "DbeeQueryFailure", "failure sign is missing")

-- Signs follow their query when lines are inserted above it.
vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "-- inserted line" })
assert(signs()[1] and not signs()[0], "sign did not move with its query")

-- Running another statement clears the sign, and older completions cannot restore it.
editor:execute_query(buf, 1, "select 1;")
older = calls[#calls]
editor:execute_query(buf, 4, "select 2;")
call = calls[#calls]
assert(vim.tbl_isempty(signs()), "another query retained the previous line's sign")
complete(older, "archived")
assert(vim.tbl_isempty(signs()), "an older query restored its sign on another line")
complete(call, "executing_failed")
assert(signs()[4].text == "✗" and not signs()[1], "latest failure was not the only sign")
complete(older, "archived")
assert(signs()[4].text == "✗" and not signs()[1], "late success replaced the latest failure")

-- Completion belongs to the original buffer even after switching scratchpads.
editor:execute_query(buf, 4, "select 2;")
call = calls[#calls]
local second_id = editor:namespace_create_note("global", "second")
editor:set_current_note(second_id)
local second_buf = vim.api.nvim_get_current_buf()
complete(call, "archived")
assert(signs()[4].text == "✓", "hidden query did not receive its status")
assert(vim.tbl_isempty(signs(second_buf)), "completion marked the wrong scratchpad")
editor:execute_query(second_buf, 0, "select 3;")
complete(calls[#calls], "executing_failed")
assert(signs(second_buf)[0].text == "✗", "second scratchpad did not receive its status")
assert(signs()[4].text == "✓", "running another scratchpad cleared this scratchpad's status")

-- Whole-file and visual runs also track their first executed line.
editor:set_current_note(note_id)
call = press("BB")
assert(vim.tbl_isempty(signs()), "whole-file run retained a previous sign")
assert(call.query == table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"), "BB omitted SQL")
complete(call, "retrieving_failed")
assert(signs()[0].text == "✗", "whole-file failure was not marked")
local original_selection = utils.visual_selection
utils.visual_selection = function() return 4, 0, 4, 9 end
editor:do_action("run_selection")
assert(vim.tbl_isempty(signs()), "visual run retained a previous sign")
call = calls[#calls]
assert(call.query == "select 2;", "selection changed SQL")
complete(call, "archived")
assert(signs()[4].text == "✓", "selection success was not marked")
utils.visual_selection = original_selection
utils.query_under_cursor = original_query

-- Handle immediate completion and every failure without waiting for another event.
for _, terminal in ipairs { "archived", "executing_failed", "retrieving_failed", "archive_failed" } do
  state = terminal
  editor:execute_query(buf, 0, "select 1;")
  assert(signs()[0].text == (terminal == "archived" and "✓" or "✗"), "lost immediate " .. terminal)
end

-- Canceled and superseded queries have no success/failure result to display.
state = "executing"
for _, terminal in ipairs { "canceled", "overwritten" } do
  editor:execute_query(buf, 0, "select 1;")
  complete(calls[#calls], terminal)
  assert(not signs()[0], "incomplete query showed a result")
end

-- A closed buffer must not break subsequent completion callbacks.
editor:execute_query(second_buf, 0, "select 3;")
call = calls[#calls]
vim.api.nvim_buf_delete(second_buf, { force = true })
complete(call, "archived")
assert(vim.tbl_isempty(editor.query_calls), "finished queries leaked pending locations")

vim.fn.delete(directory, "rf")
print("Editor query status: all checks passed")
