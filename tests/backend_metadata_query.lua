-- DBEE_TEST_BINARY=/path/to/dbee nvim --headless -u NONE -i NONE -l tests/backend_metadata_query.lua
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))
local binary = assert(vim.env.DBEE_TEST_BINARY, "DBEE_TEST_BINARY must point to the backend under test")
vim.env.PATH = vim.fs.dirname(binary) .. ":" .. vim.env.PATH
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, "p")
local database = directory .. "/source.sqlite3"
local function external(sql)
  local result = vim.system({ "sqlite3", database, sql }, { text = true }):wait()
  assert(result.code == 0, result.stderr)
end
external("CREATE TABLE users (id INTEGER); CREATE TABLE sibling (id INTEGER);")
require("dbee.api.__register")()
local handler = require("dbee.handler"):new()
local id = vim.fn.DbeeCreateConnection { id = "query-metadata", name = "Query metadata", type = "sqlite", url = database }
local events, states = {}, {}
handler:register_event_listener("metadata_refresh_state_changed", function(data)
  if data.conn_id == id then
    events[#events + 1] = data
  end
end)
handler:register_event_listener("call_state_changed", function(data)
  states[data.call.id] = data.call.state
end)
local function opts(name)
  return { schema = "sqlite_schema", table = name, materialization = "table" }
end
local function ddl(name)
  return handler:connection_get_ddl(id, opts(name))
end
local function columns(name)
  return handler:connection_get_columns(id, opts(name))
end
local schema_node = id .. "__connection_sqlite_schemasqlite_schemaschema__"
local function table_node(name)
  return schema_node .. "__connection_" .. name .. "sqlite_schematable__"
end
handler:connection_load_metadata_async(id)
assert(vim.wait(5000, function() return #events == 2 end, 10), "initial metadata load timed out")
assert(not events[2].error, events[2].error)
local function execute(sql, nodes, failed)
  events = {}
  local call = handler:connection_execute(id, sql)
  assert(vim.wait(5000, function()
    return states[call.id] == (failed and "executing_failed" or "archived")
      and #events == #nodes * 2
  end, 10), "query/metadata refresh timed out: " .. sql .. " (state: " .. tostring(states[call.id]) .. ")")
  for index, node in ipairs(nodes) do
    local start, finish = events[index * 2 - 1], events[index * 2]
    assert(start.refreshing and not finish.refreshing, "refresh did not complete")
    assert(not finish.error, finish.error)
    assert(start.node_id == node and finish.node_id == node, "query refreshed the wrong drawer scope")
  end
  return call
end

-- Table changes update columns and DDL without replacing sibling metadata.
local sibling_before = ddl("sibling")
external("ALTER TABLE sibling ADD COLUMN external_change TEXT;")
execute("/* ALTER TABLE fake */ ALTER TABLE users ADD COLUMN email TEXT", { table_node("users") })
assert(#columns("users") == 2 and ddl("users"):find("email", 1, true), "ALTER retained stale table metadata")
assert(ddl("sibling") == sibling_before and #columns("sibling") == 1, "table refresh replaced sibling metadata")

-- New tables refresh their containing schema, including newly visible siblings.
execute("CREATE TABLE new_table (id INTEGER, title TEXT)", { schema_node })
assert(#columns("new_table") == 2, "CREATE TABLE did not populate columns")
assert(#columns("sibling") == 2, "schema refresh did not update sibling metadata")
execute("ALTER TABLE new_table RENAME TO renamed", { schema_node })
assert(#columns("renamed") == 2, "renamed table was not added to metadata")
assert(not pcall(columns, "new_table"), "renamed table retained its old columns")
execute("DROP TABLE renamed", { table_node("renamed") })
assert(not pcall(columns, "renamed") and not pcall(ddl, "renamed"), "dropped table retained cached metadata")

-- A multi-statement query refreshes both tables, or their shared parent.
execute("ALTER TABLE users ADD COLUMN age INTEGER; ALTER TABLE sibling ADD COLUMN label TEXT;", {
  table_node("users"), table_node("sibling"),
})
assert(#columns("users") == 3 and #columns("sibling") == 3, "batch skipped an affected table")
execute("ALTER TABLE users ADD COLUMN active INTEGER; CREATE TABLE batch_created (id INTEGER);", { schema_node })
assert(#columns("users") == 4 and #columns("batch_created") == 1, "parent refresh skipped a batch change")

-- Data-only SQL, quoted DDL text, and failed DDL leave metadata alone.
execute("INSERT INTO users (id, email) VALUES (1, 'CREATE TABLE fake;')", {})
execute("SELECT 'ALTER TABLE users; DROP SCHEMA fake;' AS text -- CREATE TABLE fake", {})
execute("ALTER TABLE does_not_exist ADD COLUMN bad TEXT", {}, true)
vim.wait(100, function() return false end, 10)
assert(#events == 0, "read-only or failed query triggered a metadata refresh")

-- DDL without a table target refreshes the entire connection.
execute("ATTACH DATABASE ':memory:' AS auxiliary", { id })
assert(#columns("users") == 4, "connection refresh lost existing metadata")

-- An empty connection has a UI placeholder instead of a schema. Its first
-- CREATE must replace that placeholder with the real database structure.
vim.fn.DbeeDeleteConnection(id)
local empty_database = directory .. "/empty.sqlite3"
local empty = vim.system({ "sqlite3", empty_database, "PRAGMA user_version=0;" }, { text = true }):wait()
assert(empty.code == 0, empty.stderr)
id = vim.fn.DbeeCreateConnection { id = "empty-query-metadata", name = "Empty DB", type = "sqlite", url = empty_database }
events = {}
handler:connection_load_metadata_async(id)
assert(vim.wait(5000, function() return #events == 2 end, 10), "empty metadata load timed out")
assert(not events[2].error, events[2].error)
execute("CREATE TABLE first_table (id INTEGER)", { id })
assert(#columns("first_table") == 1, "first table was lost by refreshing the placeholder schema")
print("Automatic query metadata: table/schema/connection scopes, batches, rename/drop, and failed/read-only queries passed")
vim.fn.DbeeDeleteConnection(id)
local channel = vim.fn["remote#host#Require"]("nvim_dbee")
vim.fn.jobstop(channel)
vim.fn.jobwait({ channel }, 3000)
vim.fn.delete(directory, "rf")
