-- Run: nvim --headless -u NONE -i NONE -l tests/drawer_metadata.lua
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))
vim.opt.runtimepath:prepend(vim.env.NUI_RTP or (vim.fn.stdpath("data") .. "/lazy/nui.nvim"))
package.loaded["dbee.api.ui"] = {}

local listeners, refreshes = {}, {}
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
  connection_get_structure = function()
    return vim.deepcopy(structure)
  end,
  connection_get_columns = function()
    return { { name = "id", type = "integer" } }
  end,
  connection_list_databases = function()
    return "", {}
  end,
  connection_refresh_metadata_async = function(_, id)
    refreshes[#refreshes + 1] = id
    listeners.metadata_refresh_state_changed { conn_id = id, refreshing = true }
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
local function finish(id, err)
  listeners.metadata_refresh_state_changed { conn_id = id, refreshing = false, error = err }
end

-- Refreshing a descendant targets its connection and animates only that row.
select("Test DB")
drawer:do_action("expand")
select("public")
drawer:do_action("expand")
select("users")
drawer:do_action("expand")
select("id   [integer]")
drawer:do_action("refresh_metadata")
assert(refreshes[1] == "conn")
assert(line("Test DB"):find("Test DB ⠋", 1, true), "spinner is missing after the connection name")
assert(not line("Other DB"):find("⠋", 1, true), "spinner appeared on another connection")
assert(
  vim.wait(500, function()
    return line("Test DB"):find("⠙", 1, true)
  end, 10),
  "spinner did not animate"
)
assert(drawer.tree:get_node("conn"):is_expanded(), "animation collapsed the connection")
assert(line("id   [integer]"), "animation dropped expanded columns")

-- Completion reloads metadata and preserves expansion of parents and descendants.
structure[1].children[#structure[1].children + 1] = { name = "new_table", schema = "public", type = "table" }
finish("conn")
assert(not drawer.spinner_timer, "timer leaked after completion")
assert(not line("Test DB"):find("⠙", 1, true), "spinner remained after completion")
assert(line("new_table") and line("id   [integer]"), "completion lost metadata or expansion")

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

-- Wiping the drawer stops the animation even while metadata is still loading.
select("Test DB")
drawer:do_action("refresh_metadata")
vim.api.nvim_buf_delete(drawer.bufnr, { force = true })
assert(not drawer.spinner_timer, "wiping the buffer leaked the timer")
finish("conn")
print("Drawer metadata: animation, completion, failure, and cleanup passed")
