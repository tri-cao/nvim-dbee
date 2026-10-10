-- Run: nvim --headless -u NONE -i NONE -l tests/drawer_mouse.lua
-- Set NUI_RTP if nui.nvim is installed outside the usual lazy.nvim directory.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))
vim.opt.runtimepath:prepend(vim.env.NUI_RTP or (vim.fn.stdpath("data") .. "/lazy/nui.nvim"))
vim.o.mouse = "a"
vim.o.mousetime = 0
vim.o.lines = 40
vim.o.columns = 120

package.loaded["dbee.api.ui"] = {}
local config = vim.deepcopy(require("dbee.config").default.drawer)
config.disable_help = true
local note_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(note_buf, 0, -1, false, { "select 42;" })
local editor_win = vim.api.nvim_get_current_win()
local opened_note, selected_connection, executed_query, result_call
local query_count = 0
local editor = {
  get_current_note = function() end,
  register_event_listener = function() end,
  get_notes = function()
    return { { id = "note", name = "saved.sql", bufnr = note_buf } }
  end,
  set_current_note = function(_, id)
    opened_note = id
    vim.api.nvim_win_set_buf(editor_win, note_buf)
    vim.api.nvim_set_current_win(editor_win)
  end,
}
local source = { name = function() return "mouse-test" end }
local listeners = {}
local handler = {
  get_current_connection = function() return { id = "conn" } end,
  register_event_listener = function(_, event, callback) listeners[event] = callback end,
  get_sources = function() return { source } end,
  source_get_connections = function() return { { id = "conn", name = "Test DB" } } end,
  set_current_connection = function(_, id) selected_connection = id end,
  connection_load_metadata_async = function(_, id)
    listeners.metadata_refresh_state_changed { conn_id = id, refreshing = true }
  end,
  connection_get_structure = function()
    return {
      { name = "public", schema = "", type = "schema", children = {
        { name = "users", schema = "public", type = "table" },
        { name = "active_users", schema = "public", type = "view" },
      } },
    }
  end,
  connection_list_databases = function() return "", {} end,
  connection_get_helpers = function(_, id, opts)
    assert(id == "conn")
    return { List = "select * from " .. opts.schema .. "." .. opts.table }
  end,
  connection_execute = function(_, id, query)
    assert(id == "conn")
    query_count = query_count + 1
    executed_query = query
    return "query-call"
  end,
}
local result = { set_call = function(_, call) result_call = call end }
vim.cmd("topleft vsplit")
local drawer_win = vim.api.nvim_get_current_win()
local drawer = require("dbee.ui.drawer"):new(handler, editor, result, config)
drawer:show(drawer_win)

local function node_line(name)
  for line, text in ipairs(vim.api.nvim_buf_get_lines(drawer.bufnr, 0, -1, false)) do
    if text:find(name, 1, true) then
      return line
    end
  end
  error("missing tree node: " .. name)
end

local function click(line, modifiers)
  if not modifiers then
    click(line, "")
  end
  vim.cmd("redraw")
  local pos = vim.fn.screenpos(drawer_win, line, 1)
  local col = pos.col - 1 + (modifiers == "" and 0 or 20)
  vim.api.nvim_input_mouse("left", "press", modifiers or "2", 0, pos.row - 1, col)
  vim.api.nvim_feedkeys(vim.fn.getcharstr(), "xt", false)
end

-- Single clicks only select; double clicks must target the mouse, not the old cursor.
vim.api.nvim_win_set_cursor(drawer_win, { node_line("sql"), 0 })
click(node_line("saved.sql"), "")
assert(not opened_note, "single click opened a note")
vim.api.nvim_win_set_cursor(drawer_win, { node_line("sql"), 0 })
click(node_line("saved.sql"), "2")
assert(opened_note == "note", "double click did not open the clicked note")
assert(vim.api.nvim_win_get_buf(editor_win) == note_buf, "note buffer is missing from the editor")
assert(vim.fn.mode() == "n", "double click entered Visual mode")

-- Clicking from the editor focuses the drawer and toggles its grouping nodes.
click(node_line("Test DB"))
listeners.metadata_refresh_state_changed { conn_id = "conn", refreshing = false }
assert(selected_connection == "conn", "connection was not activated")
assert(vim.api.nvim_get_current_win() == drawer_win, "mouse did not focus the drawer")
click(node_line("public"))
assert(node_line("users"), "schema did not expand")
click(node_line("public"))
for _, text in ipairs(vim.api.nvim_buf_get_lines(drawer.bufnr, 0, -1, false)) do
  assert(not text:find("users", 1, true), "schema did not collapse")
end
click(node_line("public"))

-- Table/view double clicks execute exactly one List query and display its result.
click(node_line("users"))
assert(executed_query == "select * from public.users" and query_count == 1, "table List query failed")
assert(result_call == "query-call", "query result was not displayed")
click(node_line("active_users"))
assert(executed_query == "select * from public.active_users" and query_count == 2, "view List query failed")
click(node_line("Test DB"))
assert(not drawer.tree:get_node("conn"):is_expanded(), "connection did not collapse")

-- Separators, empty space below the tree, and other panes do not activate nodes.
for line, text in ipairs(vim.api.nvim_buf_get_lines(drawer.bufnr, 0, -1, false)) do
  if text == "" then
    click(line)
    break
  end
end
local pos = vim.api.nvim_win_get_position(drawer_win)
vim.cmd("redraw")
vim.api.nvim_input_mouse("left", "press", "2", 0, pos[1] + vim.api.nvim_win_get_height(drawer_win) - 1, pos[2] + 2)
vim.api.nvim_feedkeys(vim.fn.getcharstr(), "xt", false)
assert(not drawer.tree:get_node("conn"):is_expanded(), "empty space activated the last node")
assert(query_count == 2, "empty space or separator ran a query")

-- The mouse mapping is local to the drawer buffer.
vim.api.nvim_set_current_win(editor_win)
assert(vim.fn.maparg("<2-LeftMouse>", "n") == "", "mouse mapping leaked into the editor")
pos = vim.fn.screenpos(editor_win, 1, 1)
vim.api.nvim_input_mouse("left", "press", "", 0, pos.row - 1, pos.col - 1)
vim.api.nvim_feedkeys(vim.fn.getcharstr(), "xt", false)
drawer:do_action("mouse_action")
assert(query_count == 2, "mouse action outside the drawer ran a query")
print("Drawer mouse: all checks passed")
