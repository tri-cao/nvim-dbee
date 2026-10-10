-- Run from the repository root: nvim --headless -u NONE -i NONE -l tests/editor_scratchpad.lua
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))
vim.o.hidden = false

local directory = vim.fn.tempname()
local connections = {
  first = { id = "first", name = "Production" },
  second = { id = "second", name = "Production" },
  legacy = { id = "legacy", name = "Local DB" },
  unsafe = { id = "unsafe", name = "Team/DB\\Replica" },
}
local handler = {
  register_event_listener = function() end,
  connection_get_params = function(_, id)
    return connections[id]
  end,
  set_current_connection = function(self, id)
    self.current = id
  end,
}
local Editor = require("dbee.ui.editor")
local editor = Editor:new(handler, {}, { directory = directory })
editor:show(vim.api.nvim_get_current_win())
assert(not vim.bo.buflisted, "welcome buffer should stay out of the bufferline")
vim.fn.writefile({}, editor:get_current_note().file)

editor:open_connection_scratchpad("first")
local first = editor:get_current_note()
assert(first.name == "Production.sql", "scratchpad does not use the connection name")
assert(vim.fs.basename(vim.api.nvim_buf_get_name(first.bufnr)) == first.name)
assert(vim.bo[first.bufnr].buflisted, "scratchpad is missing from the bufferline")
assert(handler.current == "first" and vim.api.nvim_get_current_buf() == first.bufnr)
vim.api.nvim_buf_set_lines(first.bufnr, 0, -1, false, { "select 42;" })

editor:open_connection_scratchpad("second")
local second = editor:get_current_note()
assert(second.bufnr ~= first.bufnr, "connections with the same name share a buffer")
assert(second.name == first.name and vim.bo[second.bufnr].buflisted)
editor:open_connection_scratchpad("first")
assert(editor:get_current_note().id == first.id, "reopening created another scratchpad")
assert(vim.api.nvim_get_current_line() == "select 42;" and vim.bo.modified, "unsaved SQL was lost")
assert(#editor:namespace_get_notes("first") == 1)
vim.cmd("write")
assert(vim.fn.readfile(first.file)[1] == "select 42;", "scratchpad did not save to its named file")

-- Existing notes stay available without being overwritten by the named scratchpad.
vim.fn.mkdir(directory .. "/legacy", "p")
vim.fn.writefile({ "select 1;" }, directory .. "/legacy/scratchpad.sql")
local legacy = editor:namespace_get_notes("legacy")[1]
editor:set_current_note(legacy.id)
vim.api.nvim_buf_set_lines(legacy.bufnr, 0, -1, false, { "select 2;" })
editor:open_connection_scratchpad("legacy")
assert(editor:get_current_note().name == "Local DB.sql" and vim.bo.buflisted)
assert(editor:get_current_note().id ~= legacy.id)
assert(vim.api.nvim_buf_get_lines(legacy.bufnr, 0, -1, false)[1] == "select 2;")
assert(vim.bo[legacy.bufnr].modified, "opening the scratchpad lost unsaved edits in another note")
assert(vim.fn.readfile(legacy.file)[1] == "select 1;", "opening the scratchpad overwrote an existing note")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "select 3;" })
vim.cmd("write")

-- Restore a saved scratchpad from a fresh editor instance.
vim.api.nvim_buf_delete(editor:get_current_note().bufnr, {})
local restored = Editor:new(handler, {}, { directory = directory })
restored:show(vim.api.nvim_get_current_win())
restored:open_connection_scratchpad("legacy")
assert(restored:get_current_note().name == "Local DB.sql")
assert(vim.api.nvim_get_current_line() == "select 3;" and vim.bo.buflisted)

restored:open_connection_scratchpad("unsafe")
assert(restored:get_current_note().name == "Team_DB_Replica.sql", "name contains path separators")
assert(vim.fs.dirname(restored:get_current_note().file) == directory .. "/unsafe")

vim.fn.delete(directory, "rf")
print("DBee scratchpad bufferline: all checks passed")
