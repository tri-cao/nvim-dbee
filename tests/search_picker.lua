-- Run: nvim --headless -u NONE -i NONE -l tests/search_picker.lua
-- Set SNACKS_RTP if snacks.nvim is installed outside the usual lazy.nvim directory.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))
vim.opt.runtimepath:prepend(vim.env.SNACKS_RTP or (vim.fn.stdpath("data") .. "/lazy/snacks.nvim"))
vim.o.lines = 40
vim.o.columns = 140
require("snacks").setup { picker = { enabled = true }, notifier = { enabled = false } }

local notices = {}
vim.notify = function(message)
  notices[#notices + 1] = message
end
local connections = {
  { id = "pg", name = "Production", type = "postgres" },
  { id = "bq", name = "Warehouse", type = "bigquery" },
  { id = "offline", name = "Offline", type = "postgres" },
}
local metadata_reads, ddl_reads, executions = {}, 0, {}
local opened, scratchpad, active, displayed = 0, nil, nil, nil
local handler = {
  get_sources = function()
    return {
      {
        name = function()
          return "connections"
        end,
      },
      {
        name = function()
          return "duplicate"
        end,
      },
    }
  end,
  source_get_connections = function(_, source)
    return source == "connections" and connections or { connections[1] }
  end,
  connection_get_structure = function(_, id)
    assert(not vim.in_fast_event(), "metadata RPC called from a fast event")
    metadata_reads[id] = (metadata_reads[id] or 0) + 1
    if id == "offline" then
      error("connection unavailable")
    elseif id == "bq" then
      return {
        {
          name = "analytics",
          schema = "analytics",
          type = "",
          children = {
            { name = "users", schema = "analytics", type = "table" },
          },
        },
        { name = "empty_dataset", schema = "empty_dataset", type = "", children = vim.NIL },
      }
    end
    return {
      {
        name = "public",
        schema = "public",
        type = "schema",
        children = {
          { name = "users", schema = "public", type = "table" },
          { name = "user_view", schema = "public", type = "view" },
          { name = "no_ddl", schema = "public", type = "table" },
          { name = "no_list", schema = "public", type = "table" },
        },
      },
      { name = "empty_schema", schema = "empty_schema", type = "schema", children = {} },
    }
  end,
  connection_get_ddl = function(_, id, opts)
    ddl_reads = ddl_reads + 1
    assert(id == "pg" or id == "bq")
    assert(opts.schema == "public" or opts.schema == "analytics")
    if opts.table == "no_ddl" then
      error("DDL not supported")
    end
    return "CREATE "
      .. (opts.materialization == "view" and "VIEW" or "TABLE")
      .. " "
      .. opts.schema
      .. "."
      .. opts.table
      .. " (\n  id integer\n);"
  end,
  connection_get_helpers = function(_, id, opts)
    if opts.table == "no_list" then
      return {}
    end
    return { List = id .. ": SELECT * FROM " .. opts.schema .. "." .. opts.table .. " LIMIT 100" }
  end,
  set_current_connection = function(_, id)
    active = id
  end,
  connection_execute = function(_, id, query)
    assert(active == id, "table selection did not activate its connection")
    executions[#executions + 1] = { id = id, query = query }
    return { id = "call", query = query }
  end,
}
local editor = {
  open_connection_scratchpad = function(_, id)
    scratchpad = id
  end,
}
local result = {
  set_call = function(_, call)
    displayed = call
  end,
}
local search = require("dbee.ui.search")
local function wait_for(fn, message)
  assert(vim.wait(3000, fn, 10), message)
end
local function open(pattern)
  local picker = search.open(handler, editor, result, function()
    opened = opened + 1
  end, pattern)
  wait_for(function()
    return not picker:is_active() and picker.shown
  end, "picker did not finish loading")
  wait_for(function()
    return picker.preview.item == picker:current()
  end, "initial preview did not update")
  return picker
end
local function filter(picker, pattern, count)
  picker.input:set(pattern)
  picker:find { refresh = false }
  wait_for(function()
    return not picker:is_active() and picker.list:count() == count
  end, "unexpected matches for " .. pattern)
  picker:update { force = true }
  picker:show_preview()
  wait_for(function()
    return picker.preview.item == picker:current()
  end, "preview did not follow selection")
end
local function preview_text(picker)
  return table.concat(vim.api.nvim_buf_get_lines(picker.preview.win.buf, 0, -1, false), "\n")
end
local function enter(picker)
  -- Exercise the actual Snacks Enter mapping in normal mode.
  vim.cmd("stopinsert")
  vim.api.nvim_set_current_win(picker.input.win.win)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
  wait_for(function()
    return picker.closed
  end, "Enter did not close picker")
  wait_for(function()
    return picker.preview == nil
  end, "picker windows were not cleaned up")
end

local picker = open()
assert(#picker.finder.items == 12, "missing collapsed or empty groups, or duplicate connections")
assert(opened == 0 and #executions == 0, "opening search triggered a selection")
assert(table.concat(notices, "\n"):find("Offline", 1, true), "offline connection failure was not reported")
filter(picker, "users", 2)
filter(picker, "Production users", 1)
assert(picker:current().text == "Production / public / users [table]", "schema/table separator is not a slash")
assert(preview_text(picker):find("CREATE TABLE public.users", 1, true), "table preview lacks DDL")
local reads = ddl_reads
picker.preview:show(picker, { force = true })
assert(ddl_reads == reads, "preview fetched the same DDL again")
filter(picker, "Production [schema] public", 1)
assert(preview_text(picker) == "", "schema retained table DDL")
filter(picker, "Production [connection]", 1)
assert(preview_text(picker) == "", "connection detail is not empty")
filter(picker, "Warehouse [dataset]", 2)
assert(preview_text(picker) == "", "dataset detail is not empty")
filter(picker, "Production no_ddl", 1)
assert(preview_text(picker):find("DDL unavailable", 1, true), "DDL error broke preview")
filter(picker, "Warehouse users", 1)
assert(picker:current().text == "Warehouse / analytics / users [table]", "dataset/table separator is not a slash")
assert(preview_text(picker):find("CREATE TABLE analytics.users", 1, true))
assert(metadata_reads.pg == 1 and metadata_reads.bq == 1 and metadata_reads.offline == 1, "typing reloaded metadata")
enter(picker)
wait_for(function()
  return displayed ~= nil
end, "table Enter did not display data")
assert(opened == 1 and active == "bq" and executions[1].id == "bq")
assert(displayed.query == "bq: SELECT * FROM analytics.users LIMIT 100")
assert(scratchpad == nil, "table Enter opened a scratchpad")

for _, selection in ipairs {
  { pattern = "Production [connection]", id = "pg" },
  { pattern = "Production empty_schema", id = "pg" },
  { pattern = "Warehouse empty_dataset", id = "bq" },
} do
  scratchpad = nil
  picker = open(selection.pattern)
  assert(picker.list:count() == 1 and preview_text(picker) == "")
  enter(picker)
  wait_for(function()
    return scratchpad == selection.id
  end, "group Enter did not open its connection scratchpad")
end
assert(#executions == 1, "group Enter ran a query")

picker = open("Production user_view")
assert(preview_text(picker):find("CREATE VIEW public.user_view", 1, true))
enter(picker)
wait_for(function()
  return #executions == 2
end, "view Enter did not execute List")
assert(active == "pg" and displayed.query == "pg: SELECT * FROM public.user_view LIMIT 100")

picker = open("Production no_list")
enter(picker)
wait_for(function()
  return table.concat(notices, "\n"):find("No List query", 1, true) ~= nil
end, "missing helper was not reported")
assert(#executions == 2, "missing helper executed an invalid query")

picker = open("no-such-object")
assert(picker.list:count() == 0)
local before = opened
picker.opts.confirm(picker, nil)
assert(not picker.closed and opened == before, "empty selection opened DBee")
picker:close()
wait_for(function()
  return picker.preview == nil
end, "cancel did not clean up")
assert(opened == before and #executions == 2, "cancel triggered an action")

-- Public Lua API, Ex command, and drawer action all reach the same picker.
vim.opt.runtimepath:prepend(vim.env.NUI_RTP or (vim.fn.stdpath("data") .. "/lazy/nui.nvim"))
package.loaded["dbee.api.state"] = {
  handler = function()
    return handler
  end,
  editor = function()
    return editor
  end,
  result = function()
    return result
  end,
}
local dbee = require("dbee")
dbee.open = function()
  opened = opened + 1
end
picker = dbee.search("Warehouse users")
wait_for(function()
  return not picker:is_active() and picker.list:count() == 1
end, "public API did not forward initial search")
assert(picker:current().conn_id == "bq")
picker:close()
wait_for(function()
  return picker.preview == nil
end, "public API picker did not close")
vim.cmd("runtime plugin/dbee.lua")
vim.cmd("Dbee search Production users")
picker = Snacks.picker.get({ tab = false })[1]
wait_for(function()
  return not picker:is_active() and picker.list:count() == 1
end, "Ex command did not forward initial search")
assert(picker:current().conn_id == "pg")
picker:close()
wait_for(function()
  return picker.preview == nil
end, "Ex command picker did not close")
require("dbee.ui.drawer").get_actions({}).search()
picker = Snacks.picker.get({ tab = false })[1]
assert(picker, "drawer action did not open search")
picker:close()
wait_for(function()
  return picker.preview == nil
end, "drawer action picker did not close")
local mapped = false
for _, mapping in ipairs(require("dbee.config").default.drawer.mappings) do
  mapped = mapped or (mapping.key == "/" and mapping.action == "search")
end
assert(mapped, "drawer has no default search mapping")

package.loaded["snacks"] = {}
assert(search.open(handler, editor, result, function()
  error("unexpected selection")
end) == nil)
assert(notices[#notices]:find("requires folke/snacks.nvim", 1, true), "missing Snacks was not reported")
print("DBee Snacks search: all checks passed")
