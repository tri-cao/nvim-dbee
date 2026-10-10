-- Run: nvim --headless -n -u NONE -i NONE -l tests/connection_scratchpad.lua
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))
vim.opt.runtimepath:prepend(vim.env.NUI_RTP or (vim.fn.stdpath("data") .. "/lazy/nui.nvim"))
vim.o.lines = 60
vim.o.columns = 160
vim.o.hidden = false
package.loaded["dbee.api.ui"] = {}

local directory = vim.fn.tempname()
vim.fn.mkdir(directory .. "/notes/existing", "p")
vim.fn.writefile({ "select 7;" }, directory .. "/notes/existing/scratchpad.sql")
vim.fn.writefile(
  { vim.json.encode {
    { id = "existing", name = "Existing", type = "sqlite", url = "unused" },
  } },
  directory .. "/connections.json"
)

-- Exercise real source creation/reloading and Lua events without database access.
local connections = {}
vim.fn.DbeeCreateConnection = function(spec)
  connections[spec.id] = vim.deepcopy(spec)
  return spec.id
end
vim.fn.DbeeDeleteConnection = function(id)
  connections[id] = nil
end
vim.fn.DbeeGetConnections = function(ids)
  local result = {}
  for _, id in ipairs(ids) do
    if connections[id] then
      result[#result + 1] = connections[id]
    end
  end
  return result
end
vim.fn.DbeeConnectionGetParams = function(id)
  return connections[id] or vim.NIL
end
vim.fn.DbeeGetCurrentConnection = function()
  return vim.NIL
end
vim.fn.DbeeSetCurrentConnection = function() end
local events = require("dbee.handler.__events")
local added = 0
events.register("connection_added", function()
  added = added + 1
end)
local source = require("dbee.sources").FileSource:new(directory .. "/connections.json")
local handler = require("dbee.handler"):new { source }
vim.wait(20, function()
  return false
end)
assert(added == 1)

-- Backfill connections whose creation event preceded the editor's initialization.
local defaults = require("dbee.config").default
local editor = require("dbee.ui.editor"):new(handler, {}, { directory = directory .. "/notes" })
editor:ensure_connection_scratchpads()
local existing = editor:namespace_get_notes("existing")
assert(#existing == 2, "Existing connection did not get its own named scratchpad")
assert(vim.fn.filereadable(directory .. "/notes/existing/Existing.sql") == 1)
assert(vim.fn.readfile(directory .. "/notes/existing/scratchpad.sql")[1] == "select 7;")
editor:ensure_connection_scratchpads()
assert(#editor:namespace_get_notes("existing") == 2, "Backfill duplicated a scratchpad")
editor:show(vim.api.nvim_get_current_win())
local selected = editor:get_current_note().id
vim.cmd("topleft vsplit")
local drawer_win = vim.api.nvim_get_current_win()
local drawer = require("dbee.ui.drawer"):new(handler, editor, {}, defaults.drawer)
drawer:show(drawer_win)

local function add(name)
  local id = handler:source_add_connection(source:name(), { name = name, type = "sqlite", url = "unused" })
  assert(
    vim.wait(1000, function()
      return #editor:namespace_get_notes(id) == 1
    end),
    "New connection did not automatically get a scratchpad"
  )
  local note = editor:namespace_get_notes(id)[1]
  assert(vim.fn.filereadable(note.file) == 1, "New scratchpad was not persisted")
  assert(drawer.tree:get_node(note.id), "New scratchpad did not appear in the drawer")
  assert(editor:get_current_note().id == selected, "Creation changed the selected scratchpad")
  assert(vim.api.nvim_get_current_win() == drawer_win, "Creation stole focus")
  return id, note
end

local first_id, first = add("Production")
local second_id, second = add("Production")
assert(first.name == "Production.sql" and second.name == first.name)
assert(first_id ~= second_id and first.file ~= second.file, "Same-name connections share a scratchpad")
local _, unsafe = add("Team/DB\\Replica")
assert(unsafe.name == "Team_DB_Replica.sql", "Scratchpad name contains a path separator")

-- Reloading neither emits another addition event nor overwrites disk/unsaved contents.
editor:open_connection_scratchpad(first_id)
assert(editor:get_current_note().id == first.id)
vim.api.nvim_buf_set_lines(first.bufnr, 0, -1, false, { "select 42;" })
vim.cmd("write")
vim.api.nvim_buf_set_lines(first.bufnr, 0, -1, false, { "select 99;" })
local previous_added = added
handler:source_reload(source:name())
vim.wait(20, function()
  return false
end)
assert(added == previous_added, "Reload treated existing connections as newly added")
editor:ensure_connection_scratchpads()
assert(#editor:namespace_get_notes(first_id) == 1)
assert(vim.fn.readfile(first.file)[1] == "select 42;", "Reload overwrote saved SQL")
assert(vim.api.nvim_buf_get_lines(first.bufnr, 0, 1, false)[1] == "select 99;" and vim.bo[first.bufnr].modified)

-- New connections added by editing a source file get scratchpads on reload too.
local specs = source:load()
specs[#specs + 1] = { id = "source-edit", name = "Edited Source", type = "sqlite", url = "unused" }
vim.fn.writefile({ vim.json.encode(specs) }, source:file())
handler:source_reload(source:name())
assert(vim.wait(1000, function()
  return #editor:namespace_get_notes("source-edit") == 1
end))
assert(vim.fn.filereadable(directory .. "/notes/source-edit/Edited Source.sql") == 1)

vim.fn.delete(directory, "rf")
print("Connection scratchpads: automatic creation, reload preservation and drawer updates passed")
