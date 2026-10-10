-- Run with DBEE_TEST_BINARY pointing to a freshly built backend:
-- DBEE_TEST_BINARY=/path/to/dbee nvim --headless -u NONE -i NONE -l tests/backend_ddl_rpc.lua
-- DBEE_EXPECT_OLD=1 checks the diagnostic against an older backend.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))
local binary = assert(vim.env.DBEE_TEST_BINARY, "DBEE_TEST_BINARY must point to the backend under test")
vim.env.PATH = vim.fs.dirname(binary) .. ":" .. vim.env.PATH
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, "p")
local database = directory .. "/source.sqlite3"
local fixture = vim
  .system({
    "sqlite3",
    database,
    "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL DEFAULT 'guest'); "
      .. "CREATE VIEW active_users AS SELECT id FROM users;",
  }, { text = true })
  :wait()
assert(fixture.code == 0, fixture.stderr)
require("dbee.api.__register")()
local handler = require("dbee.handler"):new()
local id = vim.fn.DbeeCreateConnection { id = "ddl-rpc", name = "DDL RPC", type = "sqlite", url = database }
local table_opts = { schema = "sqlite_schema", table = "users", materialization = "table" }
if vim.env.DBEE_EXPECT_OLD == "1" then
  local ok, err = pcall(handler.connection_get_ddl, handler, id, table_opts)
  assert(not ok and tostring(err):find("backend is outdated", 1, true), tostring(err))
  assert(tostring(err):find('require("dbee").install("go")', 1, true), "missing rebuild instructions")
  print("Older backend RPC: rebuild diagnostic verified")
else
  local events = {}
  handler:register_event_listener("metadata_refresh_state_changed", function(data)
    events[#events + 1] = data
  end)
  handler:connection_load_metadata_async(id)
  assert(vim.wait(5000, function() return #events == 2 end, 10), "initial async metadata load did not finish")
  assert(events[1].conn_id == id and events[1].refreshing, "initial load did not emit its start event")
  assert(not events[2].refreshing and not events[2].error, events[2].error or "initial metadata load failed")
  local structure = handler:connection_get_structure(id)
  assert(#structure > 0, "metadata RPC returned no structure")
  local ddl = handler:connection_get_ddl(id, table_opts)
  assert(ddl:find("CREATE TABLE users", 1, true), "DDL RPC returned no table definition")
  assert(ddl:find("PRIMARY KEY", 1, true) and ddl:find("DEFAULT 'guest'", 1, true), "DDL lost constraints")
  local view = handler:connection_get_ddl(id, {
    schema = "sqlite_schema",
    table = "active_users",
    materialization = "view",
  })
  assert(view:find("CREATE VIEW active_users", 1, true), "view DDL RPC failed")
  assert(#handler:connection_get_calls(id) == 0, "DDL preview created query history")

  events = {}
  handler:connection_refresh_metadata_async(id)
  assert(
    vim.wait(5000, function()
      return #events == 2
    end, 10),
    "async refresh did not finish"
  )
  assert(events[1].conn_id == id and events[1].refreshing, "async refresh did not emit its start event")
  assert(events[2].conn_id == id and not events[2].refreshing and not events[2].error, "async refresh failed")
  assert(handler:connection_get_ddl(id, table_opts) == ddl, "async refresh lost DDL")

  -- A table refresh changes only its columns/DDL, even if sibling views also change.
  local changed = vim.system({ "sqlite3", database,
    "ALTER TABLE users ADD COLUMN email TEXT; DROP VIEW active_users; "
      .. "CREATE VIEW active_users AS SELECT id, email FROM users; CREATE TABLE added (id INTEGER);",
  }, { text = true }):wait()
  assert(changed.code == 0, changed.stderr)
  -- Initial loading reuses the snapshot instead of forcing a database refresh.
  events = {}
  handler:connection_load_metadata_async(id)
  assert(vim.wait(5000, function() return #events == 2 end, 10), "cached async load did not finish")
  assert(not events[2].error, events[2].error)
  assert(handler:connection_get_ddl(id, table_opts) == ddl, "initial load bypassed cached metadata")
  local scope = {
    node_id = "users-node",
    path = {
      { name = "sqlite_schema", schema = "sqlite_schema", type = "schema" },
      { name = "users", schema = "sqlite_schema", type = "table" },
    },
  }
  events = {}
  handler:connection_refresh_metadata_async(id, scope)
  assert(vim.wait(5000, function() return #events == 2 end, 10), "scoped refresh did not finish")
  assert(events[1].node_id == "users-node" and events[2].node_id == "users-node", "scoped progress targeted the connection")
  assert(not events[2].error, events[2].error)
  assert(handler:connection_get_ddl(id, table_opts):find("email", 1, true), "table DDL was not refreshed")
  assert(#handler:connection_get_columns(id, table_opts) == 3, "table columns were not refreshed")
  local view_opts = { schema = "sqlite_schema", table = "active_users", materialization = "view" }
  assert(handler:connection_get_ddl(id, view_opts) == view, "table refresh changed sibling DDL")
  assert(#handler:connection_get_structure(id)[1].children == 2, "table refresh changed sibling structure")

  -- Refreshing the schema picks up additions and changed sibling metadata.
  scope.path[2] = nil
  handler:connection_refresh_metadata(id, scope)
  assert(#handler:connection_get_structure(id)[1].children == 3, "schema refresh missed a new table")
  assert(handler:connection_get_ddl(id, view_opts):find("email", 1, true), "schema refresh missed changed view DDL")
  -- Keep the single-argument RPC working for callers using the original API.
  assert(#vim.fn.DbeeConnectionRefreshMetadata(id) > 0, "legacy refresh RPC lost compatibility")

  -- Dropped tables lose their cached columns and DDL without touching sibling views.
  changed = vim.system({ "sqlite3", database, "DROP TABLE users;" }, { text = true }):wait()
  assert(changed.code == 0, changed.stderr)
  scope.path[2] = { name = "users", schema = "sqlite_schema", type = "table" }
  local sibling_ddl = handler:connection_get_ddl(id, view_opts)
  handler:connection_refresh_metadata(id, scope)
  assert(not pcall(handler.connection_get_columns, handler, id, table_opts), "dropped table retained cached columns")
  assert(not pcall(handler.connection_get_ddl, handler, id, table_opts), "dropped table retained cached DDL")
  assert(handler:connection_get_ddl(id, view_opts) == sibling_ddl, "dropped-table refresh removed sibling DDL")

  -- A failed background refresh must also emit completion, including the error.
  local failed_id = vim.fn.DbeeCreateConnection {
    id = "failed-metadata-rpc",
    name = "Failed metadata",
    type = "postgres",
    url = "postgres://test:test@127.0.0.1:1/test?sslmode=disable&connect_timeout=1",
  }
  events = {}
  handler:connection_refresh_metadata_async(failed_id)
  assert(
    vim.wait(5000, function()
      return #events == 2
    end, 10),
    "failed async refresh did not finish"
  )
  assert(events[1].conn_id == failed_id and events[1].refreshing, "failed refresh did not emit its start event")
  assert(events[2].conn_id == failed_id and not events[2].refreshing and events[2].error, "refresh error was lost")
  vim.fn.DbeeDeleteConnection(failed_id)
  local ok, err = pcall(handler.connection_load_metadata_async, handler, "missing")
  assert(not ok and tostring(err):find("unknown connection", 1, true), "unknown async load connection was accepted")
  ok, err = pcall(handler.connection_refresh_metadata_async, handler, "missing")
  assert(not ok and tostring(err):find("unknown connection", 1, true), "unknown async connection was accepted")
  print("Backend DDL RPC: table, view, and metadata cache verified")
  print("Backend metadata RPC: async success, failure, and validation verified")
end
vim.fn.DbeeDeleteConnection(id)
local channel = vim.fn["remote#host#Require"]("nvim_dbee")
vim.fn.jobstop(channel)
vim.fn.jobwait({ channel }, 3000)
vim.fn.delete(directory, "rf")
