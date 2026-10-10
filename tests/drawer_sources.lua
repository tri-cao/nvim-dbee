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
local listeners, loads, ready = {}, {}, {}
local structure_reads = 0
local handler = {
  get_current_connection = function() end,
  register_event_listener = function(_, event, callback)
    listeners[event] = callback
  end,
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
  set_current_connection = function(_, id)
    listeners.current_connection_changed { conn_id = id }
  end,
  connection_load_metadata_async = function(_, id)
    loads[#loads + 1] = id
    listeners.metadata_refresh_state_changed { conn_id = id, refreshing = true }
  end,
  connection_get_structure = function(_, id)
    assert(ready[id], "metadata was read before the background load finished")
    structure_reads = structure_reads + 1
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
  connection_list_databases = function(_, id)
    assert(ready[id], "database selector was read before the background load finished")
    return "", {}
  end,
}
local editor = {
  get_current_note = function() end,
  register_event_listener = function() end,
  get_notes = function()
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
-- Enter on a newly added connection starts background loading and renders progress.
press(vim.api.nvim_replace_termcodes("<CR>", true, false, true))
assert(loads[1] == "conn" and structure_reads == 0, "Enter did not load the new connection asynchronously")
assert(drawer.spinner_timer and drawer.refreshing.conn, "new connection did not show a spinner")
assert(
  table.concat(vim.api.nvim_buf_get_lines(drawer.bufnr, 0, -1, false), "\n"):find("Test DB " .. drawer.spinner[1], 1, true),
  "initial spinner was not rendered beside the new connection"
)
assert(drawer.tree:get_node("conn"):is_expanded(), "new connection did not remember expansion while loading")
drawer:refresh()
assert(#loads == 1 and structure_reads == 0, "refresh duplicated or blocked the initial load")
-- Users can collapse and reopen the connection while the load is running.
select_node("Test DB")
drawer:do_action("action_1")
assert(not drawer.tree:get_node("conn"):is_expanded(), "loading connection did not collapse")
drawer:do_action("action_1")
assert(#loads == 1 and structure_reads == 0, "reopening started a duplicate load")
ready.conn = true
listeners.metadata_refresh_state_changed { conn_id = "conn", refreshing = false }
assert(not drawer.spinner_timer and not drawer.refreshing.conn, "initial load leaked its spinner")
assert(drawer.tree:get_node("conn"):is_expanded(), "completion collapsed the new connection")
select_node("public")
drawer:do_action("expand")
select_node("users")
drawer:do_action("expand")

-- e never acts on descendants, notes, separators, or read-only connections.
for _, name in ipairs { "public", "users", "id   [integer]", "sql", "Read-only DB" } do
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
-- Editing a connection's URL must load the new metadata in the background too.
connections = { { id = "conn", name = "Test DB", type = "sqlite", url = "/tmp/changed.db" } }
ready.conn = nil
local previous_reads = structure_reads
drawer:refresh()
assert(#loads == 2 and structure_reads == previous_reads, "edited connection reused old readiness or blocked the UI")
ready.conn = true
listeners.metadata_refresh_state_changed { conn_id = "conn", refreshing = false }
assert(not drawer.spinner_timer, "edited connection load leaked its spinner")
print("Drawer sources: all checks passed")
