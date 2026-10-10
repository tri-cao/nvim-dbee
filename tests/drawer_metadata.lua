-- Run: nvim --headless -u NONE -i NONE -l tests/drawer_metadata.lua
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))
vim.opt.runtimepath:prepend(vim.env.NUI_RTP or (vim.fn.stdpath("data") .. "/lazy/nui.nvim"))
package.loaded["dbee.api.ui"] = {}

local listeners, refreshes, scopes = {}, {}, {}
local structure_reads = {}
local current_database = ""
local source = {
  name = function()
    return "metadata-test"
  end,
}
local structure = {
  {
    name = "public",
    schema = "",
    type = "schema",
    children = {
      { name = "users", schema = "public", type = "table" },
    },
  },
}
local handler = {
  get_current_connection = function()
    return { id = "conn" }
  end,
  register_event_listener = function(_, event, callback)
    listeners[event] = callback
  end,
  get_sources = function()
    return { source }
  end,
  source_get_connections = function()
    return { { id = "conn", name = "Test DB" }, { id = "other", name = "Other DB" } }
  end,
  connection_get_structure = function(_, id)
    structure_reads[id] = (structure_reads[id] or 0) + 1
    return vim.deepcopy(structure)
  end,
  connection_get_columns = function()
    return { { name = "id", type = "integer" } }
  end,
  connection_list_databases = function()
    return current_database, current_database ~= "" and { current_database } or {}
  end,
  connection_refresh_metadata_async = function(_, id, scope)
    refreshes[#refreshes + 1] = id
    scopes[#refreshes] = scope
    listeners.metadata_refresh_state_changed { conn_id = id, node_id = scope and scope.node_id, refreshing = true }
  end,
}
local editor = {
  get_current_note = function() end,
  register_event_listener = function() end,
  namespace_get_notes = function()
    return {}
  end,
}
local drawer = require("dbee.ui.drawer"):new(handler, editor, {}, require("dbee.config").default.drawer, {
  spinner = { "⠋", "⠙", "⠹" },
})
drawer:show(vim.api.nvim_get_current_win())

local function line(name)
  for index, text in ipairs(vim.api.nvim_buf_get_lines(drawer.bufnr, 0, -1, false)) do
    if text:find(name, 1, true) then
      return text, index
    end
  end
  error("missing node: " .. name)
end
local function select(name)
  local _, index = line(name)
  vim.api.nvim_win_set_cursor(0, { index, 0 })
end
local function finish(id, err, scope)
  listeners.metadata_refresh_state_changed { conn_id = id, node_id = scope and scope.node_id, refreshing = false, error = err }
end

-- Refreshing a column targets its table and animates only that row.
select("Other DB")
drawer:do_action("expand")
local other_reads = structure_reads.other
local other_children = drawer.tree:get_nodes("other")
select("Test DB")
drawer:do_action("expand")
select("public")
drawer:do_action("expand")
select("users")
drawer:do_action("expand")
select("id   [integer]")
drawer:do_action("refresh_metadata")
assert(refreshes[1] == "conn")
local table_scope = scopes[1]
assert(vim.deep_equal(table_scope.path, {
  { name = "public", schema = "", type = "schema" },
  { name = "users", schema = "public", type = "table" },
}), "column refresh did not target its table")
assert(line("users"):find("users ⠋", 1, true), "spinner is missing after the table name")
assert(not line("Test DB"):find("⠋", 1, true), "table refresh animated the connection")
assert(not line("Other DB"):find("⠋", 1, true), "spinner appeared on another connection")
assert(
  vim.wait(500, function()
    return line("users"):find("⠙", 1, true)
  end, 10),
  "spinner did not animate"
)
assert(drawer.tree:get_node("conn"):is_expanded(), "animation collapsed the connection")
assert(line("id   [integer]"), "animation dropped expanded columns")

-- Completion reloads metadata and preserves expansion of parents and descendants.
structure[1].children[#structure[1].children + 1] = { name = "new_table", schema = "public", type = "table" }
finish("conn", nil, table_scope)
assert(not drawer.spinner_timer, "timer leaked after completion")
assert(not line("users"):find("⠙", 1, true), "spinner remained after completion")
assert(line("new_table") and line("id   [integer]"), "completion lost metadata or expansion")
assert(structure_reads.other == other_reads, "completion reloaded another connection")
assert(drawer.tree:get_nodes("other")[1] == other_children[1], "completion replaced another connection's nodes")

-- Schema/dataset nodes carry a shorter path, including untyped BigQuery datasets.
select("public")
drawer:do_action("refresh_metadata")
assert(#scopes[2].path == 1 and scopes[2].path[1].name == "public", "schema refresh targeted the whole connection")
assert(line("public"):find("⠋", 1, true), "schema spinner is missing")
finish("conn", nil, scopes[2])
structure[1].type = ""
drawer:refresh_connection("conn")
select("public")
drawer:do_action("expand")
drawer:do_action("refresh_metadata")
assert(#scopes[3].path == 1 and scopes[3].path[1].type == "", "dataset refresh targeted the whole connection")
finish("conn", nil, scopes[3])

-- Distinct scopes in the same connection keep independent progress state.
select("public")
drawer:do_action("refresh_metadata")
local schema_scope = scopes[4]
select("users")
drawer:do_action("refresh_metadata")
table_scope = scopes[5]
finish("conn", nil, schema_scope)
assert(drawer.spinner_timer and drawer.refreshing[table_scope.node_id], "schema completion stopped the table spinner")
assert(line("users"):find("⠋", 1, true), "table progress disappeared when its parent completed")
finish("conn", nil, table_scope)
assert(not drawer.spinner_timer, "scoped refresh leaked its timer")

-- Independent connections share the timer; a failure clears only its spinner.
select("Test DB")
drawer:do_action("refresh_metadata")
select("Other DB")
drawer:do_action("refresh_metadata")
finish("conn")
assert(drawer.spinner_timer and drawer.refreshing.other, "finishing one connection stopped another spinner")
local notification
local notify = vim.notify
vim.notify = function(message, level)
  assert(level == vim.log.levels.ERROR)
  notification = message
end
finish("other", "metadata refresh failed")
vim.notify = notify
assert(notification == "metadata refresh failed", "refresh failure was not reported")
assert(not drawer.spinner_timer and not next(drawer.refreshing), "failed refresh leaked its spinner")
assert(line("new_table"), "failure removed the existing metadata")

-- The public refresh function follows the drawer selection, unless given an ID.
local full_refreshes = {}
package.loaded["dbee.api"] = {
  core = { connection_refresh_metadata_async = function(id)
    full_refreshes[#full_refreshes + 1] = id or "active"
  end },
  ui = {},
}
package.loaded["dbee.api.state"] = { drawer = function() return drawer end }
select("users")
require("dbee").refresh_metadata()
local scope = scopes[#refreshes]
assert(scope and #scope.path == 2, "public refresh ignored the selected table")
finish("conn", nil, scope)
require("dbee").refresh_metadata("other")
assert(full_refreshes[1] == "other", "explicit connection ID did not refresh that connection")
local outside = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(outside)
require("dbee").refresh_metadata()
assert(full_refreshes[2] == "active", "refresh outside the drawer did not use the active connection")
vim.api.nvim_set_current_buf(drawer.bufnr)
vim.api.nvim_buf_delete(outside, { force = true })

-- The database selector refreshes the connection's selected database.
current_database = "warehouse"
drawer:refresh_connection("conn")
select("warehouse")
drawer:do_action("refresh_metadata")
scope = scopes[#refreshes]
assert(scope and #scope.path == 0, "database refresh did not target the selected database")
assert(line("warehouse"):find("⠋", 1, true), "database spinner is missing")
finish("conn", nil, scope)

-- Wiping the drawer stops the animation even while metadata is still loading.
select("Test DB")
drawer:do_action("refresh_metadata")
vim.api.nvim_buf_delete(drawer.bufnr, { force = true })
assert(not drawer.spinner_timer, "wiping the buffer leaked the timer")
finish("conn")
print("Drawer metadata: animation, completion, failure, and cleanup passed")
