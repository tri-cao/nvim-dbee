-- Run: nvim --headless -u NONE -i NONE -l tests/scratchpad_navigation.lua
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))
vim.o.lines = 60
vim.o.columns = 160
vim.o.hidden = false
local ui = {}
package.loaded["dbee.api.ui"] = ui

local directory = vim.fn.tempname()
local handler = {
  connection_get_params = function(_, id)
    return { id = id, name = id }
  end,
  set_current_connection = function(self, id)
    self.current = id
  end,
}
local defaults = require("dbee.config").default
local config = vim.deepcopy(defaults.editor)
config.directory = directory
local editor = require("dbee.ui.editor"):new(handler, {}, config)
local common = require("dbee.ui.common")
ui.editor_show = function(win)
  editor:show(win)
end
ui.editor_search_note_with_buf = function(buf)
  return editor:search_note_with_buf(buf)
end
ui.editor_search_note_with_file = function(file)
  return editor:search_note_with_file(file)
end
ui.editor_set_current_note = function(id)
  editor:set_current_note(id)
end
ui.editor_do_action = function(action)
  editor:do_action(action)
end
local panes = {}
for _, name in ipairs { "drawer", "result", "call_log" } do
  local buf = vim.api.nvim_create_buf(false, true)
  panes[name] = buf
  common.configure_buffer_mappings(buf, {}, defaults[name].mappings)
  ui[name .. "_show"] = function(win) vim.api.nvim_win_set_buf(win, buf) end
end

local external = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(external)
local source_win = vim.api.nvim_get_current_win()
local global_keys = 0
vim.keymap.set("n", "[b", function() global_keys = global_keys + 1 end)
vim.keymap.set("n", "]b", function() global_keys = global_keys + 1 end)
local function press(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
end

local layout = require("dbee.layouts").Default:new { result_height = 12, call_log_height = 7 }
layout:open()
press("[b")
press("]b")
assert(global_keys == 0, "welcome buffer used global navigation")

editor:open_connection_scratchpad("first")
local first = editor:get_current_note()
vim.api.nvim_buf_set_lines(first.bufnr, 0, -1, false, { "select 42;" })
press("[b")
assert(editor:get_current_note().id == first.id, "single scratchpad did not wrap")
-- Put an unrelated listed buffer between the scratchpads in buffer order.
local unrelated = vim.api.nvim_create_buf(true, false)
editor:open_connection_scratchpad("second")
local second = editor:get_current_note()
local changed
editor:register_event_listener("current_note_changed", function(data) changed = data.note_id end)

local function check_current(note, connection)
  assert(vim.api.nvim_get_current_win() == layout.windows.editor, "editor did not get focus")
  assert(vim.api.nvim_get_current_buf() == note.bufnr, "navigation did not switch the displayed buffer")
  assert(editor:get_current_note().id == note.id, "current note did not follow the buffer")
  assert(handler.current == connection, "connection did not follow its scratchpad")
  assert(layout:is_open(), "switching scratchpads closed DBee")
end

press("[b")
check_current(first, "first")
assert(changed == first.id, "drawer selection did not get updated")
assert(vim.bo[first.bufnr].modified, "unsaved SQL was discarded")
press("]b")
check_current(second, "second")
press("]b")
check_current(first, "first")

for _, name in ipairs { "drawer", "result", "call_log" } do
  local was_first = editor:get_current_note().id == first.id
  vim.api.nvim_set_current_win(layout.windows[name])
  press("]b")
  check_current(was_first and second or first, was_first and "second" or "first")
end
assert(global_keys == 0, "DBee panes used global buffer mappings")
assert(vim.api.nvim_buf_is_valid(unrelated), "unrelated buffer was removed")

-- Direct buffer switching also updates the editor state in both layout modes.
for _, mode in ipairs { "immutable", "close" } do
  layout:close()
  layout = require("dbee.layouts").Default:new { on_switch = mode, result_height = 12, call_log_height = 7 }
  layout:open()
  vim.api.nvim_win_set_buf(layout.windows.editor, first.bufnr)
  check_current(first, "first")
  vim.api.nvim_win_set_buf(layout.windows.editor, second.bufnr)
  check_current(second, "second")
end

-- Deleted and unlisted scratchpads are skipped, and count prefixes wrap.
vim.bo[first.bufnr].buflisted = false
press("[b")
check_current(second, "second")
vim.bo[first.bufnr].buflisted = true
press("2[b")
check_current(second, "second")
vim.api.nvim_buf_delete(first.bufnr, { force = true })
press("]b")
check_current(second, "second")

layout:close()
assert(vim.api.nvim_get_current_win() == source_win)
press("[b")
press("]b")
assert(global_keys == 2, "global buffer mappings changed outside DBee")
assert(vim.api.nvim_buf_is_valid(external), "source buffer was lost")
vim.fn.delete(directory, "rf")
print("DBee scratchpad navigation: all checks passed")
