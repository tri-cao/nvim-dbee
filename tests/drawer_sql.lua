-- Run: nvim --headless -u NONE -i NONE -l tests/drawer_sql.lua
-- Set NUI_RTP if nui.nvim is installed outside the usual lazy.nvim directory.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))
vim.opt.runtimepath:prepend(vim.env.NUI_RTP or (vim.fn.stdpath("data") .. "/lazy/nui.nvim"))
vim.o.lines = 40
vim.o.columns = 120
package.loaded["dbee.api.ui"] = {}

local directory = vim.fn.tempname()
-- FileSource IDs contain a slash, so their persisted notes live two levels down.
local first_conn, second_conn = "file_source_/first", "file_source_/second"
for _, namespace in ipairs { "global", first_conn, second_conn } do
  vim.fn.mkdir(directory .. "/" .. namespace, "p")
end
vim.fn.writefile({ "select 0;" }, directory .. "/global/shared.sql")
vim.fn.writefile({ "select 1;" }, directory .. "/" .. first_conn .. "/Production.sql")
vim.fn.writefile({ "select 2;" }, directory .. "/" .. second_conn .. "/Production.sql")

local listeners = {}
local handler = {
  get_current_connection = function(self)
    return self.current and { id = self.current } or nil
  end,
  connection_get_params = function(_, id)
    return { id = id, name = "Production" }
  end,
  get_sources = function() return {} end,
  register_event_listener = function(_, event, callback)
    listeners[event] = listeners[event] or {}
    table.insert(listeners[event], callback)
  end,
  set_current_connection = function(self, id)
    self.current = id
    for _, callback in ipairs(listeners.current_connection_changed or {}) do
      callback { conn_id = id }
    end
  end,
}
local defaults = require("dbee.config").default
local editor = require("dbee.ui.editor"):new(handler, {}, { directory = directory, completion = { enabled = false } })
editor:show(vim.api.nvim_get_current_win())
vim.cmd("topleft vsplit")
local drawer_win = vim.api.nvim_get_current_win()
local drawer = require("dbee.ui.drawer"):new(handler, editor, {}, defaults.drawer)
drawer:show(drawer_win)

local function check_notes()
  local nodes = drawer.tree:get_nodes()
  assert(nodes[#nodes].name == "sql", "missing shared sql section")
  assert(not drawer.tree:get_node("__master_note_global__"), "global notes section remains")
  assert(not drawer.tree:get_node("__master_note_local__"), "local notes section remains")
  local notes = editor:get_notes()
  assert(#notes == 3, "sql omitted an unopened connection scratchpad")
  for _, note in ipairs(notes) do
    assert(drawer.tree:get_node(note.id), "scratchpad is missing from sql")
  end
  return notes
end

-- All persisted scratchpads are visible before choosing a connection.
local notes = check_notes()
assert(notes[1].name == notes[2].name, "same-name scratchpads were merged")
assert(notes[1].file ~= notes[2].file, "same-name scratchpads share storage")
local first, second = notes[1], notes[2]
drawer.tree:get_node(first.id).action_1(function() drawer:refresh() end)
assert(handler.current == first_conn, "opening a scratchpad selected the wrong connection")
assert(vim.api.nvim_get_current_line() == "select 1;", "opening a scratchpad changed its SQL")
check_notes()
vim.api.nvim_buf_set_lines(first.bufnr, 0, -1, false, { "select 'draft';" })
editor:open_connection_scratchpad(second_conn)
check_notes()
assert(vim.bo[first.bufnr].modified, "switching connections lost unsaved SQL")

-- Changing projects cannot filter scratchpads or lose their tree state.
local cwd = vim.fn.getcwd()
drawer.tree:get_node("__master_sql__"):collapse()
vim.api.nvim_set_current_win(drawer_win)
vim.cmd.cd(directory)
drawer:refresh()
check_notes()
assert(not drawer.tree:get_node("__master_sql__"):is_expanded(), "refresh reset sql expansion")
vim.cmd.cd(cwd)

-- New scratchpads are global even with an active connection.
drawer.tree:get_node("__new_global_note__").action_1(function() drawer:refresh() end, nil, function(opts)
  opts.on_confirm("new-shared")
end)
local created, namespace = editor:search_note(editor:get_current_note().id)
assert(namespace == "global" and created.name == "new-shared.sql", "new scratchpad is connection-local")
assert(handler.current == second_conn, "opening a shared scratchpad changed connections")
assert(#editor:get_notes() == 4, "unsaved scratchpad is missing from sql")

-- Renaming and deleting target the selected note's storage namespace.
drawer.tree:get_node(second.id).action_2(function() drawer:refresh() end, nil, function(opts)
  opts.on_confirm("renamed")
end)
assert(vim.fn.filereadable(directory .. "/" .. second_conn .. "/renamed.sql") == 1, "rename used the wrong namespace")
drawer.tree:get_node(second.id).action_3(function() drawer:refresh() end, function(opts)
  opts.on_confirm("Yes")
end)
assert(vim.fn.filereadable(second.file) == 0, "delete kept the scratchpad file")
assert(vim.fn.filereadable(first.file) == 1, "delete removed another connection's scratchpad")
assert(not drawer.tree:get_node(second.id), "deleted scratchpad is still in sql")
assert(#editor:get_notes() == 3, "delete changed unrelated scratchpads")

vim.fn.delete(directory, "rf")
print("Drawer sql: all checks passed")
