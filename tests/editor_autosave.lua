-- Run: nvim --headless -n -u NONE -i NONE -l tests/editor_autosave.lua
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))
vim.o.lines = 60
vim.o.columns = 160
vim.o.hidden = false

local directory = vim.fn.tempname()
vim.fn.mkdir(directory, "p")
local ui = {}
package.loaded["dbee.api.ui"] = ui
local handler = {
  register_event_listener = function() end,
  connection_get_params = function(_, id)
    return { id = id, name = id }
  end,
  set_current_connection = function(self, id)
    self.current = id
  end,
  connection_execute = function()
    error("Saving must not execute SQL")
  end,
}
local defaults = require("dbee.config").default
local editor_config = vim.deepcopy(defaults.editor)
editor_config.directory = directory .. "/notes"
local editor = require("dbee.ui.editor"):new(handler, {}, editor_config)
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
for _, name in ipairs { "result", "drawer", "call_log" } do
  local buf = vim.api.nvim_create_buf(false, true)
  ui[name .. "_show"] = function(win)
    vim.api.nvim_win_set_buf(win, buf)
  end
end
local layout = require("dbee.layouts").Default:new { result_height = 12, call_log_height = 7 }
package.loaded["dbee.api"] = {
  ui = ui,
  core = {},
  current_config = function()
    return { window_layout = layout }
  end,
}
local dbee = require("dbee")
local source_win = vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unnamed work" })
local unnamed = vim.api.nvim_get_current_buf()

local function file_buffer(name, filetype)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = filetype
  vim.api.nvim_buf_set_name(buf, directory .. "/" .. name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "select 1;" })
  return buf
end
local external_sql = file_buffer("external.sql", "")
local external_mysql = file_buffer("mysql-query.txt", "mysql")
local unrelated = file_buffer("other.txt", "text")
local writes = {}
vim.api.nvim_create_autocmd("BufWritePost", {
  callback = function(event)
    writes[event.buf] = (writes[event.buf] or 0) + 1
  end,
})

dbee.open()
editor:open_connection_scratchpad("first")
local first = editor:get_current_note()
vim.api.nvim_buf_set_lines(first.bufnr, 0, -1, false, { "select 42;" })
editor:open_connection_scratchpad("second")
local second = editor:get_current_note()
vim.api.nvim_buf_set_lines(second.bufnr, 0, -1, false, { "select 84;" })
local global_id = editor:namespace_create_note("global", "shared")
editor:set_current_note(global_id)
local shared = editor:get_current_note()
vim.api.nvim_buf_set_lines(shared.bufnr, 0, -1, false, { "select 21;" })
-- A scratchpad is still saved when its filetype has been overridden.
vim.bo[first.bufnr].filetype = "text"
dbee.close()
assert(not dbee.is_open() and vim.api.nvim_get_current_win() == source_win)
for _, entry in ipairs {
  { first.bufnr, first.file, "select 42;" },
  { second.bufnr, second.file, "select 84;" },
  { shared.bufnr, shared.file, "select 21;" },
  { external_sql, vim.api.nvim_buf_get_name(external_sql), "select 1;" },
  { external_mysql, vim.api.nvim_buf_get_name(external_mysql), "select 1;" },
} do
  assert(vim.fn.readfile(entry[2])[1] == entry[3], "SQL was not saved: " .. entry[2])
  assert(not vim.bo[entry[1]].modified and writes[entry[1]] == 1)
end
assert(vim.bo[unnamed].modified and vim.bo[unrelated].modified, "Unrelated work was saved")
assert(vim.fn.filereadable(vim.api.nvim_buf_get_name(unrelated)) == 0)
assert(editor:get_current_note().id == shared.id, "Saving changed the selected scratchpad")

-- Repeated closes and unchanged buffers produce no additional writes.
dbee.close()
dbee.open()
dbee.toggle()
assert(writes[first.bufnr] == 1 and writes[shared.bufnr] == 1)

-- A failed save reports the path, retains edits, and prevents the UI from closing.
dbee.open()
editor:set_current_note(second.id)
vim.api.nvim_buf_set_lines(second.bufnr, 0, -1, false, { "select 100;" })
vim.bo[second.bufnr].readonly = true
local ok, err = pcall(dbee.close)
assert(not ok and tostring(err):find(second.file, 1, true), "Save failure was not reported")
assert(dbee.is_open() and vim.bo[second.bufnr].modified, "Save failure lost the UI or edits")
assert(vim.fn.readfile(second.file)[1] == "select 84;", "Readonly file was overwritten")
vim.bo[second.bufnr].readonly = false
dbee.toggle()
assert(not dbee.is_open() and vim.fn.readfile(second.file)[1] == "select 100;")

-- Direct layout close, :quit and :tabclose also persist hidden scratchpads.
for _, close in ipairs {
  function()
    layout:close()
  end,
  function()
    vim.api.nvim_set_current_win(layout.windows.drawer)
    vim.cmd("quit")
    assert(
      vim.wait(1000, function()
        return not layout:is_open()
      end),
      "Quit did not close DBee"
    )
  end,
  function()
    vim.cmd("hide tabclose")
  end,
} do
  dbee.open()
  vim.api.nvim_buf_set_lines(first.bufnr, 0, -1, false, { "select " .. writes[first.bufnr] .. ";" })
  local expected = vim.api.nvim_buf_get_lines(first.bufnr, 0, 1, false)[1]
  close()
  assert(not layout:is_open() and vim.fn.readfile(first.file)[1] == expected)
  assert(not vim.bo[first.bufnr].modified, "Hidden scratchpad remained unsaved")
end

-- Custom layouts receive the same autosave behavior through the public API.
local closed = false
layout = {
  is_open = function()
    return not closed
  end,
  close = function()
    closed = true
  end,
}
vim.api.nvim_buf_set_lines(external_sql, 0, -1, false, { "select 999;" })
dbee.close()
assert(closed and vim.fn.readfile(vim.api.nvim_buf_get_name(external_sql))[1] == "select 999;")

vim.fn.delete(directory, "rf")
print("DBee SQL autosave: all checks passed")
