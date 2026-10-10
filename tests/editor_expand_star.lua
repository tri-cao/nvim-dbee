-- Run: nvim --headless -n -u NONE -i NONE -l tests/editor_expand_star.lua
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))
local completion = require("dbee.completion")
local conn = { id = "test", type = "postgres" }
local structure = {
  {
    name = "public",
    type = "schema",
    children = {
      { name = "users", schema = "public", type = "table" },
      { name = "orders", schema = "public", type = "table" },
      { name = "events", schema = "public", type = "view" },
    },
  },
}
local columns = {
  users = { { name = "id" }, { name = "name" } },
  orders = { { name = "id" }, { name = "user_id" }, { name = "total" } },
  events = { { name = "event_id" } },
}
local listeners, reads, column_reads, version = {}, 0, 0, 0
local handler = {
  get_current_connection = function()
    return conn
  end,
  register_event_listener = function(_, event, cb)
    listeners[event] = cb
  end,
  connection_get_structure = function()
    reads = reads + 1
    return structure
  end,
  connection_get_columns = function(_, _, opts)
    column_reads = column_reads + 1
    return columns[opts.table] or {}
  end,
  connection_metadata_version = function()
    return version
  end,
}
local checks = 0
local function expand(query, expected, provider)
  local cursor = assert(query:find("|", 1, true))
  local text = query:sub(1, cursor - 1) .. query:sub(cursor + 1)
  local edits, err
  if provider then
    edits, err = provider:expand_star(text, cursor)
  else
    edits, err = completion.expand_star(handler, text, cursor)
  end
  if expected == false then
    assert(edits == nil and err, "expected unresolved wildcard: " .. text)
  else
    assert(edits, err)
    for i = #edits, 1, -1 do
      local edit = edits[i]
      text = text:sub(1, edit.first) .. edit.text .. text:sub(edit.finish + 1)
    end
    assert(text == expected, query .. " expanded to " .. text .. "; expected " .. expected)
  end
  checks = checks + 1
end

expand("SELECT |* FROM users", "SELECT id, name FROM users")
expand("SELECT * FROM public.users|", "SELECT id, name FROM public.users")
expand("SELECT DISTINCT |* FROM users u", "SELECT DISTINCT id, name FROM users u")
expand(
  "SELECT |* FROM users u LEFT JOIN orders o ON u.id=o.user_id JOIN events e ON true",
  "SELECT u.id, u.name, o.id, o.user_id, o.total, e.event_id FROM users u LEFT JOIN orders o ON u.id=o.user_id JOIN events e ON true"
)
expand(
  "SELECT |* FROM users, orders",
  "SELECT users.id, users.name, orders.id, orders.user_id, orders.total FROM users, orders"
)
expand("SELECT |u.* FROM users u JOIN orders o ON true", "SELECT u.id, u.name FROM users u JOIN orders o ON true")
expand(
  "SELECT o.*| FROM users u JOIN orders o ON true",
  "SELECT o.id, o.user_id, o.total FROM users u JOIN orders o ON true"
)
expand(
  "SELECT |u.*, o.*, COUNT(*), u.id * 2 FROM users u JOIN orders o ON true",
  "SELECT u.id, u.name, o.id, o.user_id, o.total, COUNT(*), u.id * 2 FROM users u JOIN orders o ON true"
)
expand(
  "SELECT |* FROM public.users JOIN public.orders ON true",
  "SELECT public.users.id, public.users.name, public.orders.id, public.orders.user_id, public.orders.total FROM public.users JOIN public.orders ON true"
)
expand("SELECT |public.users.* FROM public.users", "SELECT public.users.id, public.users.name FROM public.users")
expand(
  'SELECT |"U".* FROM users "U" JOIN users u ON true',
  'SELECT "U".id, "U".name FROM users "U" JOIN users u ON true'
)
expand('SELECT |U.* FROM users "U"', false)
expand("SELECT |users.* FROM users u", false)
expand("SELECT |x.* FROM users u", false)
expand("SELECT |* FROM missing", false)
expand("SELECT |* FROM users JOIN missing m ON true", false)
expand("SELECT |u.* FROM users u JOIN missing m ON true", "SELECT u.id, u.name FROM users u JOIN missing m ON true")
expand("SELECT |u.*, m.* FROM users u JOIN missing m ON true", false)
expand(
  "WITH people AS (SELECT * FROM users) SELECT |p.* FROM people p",
  "WITH people AS (SELECT * FROM users) SELECT p.id, p.name FROM people p"
)
expand(
  "WITH people(uid, username) AS (SELECT id, name FROM users) SELECT |* FROM people",
  "WITH people(uid, username) AS (SELECT id, name FROM users) SELECT uid, username FROM people"
)
expand(
  "SELECT |q.* FROM (SELECT id AS uid, name FROM users) q",
  "SELECT q.uid, q.name FROM (SELECT id AS uid, name FROM users) q"
)
expand("SELECT * FROM (SELECT |* FROM users) q", "SELECT * FROM (SELECT id, name FROM users) q")
expand(
  "SELECT |* FROM users WHERE EXISTS (SELECT * FROM orders)",
  "SELECT id, name FROM users WHERE EXISTS (SELECT * FROM orders)"
)
expand("SELECT * FROM users; SELECT |* FROM orders", "SELECT * FROM users; SELECT id, user_id, total FROM orders")
expand(
  "SELECT |* FROM users UNION ALL SELECT * FROM orders",
  "SELECT id, name FROM users UNION ALL SELECT * FROM orders"
)
expand(
  "SELECT * FROM users UNION ALL SELECT |* FROM orders",
  "SELECT * FROM users UNION ALL SELECT id, user_id, total FROM orders"
)
expand("SELECT\n  u.\n  |*\nFROM users u", "SELECT\n  u.id, u.name\nFROM users u")
expand("SELECT |COUNT(*), id * 2, '*' FROM users", "SELECT COUNT(*), id * 2, '*' FROM users")
expand('SELECT |"*" FROM users', 'SELECT "*" FROM users')
expand("SELECT * FROM users -- |*", "SELECT * FROM users -- *")
expand("SELECT * FROM users WHERE name = '|*'", "SELECT * FROM users WHERE name = '*'")
expand("SELECT |* EXCEPT (id) FROM users", false)

columns.users = { { name = "id" }, { name = "full name" }, { name = "select" }, { name = "MixedCase" } }
expand("SELECT |* FROM users", 'SELECT id, "full name", "select", "MixedCase" FROM users')
structure[#structure + 1] =
  { name = "archive", type = "schema", children = {
    { name = "users", schema = "archive", type = "table" },
  } }
expand("SELECT |* FROM users", false)
expand("SELECT |* FROM public.users", 'SELECT id, "full name", "select", "MixedCase" FROM public.users')
table.remove(structure)
columns.users = { { name = "id" }, { name = "name" } }

expand("SELECT |q.* FROM (SELECT *, 1 AS extra FROM missing) q", false)
expand("SELECT |q.* FROM (SELECT * FROM users JOIN missing m ON true) q", false)
expand("SELECT |q.* FROM (SELECT id + 1, name FROM users) q", false)
expand(
  'SELECT |q.* FROM (SELECT "U".* FROM users "U" JOIN orders u ON true) q',
  'SELECT q.id, q.name FROM (SELECT "U".* FROM users "U" JOIN orders u ON true) q'
)

local provider = completion.new(handler)
reads, column_reads = 0, 0
expand("SELECT |* FROM users", "SELECT id, name FROM users", provider)
provider:complete("SELECT n FROM users", 9)
assert(reads == 1 and column_reads == 1, "completion and expansion did not share metadata")
version = version + 1
columns.users[#columns.users + 1] = { name = "new_column" }
expand("SELECT |* FROM users", "SELECT id, name, new_column FROM users", provider)
assert(reads == 2 and column_reads == 2, "metadata version did not invalidate expansion")
listeners.metadata_refresh_state_changed { conn_id = conn.id, refreshing = false }
expand("SELECT |* FROM users", "SELECT id, name, new_column FROM users", provider)
assert(reads == 3 and column_reads == 3)

conn = { id = "mysql", type = "mysql" }
expand("SELECT |u.* FROM users u", "SELECT u.id, u.name, u.new_column FROM users u")
conn = { id = "sqlserver", type = "sqlserver" }
columns.users = { { name = "full name" } }
expand("SELECT |[u].* FROM users [u]", "SELECT [u].[full name] FROM users [u]")
conn = { id = "bq", type = "bigquery", url = "bigquery://my-project" }
columns.users = { { name = "id" } }
expand("SELECT |u.* FROM `my-project.public.users` u", "SELECT u.id FROM `my-project.public.users` u")
conn = nil
expand("SELECT |* FROM users", false)
conn = { id = "test", type = "postgres" }
handler.connection_get_structure = function()
  error("metadata unavailable")
end
expand("SELECT |* FROM users", false)
print("Editor wildcard expansion: " .. checks .. " checks passed")
