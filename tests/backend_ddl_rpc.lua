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
  print("Backend DDL RPC: table, view, and metadata cache verified")
end
vim.fn.DbeeDeleteConnection(id)
local channel = vim.fn["remote#host#Require"]("nvim_dbee")
vim.fn.jobstop(channel)
vim.fn.jobwait({ channel }, 3000)
vim.fn.delete(directory, "rf")
