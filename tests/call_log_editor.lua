-- Run: nvim --headless -u NONE -i NONE -l tests/call_log_editor.lua
-- Set NUI_RTP if nui.nvim is installed outside the usual lazy.nvim directory.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))
vim.opt.runtimepath:prepend(vim.env.NUI_RTP or (vim.fn.stdpath("data") .. "/lazy/nui.nvim"))
vim.o.lines = 60
vim.o.columns = 160
vim.o.hidden = false

local ui = {}
package.loaded["dbee.api.ui"] = ui
local directory = vim.fn.tempname()
local calls, listeners = {}, {}
local handler = {
  current = "first",
  get_current_connection = function(self)
    return { id = self.current }
  end,
  connection_get_params = function(_, id)
    return { id = id, name = "Connection " .. id }
  end,
  set_current_connection = function(self, id)
    self.current = id
    if listeners.current_connection_changed then
      listeners.current_connection_changed { conn_id = id }
    end
  end,
  register_event_listener = function(_, event, callback)
    listeners[event] = callback
  end,
  get_calls = function()
    local all = {}
    for _, entries in pairs(calls) do
      vim.list_extend(all, entries)
    end
    return all
  end,
  connection_execute = function()
    error("editing a history query executed it")
  end,
}
local defaults = require("dbee.config").default
local config = vim.deepcopy(defaults.editor)
config.directory = directory
local editor = require("dbee.ui.editor"):new(handler, {}, config)
local history = require("dbee.ui.call_log"):new(handler, editor, {}, defaults.call_log)
ui.editor_show = function(win) editor:show(win) end
ui.editor_search_note_with_buf = function(buf) return editor:search_note_with_buf(buf) end
ui.editor_search_note_with_file = function(file) return editor:search_note_with_file(file) end
ui.editor_set_current_note = function(id) editor:set_current_note(id) end
ui.call_log_show = function(win) history:show(win) end
for _, name in ipairs { "drawer", "result" } do
  local buf = vim.api.nvim_create_buf(false, true)
  ui[name .. "_show"] = function(win) vim.api.nvim_win_set_buf(win, buf) end
end
local layout = require("dbee.layouts").Default:new { result_height = 12, call_log_height = 7 }
layout:open()
local function press_edit()
  vim.api.nvim_set_current_win(layout.windows.call_log)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(">", true, false, true), "xt", false)
end
local function check_query(connection, expected, row)
  local note, namespace = editor:search_note_with_buf(vim.api.nvim_get_current_buf())
  assert(vim.api.nvim_get_current_win() == layout.windows.editor, "editor did not get focus")
  assert(namespace == connection and handler.current == connection, "wrong connection scratchpad")
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(note.bufnr, 0, -1, false), expected), "query text changed")
  assert(vim.api.nvim_win_get_cursor(layout.windows.editor)[1] == row, "cursor is not at inserted query")
  assert(layout:is_open(), "opening a history query closed DBee")
  assert(vim.bo[note.bufnr].modified, "query buffer should remain unsaved")
  return note
end

-- Empty history is a no-op, including focus and the current note.
local welcome = editor:get_current_note()
press_edit()
assert(vim.api.nvim_get_current_win() == layout.windows.call_log, "empty history changed focus")
assert(editor:get_current_note().id == welcome.id, "empty history created a scratchpad")

-- A multiline query opens its own connection even when the displayed history differs.
calls.first = { {
  id = "query",
  connection_id = "second",
  query = "select\n  42;\n",
  state = "archived",
  timestamp_us = 1,
} }
history:refresh()
vim.fn.setreg('"', "keep clipboard")
press_edit()
local second = check_query("second", { "select", "  42;", "" }, 1)
assert(vim.fn.getreg('"') == "keep clipboard", "editing changed the clipboard")

-- Restored calls keep their original connection even when another one is active.
editor:open_connection_scratchpad("first")
local first = editor:get_current_note()
vim.api.nvim_buf_set_lines(first.bufnr, 0, -1, false, { "select 'draft';" })
vim.cmd("write")
vim.api.nvim_buf_set_lines(first.bufnr, 0, -1, false, { "select 'unsaved draft';" })
editor:open_connection_scratchpad("second")
calls.first = { { id = "legacy", connection_id = "first", query = "select 2;", state = "overwritten", timestamp_us = 2 } }
history:refresh()
press_edit()
local reused = check_query("first", { "select 'unsaved draft';", "", "select 2;" }, 3)
assert(reused.id == first.id and #editor:namespace_get_notes("first") == 1, "scratchpad was duplicated")
assert(vim.fn.readfile(first.file)[1] == "select 'draft';", "editing overwrote the saved scratchpad")
assert(
  vim.deep_equal(vim.api.nvim_buf_get_lines(second.bufnr, 0, -1, false), { "select", "  42;", "" }),
  "another connection's scratchpad changed"
)

-- An existing final blank line already separates the next query.
vim.api.nvim_buf_set_lines(first.bufnr, 0, -1, false, { "select 1;", "" })
press_edit()
check_query("first", { "select 1;", "", "select 2;" }, 3)

layout:close()
vim.fn.delete(directory, "rf")
print("Call log editor: all checks passed")
