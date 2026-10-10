-- Run: nvim --headless -u NONE -i NONE -l tests/drawer_sources.lua
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))
vim.opt.runtimepath:prepend(vim.env.NUI_RTP or (vim.fn.stdpath("data") .. "/lazy/nui.nvim"))
package.loaded["dbee.api.ui"] = {}
local common = require("dbee.ui.common")
local prompt, edit_options, edited_file
local prompt_count, edit_count, reload_count = 0, 0, 0
common.float_prompt = function(_, opts)
  prompt_count = prompt_count + 1
  prompt = opts
end
common.float_editor = function(file, opts)
  edit_count = edit_count + 1
  edited_file, edit_options = file, opts
end

local source = require("dbee.sources").FileSource:new("/tmp/dbee/persistence.json")
local readonly = require("dbee.sources").MemorySource:new({}, "readonly")
local connections = {}
local handler = {
  get_current_connection = function() end,
  register_event_listener = function() end,
  get_sources = function()
    return { source, readonly }
  end,
  source_get_connections = function(_, id)
    return id == source:name() and connections or { { id = "readonly-conn", name = "Read-only DB" } }
  end,
  source_add_connection = function(_, id, details)
    assert(id == "persistence.json", "add used the display label as source id")
    assert(details.name == "Test DB" and details.type == "sqlite" and details.url == "/tmp/test.db")
    connections = { { id = "conn", name = details.name } }
  end,
  source_reload = function(_, id)
    assert(id == "persistence.json", "reload used the display label as source id")
    reload_count = reload_count + 1
  end,
  set_current_connection = function() end,
  connection_get_structure = function()
    return {
      {
        name = "public",
        schema = "",
        type = "schema",
        children = {
          { name = "users", schema = "public", type = "table" },
        },
      },
    }
  end,
  connection_get_columns = function()
    return { { name = "id", type = "integer" } }
  end,
  connection_list_databases = function()
    return "", {}
  end,
}
local editor = {
  get_current_note = function() end,
  register_event_listener = function() end,
  namespace_get_notes = function()
    return {}
  end,
}
local drawer_win = vim.api.nvim_get_current_win()
local config = vim.deepcopy(require("dbee.config").default.drawer)
local drawer = require("dbee.ui.drawer"):new(handler, editor, {}, config)
drawer:show(drawer_win)

local function select_node(name)
  for line, text in ipairs(vim.api.nvim_buf_get_lines(drawer.bufnr, 0, -1, false)) do
    if text:find(name, 1, true) then
      vim.api.nvim_win_set_cursor(drawer_win, { line, 0 })
      return
    end
  end
  error("missing node: " .. name)
end
local function press(key)
  vim.api.nvim_feedkeys(key, "xt", false)
end
local function check_no_action_nodes()
  assert(not drawer.tree:get_node("__source_add_connection__persistence.json"), "add node remains")
  assert(not drawer.tree:get_node("__source_edit_connections__persistence.json"), "edit source node remains")
end

-- Empty writable sources stay visible; a adds the first connection.
check_no_action_nodes()
assert(drawer.tree:get_node("__source__persistence.json").name == "connections")
select_node("connections")
press("e")
assert(edit_count == 0, "e acted on the source node")
press("a")
assert(prompt_count == 1 and prompt.title == "Add Connection", "a did not open the add prompt")
prompt.callback { name = "Test DB", type = "sqlite", url = "/tmp/test.db" }
check_no_action_nodes()
select_node("Test DB")
press("e")
assert(edit_count == 1 and edited_file == source:file(), "e did not edit the connection's source")
assert(edit_options.title == "Edit Source")
edit_options.callback()
assert(reload_count == 1, "saving source did not reload it")
select_node("Test DB")
drawer:do_action("expand")
select_node("public")
drawer:do_action("expand")
select_node("users")
drawer:do_action("expand")

-- e never acts on descendants, notes, separators, or read-only connections.
for _, name in ipairs { "public", "users", "id   [integer]", "global notes", "Read-only DB" } do
  select_node(name)
  press("e")
  assert(edit_count == 1, "e acted on " .. name)
end
select_node("Read-only DB")
press("a")
assert(prompt_count == 1, "a acted on a read-only source")
select_node("id   [integer]")
press("a")
assert(prompt_count == 2, "a did not find the source from a descendant")
for line, text in ipairs(vim.api.nvim_buf_get_lines(drawer.bufnr, 0, -1, false)) do
  if text == "" then
    vim.api.nvim_win_set_cursor(drawer_win, { line, 0 })
    press("a")
    press("e")
    assert(prompt_count == 2 and edit_count == 1, "separator triggered a source action")
    break
  end
end
print("Drawer sources: all checks passed")
